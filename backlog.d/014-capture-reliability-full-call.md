# Make capture survive a full real meeting

Priority: P1 · Status: pending · Estimate: L

## Goal
A solo operator on a 30-minute live Meet/Teams call captures their own mic AND remote participants reliably — surviving a mid-call device switch, a helper crash, and a mutex panic — with honest degraded states when a lane dies.

## Oracle
- [ ] A long-soak gate fails when the mic lane is frozen-silent (asserts on recent-window mic RMS activity, not monotonic `level_events`).
- [ ] `LaneState.active` is window-based (or `last_active_ms`): a lane that goes active then freezes degrades to `NoMicAudio`/`NoSystemAudio` instead of reporting healthy forever.
- [ ] A mid-call default-output change (AirPods/HDMI) rebuilds the aggregate without losing the system lane.
- [ ] A helper crash mid-meeting auto-restarts with bounded backoff (or degrades to honest `SOURCE_FAILED`); a mutex poisoning cannot kill the capture task.
- [ ] Decision recorded for mic-during-call: either a VPIO full-duplex graph delivers nonzero mic RMS while a real AEC call holds the mic, OR mic-in-call is documented as a known limitation and remote-participant capture leads.

## Verification System
- Claim: capture is reliable for a full real call, and lies about liveness are impossible.
- Falsifier: a frozen mic reports "live"; a device switch silences the system lane; a helper crash ends capture silently; the ship gate passes a build with the 9-min freeze.
- Driver: fix + wire `verify-capture-longrun.sh` and `verify-capture-meeting-duration.sh` into a scheduled macOS CI lane; reproduce mic-during-call on a live Meet call.
- Grader: recent-window RMS activity per lane; exactly-one helper after restart; honest lane states.
- Evidence packet: `docs/evidence/real-meeting/capture-reliability/`.
- Cadence: scheduled macOS lane + before any "full-meeting" claim.

## Children
1. Fix the ship gate to catch the freeze: make `verify-capture-meeting-duration.sh` assert on recent-window mic RMS (`STANDBY_LONGRUN_PLAY=1`), and make `LaneState.active` window-based / add `last_active_ms` so the projection degrades honestly. `verify-capture-longrun.sh:170-176`; `event_log.rs:148-150`; `domain.rs:175`.
2. Wire the orphaned capture gates (`verify-capture-longrun`, `-meeting-duration`, `-system-audio-tap`) into a scheduled, permission-granted macOS CI lane; gate the output-independent mic-liveness assertion even on a vanilla runner. *(Absent from `verify.sh` & `verify-ci.sh` today.)*
3. Harden capture supervision (Rust): replace the 7 `.expect("...lock")` in `capture.rs` with poison-tolerant access; add a helper heartbeat/liveness watchdog; auto-restart on `HelperCrashed` with bounded backoff; rebuild the in-memory pid map on startup. `capture.rs:57-168`; `main.rs:36,283,518`.
4. Mic-during-call spike (TIME-BOXED): finish the VPIO full-duplex graph (input wired to a live output as echo reference) and prove nonzero mic RMS while a real AEC call holds the mic. If the spike disproves it, fall back to documenting mic-in-call as a limitation and leading with remote-participant capture (already works). REJECT per-process tap of the meeting app as a mic substitute — a process tap captures *output* (remote audio), not the operator's mic. `main.swift:912-942`; `real-meeting-followups.md:23-37`.
5. HAL device-change listeners (default-input AND default-output) that rebuild the engine/aggregate on hot-plug; per-lane partial transcript keyed by lane/speaker so concurrent mic+remote captions both render. `main.swift:611-632`; `event_log.rs:111,161-178`.

## Notes
**Why:** Capture lane + Runtime lane converged. The headline mic-during-call bug is real and unfixed — VPIO is a dead opt-in the code itself says freezes (`main.swift:912-942`). The ~9-min mic stall has zero detection and `LaneState.active` latches, so a frozen mic reports healthy (`event_log.rs:148-150`; `domain.rs:175`) — and critically the 10-min "ship gate" keys on monotonic `level_events` which climb even when the mic is frozen-silent, so it cannot catch the bug it was built for (`verify-capture-longrun.sh:170-176`). The only genuine production panic risk in the Rust is the 7 `.expect()` on mutex locks in `capture.rs` (poisoning kills capture mid-meeting).

Premise-challenger reframe: mic capture IS necessary (system audio is the output mixdown and does not include the operator's mic), but the investment path should be re-ranked — time-box the hard VPIO spike against option (c) rather than letting it block product-ready. External best-practice validation for this was the one swarm lane that did not run (web research rejected on interrupt), which is exactly why child #4 is a spike, not a build.

The "157 non-test panics" framing was a grep artifact: `src/*.rs` has ~0 production unwraps (both Runtime and Simplification lanes verified) — do NOT file a 157-panic ticket; the real surface is the 7 `capture.rs` locks in child #3.
