// standby-capture-helper
//
// A tiny native capture/transcription boundary for Standby. It owns the macOS
// frameworks that Rust cannot drive safely (ScreenCaptureKit, Apple Speech /
// SpeechAnalyzer, AVAudioEngine) and emits one JSON object per line on stdout.
//
// It is deliberately dumb: it captures audio, measures it, transcribes it, and
// reports honest failures. It NEVER writes SQLite, creates proposals, launches
// workers, sends messages, or knows worker credentials. Rust owns all durable
// behavior. Diagnostics go to stderr; only JSONL goes to stdout.
//
// Concurrency contract (the original helper deadlocked here — see
// docs/research/capture-helper-deadlock-and-system-audio.md):
//   * This file is `main.swift` with top-level `await`, so the Swift runtime
//     drives an async main that SERVICES the main-actor executor. The old build
//     used `dispatchMain()`, a GCD loop that parks the main thread WITHOUT
//     pumping that executor, so AVFoundation/Speech continuations that hop to the
//     main actor never resumed → wedge. We never call `dispatchMain()`.
//   * Realtime audio callbacks do ZERO blocking work: they copy the buffer and
//     `yield` it to a per-lane bounded `AsyncStream`. No per-callback `Task`, no
//     locks, no I/O on the render thread. A single consumer task per lane drains
//     the stream → RMS + convert + feed the transcriber + emit.
//   * stdout is owned by one serial queue; `emit()` is a non-blocking `async`
//     enqueue (never `.sync`, never called from a realtime thread). `flushStdout()`
//     is a barrier used only before process exit so terminal events aren't lost.
//   * Lifecycle runs under a structured `TaskGroup`; the stop signal
//     (SIGTERM/SIGINT/`--seconds`) is observed on a DEDICATED queue, never `.main`.
//   * Transcriber-bound audio is never dropped silently: a bounded-stream overflow
//     increments a counter and emits `audio.dropped{lane,count}`.
//
// Subcommands:
//   transcribe-file <path> [--locale en-US]
//       Deterministic offline transcription of an audio file. Emits
//       transcribe.final per phrase and transcribe.done with the full text.
//   capture --mode mic|system|mic+system [--seconds N] [--locale en-US]
//       Live capture. Emits source.started, audio.level per lane, segment
//       partial/final per lane, audio.dropped on overflow, source.failed|stopped.
//
// Output event shapes (one JSON object per line):
//   {"type":"source.started","mode":"mic+system","mic":true,"system":true}
//   {"type":"audio.level","lane":"microphone","rms":0.04,"peak":0.2,"captured_ms":1000}
//   {"type":"audio.dropped","lane":"system_audio","count":3}
//   {"type":"segment.partial","lane":"microphone","speaker":"me","text":"...","start_ms":0,"end_ms":0}
//   {"type":"segment.final","lane":"system_audio","speaker":"system_audio","text":"...","start_ms":0,"end_ms":0}
//   {"type":"source.failed","reason":"screen_recording_permission_denied","lane":"system_audio","detail":"..."}
//   {"type":"source.stopped"}
//   {"type":"transcribe.final","text":"...","start_ms":0,"end_ms":2533}
//   {"type":"transcribe.done","text":"..."}

import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech
import Synchronization

// MARK: - Output (single serial writer; non-blocking enqueue, barrier flush)

let stdoutQueue = DispatchQueue(label: "standby.capture.stdout")

/// Non-blocking: serialize the JSON line onto the stdout queue and return. Safe to
/// call from any non-realtime context. NEVER call from an audio render thread.
func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    stdoutQueue.async {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

/// Barrier: block until all queued writes have flushed. Used ONLY just before
/// `exit()` so a terminal event (source.failed / source.stopped / transcribe.done)
/// can't be lost to the async writer.
func flushStdout() {
    stdoutQueue.sync {}
}

func logErr(_ message: String) {
    FileHandle.standardError.write(("standby-capture-helper: " + message + "\n").data(using: .utf8)!)
}

/// Fire `body` after `seconds` on a background thread, independent of the async
/// executor. Used as a hard watchdog: ScreenCaptureKit acquisition can hang with
/// no throw/prompt when the host process lacks Screen-Recording TCC, and a
/// structured-concurrency timeout cannot interrupt that non-cancellable await —
/// but `exit()` from this thread terminates the stuck process.
func armWatchdog(_ seconds: Double, _ body: @escaping () -> Void) {
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: body)
}

func failAndExit(reason: String, lane: String?, detail: String?) -> Never {
    var event: [String: Any] = ["type": "source.failed", "reason": reason]
    if let lane { event["lane"] = lane }
    if let detail { event["detail"] = detail }
    emit(event)
    flushStdout()
    exit(1)
}

func rms(of buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
    guard let channel = buffer.floatChannelData else { return (0, 0) }
    let frames = Int(buffer.frameLength)
    if frames == 0 { return (0, 0) }
    var sum: Float = 0
    var peak: Float = 0
    let samples = channel[0]
    for i in 0..<frames {
        let s = samples[i]
        sum += s * s
        let a = abs(s)
        if a > peak { peak = a }
    }
    return ((sum / Float(frames)).squareRoot(), peak)
}

/// A fixed ring of pre-allocated PCM buffers so the realtime mic render thread can
/// copy WITHOUT calling `malloc` (allocation takes a lock and can stall the audio
/// thread under memory pressure — the no-allocation-on-render-thread invariant).
/// `count` exceeds the lane stream's buffering cap, so by the time the ring wraps
/// back to a slot, that slot is no longer in the stream and is safe to overwrite.
/// Single-producer (the tap block is called serially), so the index needs no lock.
final class PCMBufferPool: @unchecked Sendable {
    private let buffers: [AVAudioPCMBuffer]
    private var index = 0

    init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, count: Int) {
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(count)
        for _ in 0..<count {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
            else { return nil }
            allocated.append(buffer)
        }
        self.buffers = allocated
    }

    /// Copy `source` into the next ring slot and return it. Returns nil only if the
    /// source is larger than the pre-allocated capacity or is not float — both
    /// outside steady state — so the caller drops rather than allocates.
    func copyInto(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(source.frameLength)
        guard AVAudioFrameCount(frames) <= buffers[index].frameCapacity,
            let src = source.floatChannelData
        else { return nil }
        let destination = buffers[index]
        index = (index + 1) % buffers.count
        destination.frameLength = source.frameLength
        guard let dst = destination.floatChannelData else { return nil }
        for channel in 0..<Int(source.format.channelCount) {
            memcpy(dst[channel], src[channel], frames * MemoryLayout<Float>.size)
        }
        return destination
    }
}

/// Deep-copy a PCM buffer (allocates). Used off the realtime path — for SCStream
/// and tap buffers, which are already owned but only valid for the callback. The
/// realtime mic tap uses `PCMBufferPool` instead to avoid allocating on its thread.
func copyPCM(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)
    else { return nil }
    copy.frameLength = buffer.frameLength
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)
    if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
        for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size) }
    } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
        for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size) }
    } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
        for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size) }
    } else {
        return nil
    }
    return copy
}

// MARK: - Format conversion (AVAudioConverter)

final class BufferConverter {
    enum ConversionError: Swift.Error { case cannotCreateConverter, cannotCreateBuffer, conversionFailed(NSError?) }
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.cannotCreateConverter }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else {
            throw ConversionError.cannotCreateBuffer
        }
        var consumed = false
        var nsError: NSError?
        let status = converter.convert(to: out, error: &nsError) { _, statusPtr in
            defer { consumed = true }
            statusPtr.pointee = consumed ? .noDataNow : .haveData
            return consumed ? nil : buffer
        }
        if status == .error { throw ConversionError.conversionFailed(nsError) }
        return out
    }
}

// MARK: - Per-lane transcription pipeline (Apple Speech / SpeechAnalyzer)

actor LanePipeline {
    let lane: String
    let speaker: String
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let converter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    init(lane: String, speaker: String, locale: Locale) {
        self.lane = lane
        self.speaker = speaker
        self.transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func start() async throws {
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let lane = self.lane
        let speaker = self.speaker
        resultsTask = Task { [transcriber] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if text.isEmpty { continue }
                    emit([
                        "type": result.isFinal ? "segment.final" : "segment.partial",
                        "lane": lane,
                        "speaker": speaker,
                        "text": text,
                        "start_ms": 0,
                        "end_ms": 0,
                    ])
                }
            } catch {
                logErr("lane \(lane) results error: \(error)")
            }
        }
        try await analyzer.start(inputSequence: sequence)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let continuation else { return }
        do {
            let converted = try converter.convert(buffer, to: analyzerFormat)
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            logErr("lane \(lane) convert error: \(error)")
        }
    }

    func finish() async {
        continuation?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
    }
}

// MARK: - Capture lane: bounded realtime handoff + single consumer

/// One capture lane. The realtime source calls `submit(_:)` (non-blocking yield
/// into a bounded stream). A single `runConsumer()` task drains it: RMS + level
/// emit + feed the transcriber. Overflow is counted and surfaced as
/// `audio.dropped` — lost transcript is never silent.
final class CaptureLane: @unchecked Sendable {
    let lane: String
    let pipeline: LanePipeline
    private let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let dropped = Atomic<Int>(0)

    /// ~64 buffers of headroom (several seconds at typical buffer sizes). The
    /// consumer (convert + feed) easily keeps up in steady state, so this never
    /// drops in practice; if it ever does, the overflow is reported, not hidden.
    init(lane: String, speaker: String, locale: Locale, bufferCap: Int = 64) {
        self.lane = lane
        self.pipeline = LanePipeline(lane: lane, speaker: speaker, locale: locale)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferCap))
        self.stream = stream
        self.continuation = continuation
    }

    func start() async throws { try await pipeline.start() }

    /// Called from a realtime audio thread. Non-blocking: yield or count a drop.
    func submit(_ buffer: AVAudioPCMBuffer) {
        switch continuation.yield(buffer) {
        case .dropped:
            dropped.wrappingAdd(1, ordering: .relaxed)
        default:
            break
        }
    }

    /// Signal end-of-input so the consumer drains remaining buffers and returns.
    func finishInput() { continuation.finish() }

    func runConsumer() async {
        var windowSum: Float = 0
        var windowPeak: Float = 0
        var windowFrames: Int = 0
        var capturedMs: Double = 0
        var lastEmit: Double = 0
        var reportedDropped = 0

        func reportDropsIfAny() {
            let d = dropped.load(ordering: .relaxed)
            if d > reportedDropped {
                reportedDropped = d
                emit(["type": "audio.dropped", "lane": lane, "count": d])
            }
        }

        for await buffer in stream {
            let sampleRate = buffer.format.sampleRate
            let frames = Int(buffer.frameLength)
            let (r, p) = rms(of: buffer)
            windowSum += r * r * Float(frames)
            windowPeak = max(windowPeak, p)
            windowFrames += frames
            if sampleRate > 0 { capturedMs += Double(frames) / sampleRate * 1000.0 }
            if capturedMs - lastEmit >= 1000.0 {
                let meanRms = windowFrames > 0 ? (windowSum / Float(windowFrames)).squareRoot() : 0
                emit([
                    "type": "audio.level",
                    "lane": lane,
                    "rms": Double(meanRms),
                    "peak": Double(windowPeak),
                    "captured_ms": Int(capturedMs),
                ])
                lastEmit = capturedMs
                windowSum = 0
                windowPeak = 0
                windowFrames = 0
                reportDropsIfAny()
            }
            await pipeline.feed(buffer)
        }
        reportDropsIfAny()
    }
}

// MARK: - System audio capture (Core Audio Process Tap — primary, output-independent)

/// Captures system audio via a Core Audio process tap + private aggregate device.
/// Unlike ScreenCaptureKit, this is NOT coupled to the output device, so it works
/// when the default output is HDMI/Bluetooth (where SCStream delivers zero frames).
/// It needs the `kTCCServiceAudioCapture` ("System Audio Recording Only") grant,
/// detected by attempt-and-classify (no public pre-check API). Non-destructive:
/// `muteBehavior = .unmuted` keeps the call audible to the operator.
///
/// macOS 14.2+. The flow follows insidegui/AudioCap and Apple's "Capturing system
/// audio with Core Audio taps": describe a global mixdown tap → create the tap →
/// read its format → build a private aggregate device with the tap as a sub-tap
/// and the real default output as the main sub-device (tap-as-main with no real
/// sub-device yields silence) with drift correction on → install an IOProc block
/// (its own dispatch queue, no CFRunLoop) → start.
@available(macOS 14.2, *)
final class SystemAudioTap {
    enum TapError: Error { case notPermitted(OSStatus), setupFailed(OSStatus, String) }

    /// `kAudioHardwareNotPermittedError` ('nope', 0x6E6F7065) is the
    /// System-Audio-Recording-denied status, but it isn't surfaced as a Swift
    /// symbol — define it from its FourCC value.
    static let notPermittedStatus: OSStatus = 1_852_797_029

    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let ioQueue = DispatchQueue(label: "standby.capture.tap.io")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() throws {
        // Self-heal: destroy any of OUR private aggregate devices left over from a
        // previous run that didn't tear down (a kill -9 skips teardown). Leaked
        // aggregates accumulate in the HAL and can hang new aggregate creation.
        Self.destroyOrphanedAggregates()

        // Clean up any partially-created CoreAudio objects on ANY failure path so a
        // throw (e.g. aggregate creation fails after the tap exists) never leaks a
        // process tap or aggregate device.
        var succeeded = false
        defer { if !succeeded { teardown() } }

        // 1. Global tap of ALL process output (every participant), excluding none.
        //    CRITICAL: `stereoMixdownOfProcesses: []` taps ZERO processes (silence) —
        //    it mixes down the *listed* processes, and the list is empty. The
        //    global-tap-but-exclude initializer is what captures everything; an
        //    empty exclude list means "exclude nothing". (Compiles either way; only
        //    live capture reveals the difference — it did.) The operator's own mic
        //    does not flow to local output, so a per-PID tap is a later mic-bleed
        //    refinement, not needed for correctness here.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "StandbyCaptureTap"
        description.isPrivate = true
        description.isExclusive = false
        description.muteBehavior = .unmuted  // keep the call audible — non-destructive

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &newTap)
        if createStatus == Self.notPermittedStatus {
            throw TapError.notPermitted(createStatus)
        }
        guard createStatus == noErr, newTap != kAudioObjectUnknown else {
            throw TapError.setupFailed(createStatus, "AudioHardwareCreateProcessTap")
        }
        tapID = newTap

        // 2. The tap's stream format.
        let tapFormat = try Self.readTapFormat(tapID)
        self.format = tapFormat
        logErr("tap format: \(tapFormat.sampleRate)Hz ch=\(tapFormat.channelCount) interleaved=\(tapFormat.isInterleaved) commonFormat=\(tapFormat.commonFormat.rawValue)")

        // 3. Private aggregate device exposing the tap. Follows the minimal working
        //    reference (MiniMeters gist / insidegui/AudioCap): the TAP alone drives
        //    the aggregate — NO hardware sub-device, NO main sub-device. Live-tested:
        //    adding the default output as a main sub-device prevented the IOProc from
        //    ever firing on this machine. A tap-only aggregate also sidesteps
        //    hardware/tap clock drift entirely (there is no second clock to drift).
        let aggUID = "com.standby.capture.aggregate.\(description.uuid.uuidString)"
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "StandbyCaptureAggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: false,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: description.uuid.uuidString]
            ],
        ]

        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAgg)
        guard aggStatus == noErr, newAgg != kAudioObjectUnknown else {
            throw TapError.setupFailed(aggStatus, "AudioHardwareCreateAggregateDevice")
        }
        aggregateID = newAgg
        // NOTE: setting kAudioDevicePropertyBufferFrameSize on the aggregate HANGS
        // the HAL here (live-tested — wedges between tap-format and tap-start). The
        // tap delivers ~512-frame buffers (~93/sec); the per-buffer overhead is
        // reduced in software instead (see the coalescing accumulator below).

        // 4. IOProc on the aggregate. The block runs on ioQueue (no CFRunLoop). It
        //    wraps the input buffer list no-copy, copies it (the list is only valid
        //    for the call), and hands the owned buffer to the lane.
        let onBuffer = self.onBuffer
        let fmt = tapFormat
        // Coalesce the tap's small (~512-frame) buffers into ~4096-frame chunks so
        // the downstream convert + transcriber feed runs ~12/sec instead of ~93/sec.
        // The small-buffer rate (live-tested) starved the mic lane's consumer and
        // dropped ~25% of its audio over a 10-min capture. The IOProc is serial on
        // ioQueue, so the accumulator needs no lock. (Setting the device buffer size
        // directly hangs the HAL, so we coalesce in software instead.)
        let coalesceTarget: AVAudioFrameCount = 4096
        guard let accumulator = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: coalesceTarget + 1024)
        else { throw TapError.setupFailed(0, "could not allocate tap coalescing buffer") }
        var accumFrames: AVAudioFrameCount = 0
        let firstCall = Atomic<Bool>(true)
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) {
            _, inInputData, _, _, _ in
            if firstCall.exchange(false, ordering: .relaxed) {
                logErr("tap ioproc firing (coalescing to \(coalesceTarget) frames)")
            }
            guard let wrapped = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInputData),
                let src = wrapped.floatChannelData, let dst = accumulator.floatChannelData
            else { return }
            let incoming = wrapped.frameLength
            if incoming == 0 { return }
            let toCopy = min(incoming, accumulator.frameCapacity - accumFrames)
            memcpy(
                dst[0].advanced(by: Int(accumFrames)), src[0],
                Int(toCopy) * MemoryLayout<Float>.size)
            accumFrames += toCopy
            if accumFrames >= coalesceTarget {
                accumulator.frameLength = accumFrames
                if let owned = copyPCM(accumulator) { onBuffer(owned) }
                accumFrames = 0
            }
        }
        guard procStatus == noErr, let proc = newProc else {
            throw TapError.setupFailed(procStatus, "AudioDeviceCreateIOProcIDWithBlock")
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            throw TapError.setupFailed(startStatus, "AudioDeviceStart")
        }
        succeeded = true
    }

    func stop() { teardown() }

    /// Idempotent teardown of every CoreAudio object, in reverse creation order.
    /// Safe to call on a partially-started tap (the start() failure path).
    private func teardown() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func readTapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.setupFailed(status, "kAudioTapPropertyFormat")
        }
        return format
    }

    /// Destroy any private aggregate devices we created in a previous run (matched
    /// by our UID prefix) that were leaked by an abnormal exit. Best-effort and
    /// scoped to our own devices — never touches another app's aggregate.
    private static func destroyOrphanedAggregates() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices)
                == noErr
        else { return }
        for device in devices where device != kAudioObjectUnknown {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &uid) {
                AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
            }
            if status == noErr, (uid as String).hasPrefix("com.standby.capture.aggregate") {
                AudioHardwareDestroyAggregateDevice(device)
                logErr("cleaned up orphaned aggregate \(uid as String)")
            }
        }
    }
}

// MARK: - System audio capture (ScreenCaptureKit — fallback lane for older OS / built-in output)

final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let sampleQueue = DispatchQueue(label: "standby.capture.system")

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "standby", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer(pcm)
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return pcm
    }
}

// MARK: - Stop signal (SIGTERM/SIGINT/--seconds on a DEDICATED queue, not .main)

/// Resolves exactly once, from a signal source or a timer, both serviced on a
/// dedicated dispatch queue. Critically NOT `.main`: under async main the helper
/// must not depend on the main dispatch queue being pumped for shutdown to work —
/// that coupling is what made the old build SIGTERM-immune.
final class StopSignal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "standby.capture.signals")
    private var reason: String?
    private var continuation: CheckedContinuation<String, Never>?
    private var sources: [DispatchSourceSignal] = []

    /// Arm handlers immediately (before long capture setup) so an early SIGTERM is
    /// captured rather than dropped. Set the SIG_IGN disposition SYNCHRONOUSLY so a
    /// signal arriving before the async block runs can't trigger the default
    /// terminate action; the dispatch sources (created on `queue`) then observe it.
    func arm(seconds: Double?) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        queue.async {
            for sig in [SIGINT, SIGTERM] {
                let src = DispatchSource.makeSignalSource(signal: sig, queue: self.queue)
                let name = sig == SIGINT ? "sigint" : "sigterm"
                src.setEventHandler { self.fire(name) }
                src.resume()
                self.sources.append(src)
            }
            if let seconds {
                self.queue.asyncAfter(deadline: .now() + seconds) { self.fire("timeout") }
            }
        }
    }

    func wait() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            queue.async {
                if let reason = self.reason {
                    cont.resume(returning: reason)
                } else {
                    self.continuation = cont
                }
            }
        }
    }

    /// Always runs on `queue`. Resolves once; later signals are ignored.
    private func fire(_ r: String) {
        guard reason == nil else { return }
        reason = r
        continuation?.resume(returning: r)
        continuation = nil
    }
}

// MARK: - Argument parsing

func argValue(_ name: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else {
    logErr("usage: standby-capture-helper <transcribe-file|capture> [options]")
    exit(2)
}
let localeId = argValue("--locale", in: arguments) ?? "en-US"
let locale = Locale(identifier: localeId)

// MARK: - transcribe-file

func runTranscribeFile(path: String) async {
    do {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if !(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
            .contains(locale.identifier(.bcp47))
        {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        async let collected: String = {
            var acc = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                acc += text
                emit(["type": "transcribe.final", "text": text, "start_ms": 0, "end_ms": 0])
            }
            return acc
        }()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let full = try await collected
        emit(["type": "transcribe.done", "text": full])
        flushStdout()
        exit(0)
    } catch {
        failAndExit(reason: "unknown", lane: nil, detail: "transcribe-file: \(error)")
    }
}

// MARK: - capture

func runCapture(mode: String, seconds: Double?) async {
    let wantsMic = mode.contains("mic")
    let wantsSystem = mode.contains("system")
    guard wantsMic || wantsSystem else {
        failAndExit(reason: "unsupported", lane: nil, detail: "mode must include mic and/or system")
    }

    // Arm stop handlers BEFORE any long setup so an early SIGTERM is never lost.
    let stop = StopSignal()
    stop.arm(seconds: seconds)

    var lanes: [CaptureLane] = []
    let engine = AVAudioEngine()
    // Teardown for the Core Audio tap, set once acquired (on a background queue) and
    // read by the stop task — guarded because they run on different threads. The
    // accessors are synchronous so the lock is never taken from an async context.
    let sysLock = NSLock()
    var systemTeardown: (() -> Void)?
    func setSystemTeardown(_ td: @escaping () -> Void) {
        sysLock.lock(); systemTeardown = td; sysLock.unlock()
    }
    func takeSystemTeardown() -> (() -> Void)? {
        sysLock.lock(); defer { sysLock.unlock() }; return systemTeardown
    }

    // A system-lane failure is NON-FATAL when the microphone lane is running: the
    // mic keeps capturing and the system lane is reported failed. Only a
    // system-only capture treats a system failure as fatal (nothing else to record).
    func failSystemLane(_ reason: String, _ detail: String) {
        emit(["type": "source.failed", "reason": reason, "lane": "system_audio", "detail": detail])
        if !wantsMic {
            flushStdout()
            exit(1)
        }
        logErr("system lane failed (\(reason)); microphone capture continues")
    }

    // Microphone lane (output-independent; always available once granted).
    if wantsMic {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard granted else {
            failAndExit(reason: "mic_permission_denied", lane: "microphone", detail: nil)
        }
        let lane = CaptureLane(lane: "microphone", speaker: "me", locale: locale)
        do { try await lane.start() } catch {
            failAndExit(reason: "unknown", lane: "microphone", detail: "mic transcriber: \(error)")
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Pre-allocate the ring HERE (off the render thread). Capacity 2× the tap
        // buffer size absorbs occasional larger callbacks; 96 slots exceed the lane
        // stream's 64-buffer cap so a slot is always free by the time the ring
        // wraps. If allocation fails, degrade to per-callback copyPCM.
        let micPool = PCMBufferPool(format: format, frameCapacity: 8192, count: 96)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Realtime thread: copy into a pre-allocated slot (no malloc) + yield.
            if let owned = micPool?.copyInto(buffer) ?? copyPCM(buffer) {
                lane.submit(owned)
            }
        }
        do { try engine.start() } catch {
            failAndExit(reason: "no_input_device", lane: "microphone", detail: "\(error)")
        }
        lanes.append(lane)
    }

    // System-audio lane via the Core Audio tap. The tap is acquired on a DEDICATED
    // background queue, decoupled from the consumer TaskGroup: tap.start() is
    // synchronous and a HAL call inside can wedge, and it must NEVER block the mic
    // lane or shutdown. The lane's consumer runs in the group regardless; if the tap
    // never feeds it, it idles until stop. The OS floor is macOS 26 (SpeechAnalyzer),
    // so the 14.2+ tap is always available — SystemAudioCapture (ScreenCaptureKit)
    // is retained as a type but unused on this deployment.
    let systemSettled = Atomic<Bool>(false)
    func settleSystemFailure(_ reason: String, _ detail: String) {
        guard systemSettled.exchange(true, ordering: .relaxed) == false else { return }
        failSystemLane(reason, detail)
    }
    if wantsSystem {
        let lane = CaptureLane(lane: "system_audio", speaker: "system_audio", locale: locale)
        var transcriberOK = true
        do { try await lane.start() } catch {
            transcriberOK = false
            settleSystemFailure("unknown", "system transcriber: \(error)")
        }
        if transcriberOK {
            lanes.append(lane)
            DispatchQueue.global(qos: .userInitiated).async {
                guard #available(macOS 14.2, *) else {
                    settleSystemFailure("system_audio_unsupported_os", "Core Audio taps need macOS 14.2+")
                    return
                }
                let tap = SystemAudioTap { buffer in lane.submit(buffer) }
                let tapDone = Atomic<Bool>(false)
                // A HAL wedge in tap.start() leaks this one background thread but
                // never blocks the mic lane or shutdown; the watchdog reports it.
                armWatchdog(8) {
                    if !tapDone.load(ordering: .relaxed) {
                        settleSystemFailure(
                            "unknown",
                            "Core Audio tap setup did not complete in 8s (HAL wedge); try `sudo killall coreaudiod`")
                    }
                }
                do {
                    try tap.start()
                    tapDone.store(true, ordering: .relaxed)
                    if systemSettled.exchange(true, ordering: .relaxed) == false {
                        setSystemTeardown { tap.stop() }
                        logErr("system audio: Core Audio process tap active (output-independent)")
                    } else {
                        tap.stop()  // watchdog already failed the lane; don't leak the late tap
                    }
                } catch SystemAudioTap.TapError.notPermitted {
                    tapDone.store(true, ordering: .relaxed)
                    settleSystemFailure(
                        "system_audio_permission_denied",
                        "grant System Settings › Privacy & Security › System Audio Recording")
                } catch {
                    tapDone.store(true, ordering: .relaxed)
                    settleSystemFailure("unknown", "tap setup failed: \(error)")
                }
            }
        }
    }

    emit(["type": "source.started", "mode": mode, "mic": wantsMic, "system": wantsSystem])

    // Consumers + stop task under one structured group. Realtime callbacks keep
    // yielding into each lane's bounded stream concurrently; when stop fires we
    // stop the sources and finish the inputs, the consumers drain and return, and
    // only then do we finalize the transcribers (so no buffer is fed post-finalize).
    await withTaskGroup(of: Void.self) { group in
        for lane in lanes {
            group.addTask { await lane.runConsumer() }
        }
        group.addTask {
            let reason = await stop.wait()
            logErr("stop requested: \(reason)")
            engine.stop()
            if wantsMic { engine.inputNode.removeTap(onBus: 0) }
            takeSystemTeardown()?()
            for lane in lanes { lane.finishInput() }
        }
        await group.waitForAll()
    }

    for lane in lanes { await lane.pipeline.finish() }
    emit(["type": "source.stopped"])
    flushStdout()
    exit(0)
}

// MARK: - Dispatch (async top-level main — NO dispatchMain)

switch subcommand {
case "transcribe-file":
    guard arguments.count >= 2 else {
        logErr("usage: standby-capture-helper transcribe-file <path>")
        exit(2)
    }
    await runTranscribeFile(path: arguments[1])
case "capture":
    let mode = argValue("--mode", in: arguments) ?? "mic+system"
    let seconds = argValue("--seconds", in: arguments).flatMap(Double.init)
    await runCapture(mode: mode, seconds: seconds)
default:
    logErr("unknown subcommand: \(subcommand)")
    exit(2)
}
