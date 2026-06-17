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
// Subcommands:
//   transcribe-file <path> [--locale en-US]
//       Deterministic offline transcription of an audio file. Emits
//       transcribe.final per phrase and transcribe.done with the full text.
//   capture --mode mic|system|mic+system [--seconds N] [--locale en-US]
//       Live capture. Emits source.started, audio.level per lane, segment
//       partial/final per lane, and source.failed | source.stopped.
//
// Output event shapes (one JSON object per line):
//   {"type":"source.started","mode":"mic+system","mic":true,"system":true}
//   {"type":"audio.level","lane":"microphone","rms":0.04,"peak":0.2,"captured_ms":1000}
//   {"type":"segment.partial","lane":"microphone","speaker":"me","text":"...","start_ms":0,"end_ms":0}
//   {"type":"segment.final","lane":"system_audio","speaker":"system_audio","text":"...","start_ms":0,"end_ms":0}
//   {"type":"source.failed","reason":"screen_recording_permission_denied","lane":"system_audio","detail":"..."}
//   {"type":"source.stopped"}
//   {"type":"transcribe.final","text":"...","start_ms":0,"end_ms":2533}
//   {"type":"transcribe.done","text":"..."}

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

// MARK: - Output

let stdoutQueue = DispatchQueue(label: "standby.capture.stdout")

func emit(_ object: [String: Any]) {
    stdoutQueue.sync {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

func logErr(_ message: String) {
    FileHandle.standardError.write(("standby-capture-helper: " + message + "\n").data(using: .utf8)!)
}

func failAndExit(reason: String, lane: String?, detail: String?) -> Never {
    var event: [String: Any] = ["type": "source.failed", "reason": reason]
    if let lane { event["lane"] = lane }
    if let detail { event["detail"] = detail }
    emit(event)
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

// MARK: - Per-lane transcription pipeline

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

// MARK: - Level reporting (throttled to ~1/sec per lane)

final class LevelMeter {
    private let lane: String
    private let queue = DispatchQueue(label: "standby.capture.level")
    private var windowSum: Float = 0
    private var windowPeak: Float = 0
    private var windowFrames: Int = 0
    private var capturedMs: Double = 0
    private var lastEmit: Double = 0
    private let sampleRate: Double

    init(lane: String, sampleRate: Double) {
        self.lane = lane
        self.sampleRate = sampleRate
    }

    func observe(rms: Float, peak: Float, frames: Int) {
        queue.sync {
            windowSum += rms * rms * Float(frames)
            windowPeak = max(windowPeak, peak)
            windowFrames += frames
            capturedMs += Double(frames) / sampleRate * 1000.0
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
            }
        }
    }
}

// MARK: - System audio capture (ScreenCaptureKit)

final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let sampleQueue = DispatchQueue(label: "standby.capture.system")

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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

    let micPipeline = wantsMic ? LanePipeline(lane: "microphone", speaker: "me", locale: locale) : nil
    let systemPipeline =
        wantsSystem ? LanePipeline(lane: "system_audio", speaker: "system_audio", locale: locale) : nil

    let engine = AVAudioEngine()
    // Set once during setup, then only read by the stop handler.
    nonisolated(unsafe) var systemCapture: SystemAudioCapture?

    // Microphone lane
    if wantsMic {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard granted else {
            failAndExit(reason: "mic_permission_denied", lane: "microphone", detail: nil)
        }
        do { try await micPipeline?.start() } catch {
            failAndExit(reason: "unknown", lane: "microphone", detail: "mic transcriber: \(error)")
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let meter = LevelMeter(lane: "microphone", sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let (r, p) = rms(of: buffer)
            meter.observe(rms: r, peak: p, frames: Int(buffer.frameLength))
            Task { await micPipeline?.feed(buffer) }
        }
        do { try engine.start() } catch {
            failAndExit(reason: "no_input_device", lane: "microphone", detail: "\(error)")
        }
    }

    // System audio lane
    if wantsSystem {
        do { try await systemPipeline?.start() } catch {
            failAndExit(reason: "unknown", lane: "system_audio", detail: "system transcriber: \(error)")
        }
        let meter = LevelMeter(lane: "system_audio", sampleRate: 48_000)
        let capture = SystemAudioCapture { buffer in
            let (r, p) = rms(of: buffer)
            meter.observe(rms: r, peak: p, frames: Int(buffer.frameLength))
            Task { await systemPipeline?.feed(buffer) }
        }
        do {
            try await capture.start()
            systemCapture = capture
        } catch {
            failAndExit(
                reason: "screen_recording_permission_denied", lane: "system_audio", detail: "\(error)")
        }
    }

    emit(["type": "source.started", "mode": mode, "mic": wantsMic, "system": wantsSystem])

    func stopAll() async {
        engine.stop()
        if wantsMic { engine.inputNode.removeTap(onBus: 0) }
        await systemCapture?.stop()
        await micPipeline?.finish()
        await systemPipeline?.finish()
        emit(["type": "source.stopped"])
        exit(0)
    }

    // SIGINT/SIGTERM → graceful stop
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigint.setEventHandler { Task { await stopAll() } }
    sigterm.setEventHandler { Task { await stopAll() } }
    sigint.resume()
    sigterm.resume()

    if let seconds {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await stopAll()
        }
    }
}

// MARK: - Dispatch

switch subcommand {
case "transcribe-file":
    guard arguments.count >= 2 else {
        logErr("usage: standby-capture-helper transcribe-file <path>")
        exit(2)
    }
    Task { await runTranscribeFile(path: arguments[1]) }
    dispatchMain()
case "capture":
    let mode = argValue("--mode", in: arguments) ?? "mic+system"
    let seconds = argValue("--seconds", in: arguments).flatMap(Double.init)
    Task { await runCapture(mode: mode, seconds: seconds) }
    dispatchMain()
default:
    logErr("unknown subcommand: \(subcommand)")
    exit(2)
}
