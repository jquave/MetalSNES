# MetalSNES Development Log

## 2026-03-10: Hybrid Metal PPU Path for Common Frames

### Findings
- The previous "Metal renderer" was only presenting a CPU-rendered RGBA framebuffer. The expensive tile/sprite composition work was still entirely in `PPU.swift`.
- A full accuracy-first GPU rewrite would need mid-frame VRAM/OAM/CGRAM history for raster effects, which is larger than a single-pass optimization change.
- The practical first step is a hybrid path:
  - use Metal compute for common frames where the current renderer does not need color math or window masking,
  - keep the existing CPU renderer as the correctness fallback for everything else.

### Changes
- Added a GPU frame-state path in `PPU.swift`:
  - per-scanline render state snapshots (`GPULineState`),
  - flattened per-scanline sprite caches for GPU consumption,
  - and per-frame selection between CPU rendering and the new Metal path.
- Extended `Shaders.metal` with a compute kernel that renders:
  - modes 0/1/2/3/4/5/6/7 using the current simplified repo behavior,
  - tilemap backgrounds from VRAM/CGRAM state,
  - sprite composition with the same priority ordering used by the CPU path,
  - and writes directly into the Metal texture before the presentation pass.
- Reworked `MetalRenderer.swift` so it can either:
  - upload a CPU framebuffer, or
  - upload VRAM/OAM/palette/scanline-state buffers and run the compute PPU pass.
- `EmulatorCore.swift` now selects the GPU renderer only when the Metal path is available; benchmark and headless paths continue to use the CPU renderer.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
- CPU fallback benchmark still works:
  - `120 frames in 9.947 sec = 12.1 FPS`
  - `CPU+SPC: 4165 ms (42%), PPU: 5777 ms (58%)`
- A 5-second GUI smoke run of `/tmp/MetalSNESDerived/Build/Products/Debug/MetalSNES.app/Contents/MacOS/MetalSNES --rom mario.sfc` produced no captured runtime/shader errors.

## 2026-03-10: Hybrid Metal PPU Path Expansion for Subscreen Color Math

### Findings
- The first Metal PPU pass still fell back to the CPU whenever `C GWSEL` requested blending with the subscreen and `TS` enabled any real layers.
- That left a meaningful amount of common SNES transparency work on the CPU even when the frame did not use any window masks.
- Supporting the no-window subscreen case is a good next step because it materially expands GPU coverage without needing a full rewrite of the window system or raster-history handling.

### Changes
- `PPU.swift` no longer rejects GPU rendering solely because the subscreen mask `TS` is non-zero.
- `Shaders.metal` now factors layer composition into a reusable helper and renders both:
  - the main screen from `TM`, and
  - the subscreen from `TS` when color math blends against the subscreen.
- The Metal color-math path now matches the existing CPU approximation more closely by:
  - using the actual subscreen pixel instead of always falling back to backdrop,
  - and only applying half-color on subscreen blends when the below pixel is a real layer rather than plain backdrop.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded after the shader changes.
- A fresh 5-second GUI smoke run of `/tmp/MetalSNESDerived/Build/Products/Debug/MetalSNES.app/Contents/MacOS/MetalSNES --rom mario.sfc` again produced no captured runtime/shader errors.

## 2026-03-10: Metal Window Masks + DSP/APU Hot-Path Cleanup

### Findings
- After subscreen blending support, the next major GPU coverage gap was window handling:
  - main-screen layer windows (`TMW`) still forced CPU fallback,
  - and color-window masks in `CGWSEL` still forced CPU fallback even when the frame used no subscreen windowing.
- Separately, the audio path still did avoidable diagnostic work in normal runs:
  - several APU/DSP hot paths formatted debug strings before `diagLog()` discarded them,
  - and DSP diagnostic file setup still happened eagerly at startup instead of only when debugging was actually enabled.

### Changes
- Expanded the Metal PPU path to cover the repo's current window behavior for the main screen:
  - added window register state to `GPULineState`,
  - ported per-layer window masking logic for BG1-BG4 and OBJ into `Shaders.metal`,
  - ported color-window gating for color math,
  - and relaxed GPU eligibility so frames no longer fall back solely because `TMW` or color-window masks are in use.
- Kept `TSW` as the remaining unsupported window case, so frames using sub-screen window masking still fall back to the CPU path.
- Cleaned up APU/DSP diagnostics:
  - debug string formatting on CPU→SPC and DSP register/KON paths is now gated by `EmulatorCore.debugLogging`,
  - DSP periodic diagnostic string construction is skipped when debug logging is off,
  - and the `/tmp/dsp_diag.log` file is now opened lazily only when a diagnostic write is actually needed.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
- CPU benchmark:
  - previous isolated baseline: `120 frames in 9.947 sec = 12.1 FPS`
  - after this pass: `120 frames in 9.791 sec = 12.3 FPS`
  - `CPU+SPC` time dropped from `4165 ms` to `3983 ms` in the current benchmark path.
- A fresh 5-second GUI smoke run of `/tmp/MetalSNESDerived/Build/Products/Debug/MetalSNES.app/Contents/MacOS/MetalSNES --rom mario.sfc` produced no captured runtime/shader errors.

## 2026-03-10: TSW Sub-screen Windows + Headless GPU Benchmark

### Findings
- The CPU renderer still did not apply `TSW` sub-screen window masking at all; it only respected `TMW` on the main screen.
- That meant the Metal path could not honestly support `TSW` until the baseline renderer was fixed too.
- The project also still lacked a way to measure GPU composition directly. The existing `--benchmark` mode only exercised the CPU path, so it could not answer whether the Apple Silicon renderer was actually helping.

### Changes
- Fixed sub-screen window masking in `PPU.swift` by applying the same layer-window rules to the sub-screen path, using `TSW` instead of `TMW`.
- Expanded the Metal PPU path to support `TSW` as well:
  - the compute shader now chooses main-screen vs sub-screen window enable bits when composing layers,
  - and GPU eligibility no longer rejects frames solely because `TSW` is non-zero.
- Added a new CLI benchmark mode:
  - `--benchmark` keeps the CPU-only benchmark behavior,
  - `--benchmark-gpu` creates a headless `MetalRenderer`, runs the Metal PPU path offscreen, and measures the real compute/presentation cost without a visible window.
- Updated `EmulatorCore.benchmark()` to time frame presentation separately so the GPU benchmark can distinguish CPU+SPC, PPU scanline work, and Metal presentation cost.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded after the `TSW` and benchmark changes.
- CPU benchmark after the `TSW` fix:
  - `120 frames in 9.867 sec = 12.2 FPS`
  - `CPU+SPC: 4041 ms (41%), PPU: 5822 ms (59%), Present: 0 ms (0%)`
- New headless GPU benchmark:
  - `120 frames in 4.130 sec = 29.1 FPS`
  - `CPU+SPC: 3991 ms (97%), PPU: 58 ms (1%), Present: 76 ms (2%)`
- A fresh 5-second GUI smoke run of `/tmp/MetalSNESDerived/Build/Products/Debug/MetalSNES.app/Contents/MacOS/MetalSNES --rom mario.sfc` again produced no captured runtime/shader errors.

## 2026-03-10: Performance Pass — Benchmark Isolation + PPU Hot-Path Cleanup

### Findings
- The CLI `--benchmark` path was still mounting the normal SwiftUI app scene, which meant `ContentView.onAppear` loaded a default ROM and auto-started a second emulator thread while the benchmark core was running. That made the earlier benchmark numbers noisier than they looked.
- The remaining renderer hotspot is still the CPU-side PPU path, especially:
  - per-pixel CGRAM conversion,
  - per-pixel bitplane extraction for 2bpp/4bpp/8bpp tiles and sprites,
  - and byte-at-a-time framebuffer writes.
- The live app was also doing avoidable debug work during normal play:
  - auto-starting the debug server every run,
  - and copying full VRAM/CGRAM/OAM snapshots every 10 frames even when the debug sidebar was closed.

### Changes
- Benchmark isolation:
  - benchmark mode now suppresses the normal `ContentView` scene so the CLI benchmark runs by itself,
  - and the app no longer activates the normal window path during `--benchmark`.
- Debug/trace overhead:
  - CPU write capture now only records when explicitly enabled for debug-server use,
  - unconditional DSP `KON` console logging is now gated behind `EmulatorCore.debugLogging`,
  - and the normal app run path no longer auto-starts the debug server.
- PPU hot-path work:
  - added a cached CGRAM `UInt32` color table updated on `CGRAM` writes,
  - added a precomputed 16-bit bitplane-pair decode table so tile/sprite rows no longer rebuild 2bpp values bit-by-bit for every pixel,
  - switched framebuffers/subscreen buffers to raw 32-bit pixel storage while preserving byte access for color math and upload,
  - reduced sprite scanline-cache work to only the visible scanline ranges for each sprite,
  - and added a fast path that skips color-window checks when color windows are disabled.
- Live debug UI overhead:
  - the emulator now only publishes debug snapshots when the debug sidebar is actually open.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
- Clean isolated benchmark:
  - `120 frames in 9.962 sec = 12.0 FPS (0.2x realtime)`
  - `CPU+SPC: 4176 ms (42%), PPU: 5782 ms (58%)`

## 2026-03-10: Overworld Ghosting + Audio Pops Follow-up

### Findings
- The first overworld transparency pass fixed stale sub-screen/fixed-color behavior, but it was not enough to fix the saved-state repro where Mario still looked partially transparent on the map.
- The remaining high-confidence PPU bug was that `PPU.swift` collapsed all sprite pixels into a single `OBJ` source for color math. On real hardware, color math only applies to `OBJ2` (sprite palettes 12-15 / CGRAM indices `>= 192`), while `OBJ1` never participates.
- That meant normal sprite palettes could be blended whenever OBJ math was enabled at all, which matches the "ghost-like Mario" symptom on the overworld.
- The audio popping investigation pointed at host-side buffering rather than the DSP mix itself:
  - the output ring buffer was small,
  - startup had no prebuffer,
  - overflow handling dropped the newest sample abruptly,
  - and there was no underrun/overrun telemetry in the debug endpoint.

### Changes
- PPU:
  - corrected color math setup so `$2130` bit 1 selects sub-screen vs fixed-color blending, while bits 4-7 are treated as color-window masks,
  - stopped re-deriving fixed color from the last raw `$2132` write and instead used the accumulated fixed-color channels,
  - cleared and reinitialized the sub-screen scanline buffer before sub-screen blending so stale below pixels do not leak into later frames,
  - split sprite source tagging into `OBJ1` vs `OBJ2` so only sprite palettes 12-15 are eligible for color math.
- Audio:
  - increased the host ring buffer size,
  - added a startup prebuffer to avoid immediate underruns,
  - changed overflow handling to discard the oldest queued sample rather than the newest one,
  - exposed underrun/overrun counters through `/audio/stats`.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Release -derivedDataPath /tmp/MetalSNESReleaseDerived build CODE_SIGNING_ALLOWED=NO` succeeded after both passes.
- The overworld `mario.state` repro was re-run in the `Release` app, and the user confirmed the updated build fixed the ghost-like Mario transparency issue.

## 2026-03-10: Markdown Audit — Repo Docs Reconciled With Current Code

### Findings
- Re-read every Markdown file in the repo (`README.md`, `ISSUES.md`, `AUDIO_DEBUG.md`, `DEVLOG.md`, `AGENTS.md`, `CLAUDE.md`) against the current tree.
- The stale items were concentrated in the audio/debug docs and the architecture overview:
  - README still described `renderMode7()` as a stub and had stale ownership notes for `CPU`.
  - ISSUES still claimed color math/sub-screen blending were missing, even though `PPU.swift` now renders a sub-screen path and applies additive/subtractive color math.
  - AUDIO_DEBUG still had an internal contradiction about the debug server being "off" while also documenting that the current app auto-starts it, and it still referenced the older 32-cycle DSP interleave.
  - DEVLOG still contained an older BG chr-base conclusion that no longer matches the current renderer or the rest of the repo docs.

### Changes
- Updated `README.md` to match the current PPU/APU feature set and current ownership/timing flow.
- Updated `ISSUES.md` so the remaining issue list reflects the current code, especially around audio timing and color math.
- Updated `AUDIO_DEBUG.md` to match current debug-server startup behavior, current endpoint coverage, and current audio fixes.
- Marked the older DEVLOG chr-base conclusion as a false lead instead of leaving it as an unqualified hardware claim.

## 2026-03-10: APU Timing Fix — SPC Was Scheduled at Half Clock Rate

### Findings
- The new symptom set after the SPC instruction fixes was: background music playing at roughly half speed and sound effects sounding wrong rather than simply silent.
- The root cause was in the APU scheduler, not the SMW script path. `SPC700.step()` returns raw S-SMP clock counts (`NOP = 2`, etc), but `APU.swift` was budgeting the SPC as if it ran at ~1.024 MHz and was generating DSP samples every 32 SPC clocks.
- The actual S-SMP clock domain is ~2.048 MHz (`24.576 MHz / 12`), and the DSP sample cadence is 64 SMP clocks per 32 kHz output sample.
- That meant the DSP audio stream itself was being produced at 32 kHz, but the SPC program/timer side was only advancing at about half the intended rate relative to that stream. That matches the user-facing symptom: music tempo roughly halved and SFX behavior sounding strange rather than fully broken.

### Changes
- Updated the APU SPC scanline budget to use the full ~2.048 MHz S-SMP clock domain.
- Updated DSP interleave cadence from 32 to 64 SPC clocks per generated sample.
- Kept the existing 32 kHz audio output rate; the fix is the relative SPC-to-DSP timing, not the host output format.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Release -derivedDataPath /tmp/MetalSNESReleaseDerived build CODE_SIGNING_ALLOWED=NO` succeeded after the timing patch.

## 2026-03-10: SPC700 Follow-up — WAIT/STOP Idle Semantics + Trace Fix

### Findings
- Compared our `SPC700.step()` flow against bsnes `SMP::main()` plus `instructionWait()` / `instructionStop()`.
- The previous implementation had two separate problems:
  - `SLEEP` (`$EF`) / `STOP` (`$FF`) rewound `PC`, which does not match bsnes.
  - once `sleeping/stopped` was set, later `step()` calls returned immediately with no bus read and almost no timing cost.
- bsnes keeps `PC` advanced after the opcode fetch and, while halted, repeatedly performs a read at the current `PC` plus an idle cycle. That means our old behavior was both control-flow wrong and timing-wrong.
- The SPC trace logger also had a real tooling bug: the end-of-scope `defer` ran before opcode execution, so the “post” register dump could actually be a pre-execution snapshot.

### Changes
- `SPC700.step()` now treats `sleeping/stopped` as a halted execution state that performs a read at the already-advanced `PC` and returns a 2-cycle idle step.
- `SLEEP` / `STOP` no longer rewind `PC`; they just enter the halted state and return the opcode cost for the entry instruction.
- Reworked the trace path so the trace context is captured before fetch and appended after the opcode switch returns, which makes the logged post-state reflect the actual post-instruction registers.

### Validation
- `xcodebuild -project /Users/jquave/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Release -derivedDataPath /tmp/MetalSNESReleaseDerived build CODE_SIGNING_ALLOWED=NO` succeeded after the change.

## 2026-03-10: SPC700 Review Follow-up — Remaining Class-Level Bugs

Historical note: the `SLEEP` / `STOP` and trace issues described here were fixed later the same day in the entry above.

### Findings
- Re-reviewed `MetalSNES/Emulator/SPC700.swift` against the local bsnes SPC700 core after the `POP A/X/Y` flag fix.
- One additional high-confidence emulation bug remains in the class: `SLEEP` (`$EF`) and `STOP` (`$FF`) currently set `sleeping/stopped`, rewind `PC` by 1, and then `step()` returns early forever while those flags are set.
- bsnes does not rewind `PC` for these opcodes. It fetches the opcode once, leaves `PC` advanced, and then idles on repeated reads of the current `PC` until the wait/stop condition is released.
- In our core, that means executing `SLEEP` or `STOP` is currently terminal unless some outside code manually clears the flags, and even if something did clear them later, execution would re-run the wait opcode instead of continuing at the following instruction.
- Separate tooling bug: the SPC trace block uses a `defer` at end-of-scope, and Swift warns that it executes immediately. That matches the earlier misleading traces where lines for `MOV A,...`, `MUL`, `INC A`, and `POP A` appeared to show stale post-instruction register values.

### Current Conclusion
- After the `POP` fix, I do not currently see another equally obvious ALU/flag mismatch in `SPC700.swift` from a bsnes cross-check.
- The next concrete code fix in this class should be `SLEEP`/`STOP` semantics. The trace logger should also be corrected so future SPC investigations are not biased by stale state dumps.

## 2026-03-10: SMW Audio Fix — SPC700 POP Flags Were Clobbering DSP Pitch Writes

### Findings
- Compared the live SMW SPC trace against the local bsnes SPC700 core and found a real CPU-core mismatch: our `POP A/X/Y` implementation was incorrectly updating `N/Z`, while bsnes and hardware leave flags unchanged.
- This mattered directly in the hot SMW/N-SPC DSP write helper at `$068F-$069D`:
  - `PUSH A`
  - mask-check in `A`
  - `POP A`
  - `BNE` to skip the write
- With our broken `POP A`, the restored non-zero pitch-low byte was setting `Z=0`, so the helper skipped the `$F2/$F3` write that should have updated DSP pitch registers. That left active voices pinned near the default pitch state and made fresh-boot music behavior look dead or badly wrong.
- After fixing `POP A/X/Y`, a clean `Release` boot of `mario.sfc` showed the expected downstream change immediately:
  - SPC port 2 echo returns song ID `$01`
  - multiple DSP voices key on with varying pitches instead of getting stuck at `$1000`
  - sample snapshots now show values like `$1C30`, `$2A48`, `$0546`, `$08DF`, `$1FB9`, `$1524`
  - `audio/stats` remains heavily non-zero during playback (`nonZero` climbing into the high hundreds of thousands on fresh boot)

### Change
- Removed the incorrect `setNZ(...)` side effect from SPC700 opcodes:
  - `POP A` (`$AE`)
  - `POP X` (`$CE`)
  - `POP Y` (`$EE`)

### Current Conclusion
- The earlier "main CPU never sends the music command" theory is no longer the active one for fresh boot. The SPC is now clearly receiving and processing the SMW music command path.
- I still cannot literally hear the app from inside the shell, but the emulator state after this fix now matches active SMW song playback far more closely than the pre-fix runs.

## 2026-03-10: SMW Audio Follow-up — Fresh Boot Still Fails, CPU-Side Lead

Historical note: later `POP A/X/Y` and APU clock-rate fixes changed this conclusion. Keep this section as an investigation snapshot, not the final root cause.

### Findings
- Revalidated on a `Release` build, not `Debug`. A clean `mario.sfc` boot still does not produce working SMW music.
- The SPC/DSP side is no longer obviously dead on fresh boot:
  - `audio/stats` shows continuous DSP sample generation with substantial non-zero output.
  - Live DSP voice dumps now show real keyed voices and occasional sustained envelopes instead of total silence.
  - The main CPU does write non-zero values to APU ports during a fresh boot (`port0` values like `$13/$14/$15/$1C`, plus other boot/upload traffic), so the situation is not simply "CPU never touches the APU".
- The deterministic `mario.state` repro remains silent:
  - `konCount=0`, `nonZero=0`, all DSP voices released.
  - The SPC sits in the `$0549/$054C` timer wait loop for long stretches (`MOV Y,$00FD` / `BEQ`), which is consistent with the restore landing in a no-music scheduler state.
- WRAM sound mirror watchpoints on `$1DF9-$1DFB` stayed quiet during the observed fresh-boot window, which suggests SMW is not reaching the usual mirror-based music queue path in the current emulation state, even though there is still some direct CPU→APU traffic.

### Changes
- Tightened SPC timer modeling toward bsnes:
  - Added TEST-register timer gating (`$F0` bits affecting timer pulses).
  - Added stage-1/stage-2 timer behavior so timer outputs are driven by falling-edge pulses rather than the previous simplified divider.
  - Timer stage clocks now continue running while the timer is disabled, matching hardware behavior more closely.
- Extended save-state support for the new SPC timer fields while keeping older v2 save states loadable.

### Current Conclusion
- The remaining SMW music failure on a fresh boot looks upstream of the audible DSP path.
- The APU is receiving some traffic, but the game is still not reaching the correct music-start state. The next pass should focus on the CPU-side sound command path / game-state progression rather than more blind DSP tweaks.

## 2026-03-10: SMW Audio Follow-up — SPC Word Arithmetic + DIV Accuracy

### Findings
- Parsed `mario.state` directly to inspect the live SPC RAM image instead of guessing from traces. The loaded SMW/N-SPC code uses `SUBW` (`$9A`), `ADDW` (`$7A`), and `DIV YA,X` (`$9E`) heavily, including right around the hot loop at `$118F-$12C7`.
- The live SPC PC observed during clean boot also landed in this area (`$1191`), so these are not theoretical compatibility holes — the currently running sound driver executes them.
- Our previous `DIV YA,X` implementation used a simplified quotient/remainder path and an ad-hoc divide-by-zero case, which does not match bsnes or hardware behavior. `ADDW`/`SUBW` were also being handled with hand-rolled flag logic instead of the SPC700's bytewise carry/borrow behavior.
- DSP-side cleanup: `KON`/`KOFF` were being accumulated with `|=` between samples instead of behaving like a last-write latch, and pitch modulation was using the pre-envelope sample instead of the post-envelope voice output.

### Changes
- Reworked `SPC700.swift` word arithmetic to follow the bsnes model:
  - `CMPW` now uses a dedicated 16-bit compare helper.
  - `ADDW`/`SUBW` now reuse the 8-bit ADC/SBC path byte-by-byte so carry, half-carry, overflow, and negative flags match the SPC700 rules more closely.
  - `DIV YA,X` now uses the bsnes overflow-path algorithm instead of the simplified quotient clamp.
- Tightened `DSP.swift` behavior:
  - `KON`/`KOFF` now record the last value written rather than OR-ing multiple writes together.
  - Pitch modulation now uses the post-envelope output sample, matching the bsnes pipeline more closely.

### Validation Note
- Runtime validation is being moved to `Release` builds for audio work. The app runs much faster there, the timing behavior is closer to what we want to observe, and the extra compile time is not material compared to the debugging time spent waiting on a slower `Debug` binary.

## 2026-03-10: Music Debugging Progress

### DSP Audio Pipeline Works
Directly programming DSP registers via the debug server's `/dsp/kon` endpoint successfully plays notes with correct pitch, envelope (ADSR), and BRR sample decoding. A test melody on voice 0 with varying pitches was clearly audible. This confirms the entire audio pipeline (BRR decode → gaussian interpolation → envelope → volume → AudioUnit output) is functional.

### Early Protocol Hypothesis (not yet confirmed)
An initial trace suggested the game sets `$1DFB = $01` (music track 1) at `$00:96C8` and the NMI handler copies it to SPC port 2 (`$2142`), while port 0 (`$2140`) remains `$00` from WRAM `$1DF9`. That made port-0 command latching look like a plausible culprit.

Key findings:
- SMW game code at `$96C0`: checks `$0109` flag, calls `$810E` (APU reset), sets `$1DFB=$01`
- NMI handler at `$818F`: copies `$1DF9→$2140`, `$1DFA→$2141`, `$1DFC→$2143`
- `$1DF9` is never set to a non-zero value during music init
- N-SPC polls ports at `$05AC: MOV A, !$00F4+X` and `$12FC: MOV A, !$00F4`
- The `$810E` reset routine calls `$80F7` (SPC handshake), so handshake/counter state is still a protocol area worth checking

Later DSP logs showed a port-2 music write followed by `KON` activity and non-zero samples, so this note should be treated as an investigation branch, not a confirmed root cause.

### Crash Fix
Removed `cpuRef` (strong reference to CPU) from `APU.write()` — it caused a Swift exclusivity violation (`swift_beginAccess` trap) because `cpu.regs` was being mutated by `cpu_step()` while the APU port write handler tried to read `cpu.regs.PBR`/`.PC` in the same call chain.

## 2026-03-10: SMW Audio Follow-up — TSET1 Note Corrected, DSP KON Delay Added

### Findings
- Re-checked SPC700 `TSET1/TCLR1` semantics against the SPC700 programming manual. The current implementation using `A - mem` for N/Z is correct; the earlier DEVLOG note claiming `A & mem` was wrong.
- Existing `/tmp/dsp_diag.log` output showed SMW already sending a music command on port 2 (`$2142 -> $01`) and the DSP producing non-zero samples with `FLG=$20`. That means the current failure mode is no longer "SPC boot/upload never happened".
- The largest remaining DSP accuracy gap in the current code was immediate key-on. bsnes holds voices in a 5-sample KON startup delay with the envelope at zero before normal pitch/envelope processing begins.

### Change
- Added a per-voice `konDelay` field in `DSP.swift`.
- `KON` now schedules a 5-sample startup delay instead of decoding/attacking immediately.
- During the delay, `ENVX`/`OUTX` stay at zero and normal pitch/envelope advancement is skipped.
- Clearing `ENDX` on KON was moved to the key-on path to better match hardware behavior.

## 2026-03-09: SPC700 Bug Fixes + Debug Server

### SPC700 Bugs Found (via research agent comparing against hardware docs)

1. **Direct Page 16-bit wrapping**: `readDP16($FF)` read $00FF and $0100 instead of wrapping to $0000. Broke N-SPC 16-bit track pointers used by MOVW/ADDW/SUBW. Same bug in `addrIndirectX`/`addrIndirectY`.

2. **TSET1/TCLR1 note (later corrected)**: This investigation initially suspected the flags should use AND (`a & v`), but a later re-check against the SPC700 programming manual showed the current `A - mem` behavior is correct.

3. **ADDW/SUBW half-carry**: H flag was computed on bit 12 boundary instead of high byte with carry/borrow from low byte.

### Debug Server
Added HTTP debug server (`DebugServer.swift`) on port 8765 for real-time SPC/DSP inspection via `curl`. See `AUDIO_DEBUG.md` for endpoints and usage. Historical note: this originally required a manual `startDebugServer()` call; the current UI auto-starts it when emulation begins.

## 2026-03-09: Performance Optimization — 16 FPS → 408 FPS

### Problem
Emulator was running at 16.4 FPS (0.3x realtime) during initial benchmarking. Turned out this was a Debug build. Release mode was 199 FPS (3.3x), but still room to improve.

### Profiling
Added CPU/PPU/SPC timing splits to benchmark. Results showed CPU+SPC = 97% of time, PPU only 3%. The bottleneck was the C→Swift callback path for every memory access.

### Optimizations Applied
1. **CPU.swift**: `weak var bus` → `unowned let bus` (eliminated ARC retain/release per step); cached `ctx` pointer (was recreating `Unmanaged.passUnretained` every step); `@inline(__always)` on `step()`
2. **Bus.swift**: `@inline(__always)` on all read/write/routing functions
3. **Cartridge.swift**: `Data` → `[UInt8]` for romData; bitmask addressing (`& romMask`) instead of modulo; `@inline(__always)` on read/address functions
4. **SPC700.swift**: Fast-path RAM reads (skip I/O switch for addresses outside $F0-$FF and $FFC0-$FFFF); `@inline(__always)` on `read`/`fetchByte`
5. **EmulatorCore.swift**: Batched SPC execution per-scanline (was interleaved per CPU step with floating-point debt tracking); skip H/V IRQ position checks when IRQ disabled

### Results
- Debug: 16.4 FPS → Release baseline: 199 FPS → Optimized: **408 FPS (6.8x realtime)**
- CPU 96%, PPU 1%, SPC 3% — further gains require moving memory map to C

## 2026-03-08: Zelda Boot Priority — Steps 1-6 Implementation

### Changes Made

**cpu_dispatch.c:**
- Added XBA opcode ($EB) — Exchange B and A (swap high/low bytes of 16-bit accumulator). Sets N/Z based on new low byte.
- Added printf logging to `op_unimpl` — now prints opcode and PC when an unimplemented opcode is hit, making it easy to identify missing opcodes during Zelda boot.
- Added `#include <stdio.h>` for printf.

**PPU.swift — BG scroll fix:**
- Fixed BG scroll write-twice register formula. Was `(scrollLatch & 0xF8) << 8` which masked out bits 0-2 of the latch, zeroing scroll bits 8-10. Changed to `scrollLatch << 8` so the full 10-bit scroll value is constructed correctly.

**PPU.swift — 16x16 tile support:**
- `renderBG4bpp` now handles 16x16 tiles (BGMODE character size bits). For 16x16 tiles, tilemap coordinates use 16-pixel steps and sub-tile offsets select the correct 8x8 sub-tile within the 16x16 block.
- Fixed tilemap screen size calculation in both `renderBG4bpp` and `renderBG2bpp` to correctly use SC register bits 0-1 for the screen layout (32x32, 64x32, 32x64, 64x64).

**APU.swift — SPC700 transfer protocol:**
- Enhanced APU stub beyond basic $AA/$BB handshake. Now handles the full SPC700 boot ROM transfer protocol:
  - Phase 1: Wait for $CC acknowledgment
  - Phase 2: Transfer mode — echoes counter values on port 0, accepts data on port 1
  - Phase 3: Running mode — echoes all ports
- This should prevent Zelda from hanging during APU program upload.

**EmulatorView.swift — Keyboard input:**
- Created `KeyCaptureMTKView` subclass of MTKView that overrides `keyDown`/`keyUp` and forwards to `Joypad`.
- `performKeyEquivalent` returns true for mapped keys to prevent system beep.
- `updateNSView` ensures the view stays first responder and updates the joypad reference when the emulator core loads.

**EmulatorCore.swift / CPU.swift:**
- Trace enabled for first 500 instructions (was 100/1000 mismatch).

### Build Status
- C code compiles with `cc -c -Wall` (only unused parameter warnings from macros)
- All Swift files pass `swiftc -typecheck`
- Needs `sudo xcode-select --switch /Applications/Xcode.app` + `sudo xcodebuild -license accept` for full xcodebuild

### Next Steps
- Run Zelda and check trace output for any `UNIMPL opcode` messages
- Verify DMA uploads tile data to VRAM correctly (watch for writes to $2118/$2119)
- Check if APU transfer protocol is sufficient or if game hangs
- Test keyboard input on title screen

## 2026-03-09: PPU Diagnostic Tests + Chr Base Investigation

### PPU Diagnostic Framework
- Created `PPUDiagnostic.swift` with 4 progressive unit tests that bypass the CPU:
  - Test 1: Backdrop color (CGRAM[0] → screen)
  - Test 2: 2bpp tile rendering (Mode 0, BG1)
  - Test 3: 4bpp tile rendering (Mode 1, BG1)
  - Test 4: VRAM address variation (different tilemap/chr bases)
- Added `readPixel(x:y:)` helper to PPU for framebuffer readback
- Added `PPUDiagnostic.dumpState()` for runtime VRAM/CGRAM/register dumps
- Added `checkRuntimeFramebuffer()` for color distribution analysis
- Added "Run PPU Test" toolbar button in ContentView

### Bug Fix: `runOneFrame()` didn't execute CPU
- `EmulatorCore.runScanline()` checks `while running`, but `running` was only set by `run()`.
- Standalone `runOneFrame()` calls (used by diagnostic) had `running=false`, executing 0 CPU cycles.
- Fixed by saving/restoring `running` flag in `runOneFrame()`.

### Historical note: chr base investigation was a false lead
- This conclusion did not hold up. Later rechecks and the current renderer keep BG chr bases at `nibble << 13` (8KB steps), while sprite name bases remain `<< 14`.
- The Zelda rendering symptoms observed here were real, but this was not the final explanation for them.

### Findings from Runtime Dump
- Zelda title screen: `tm=0x10` (sprites only) — all visible content rendered as sprites
- CGRAM: only 14/256 colors loaded (palette 13 = sprite palette), BG palettes empty
- WRAM CGRAM source ($7E:C500): 27/512 non-zero bytes — palette buffer not fully initialized
- This suggests CPU instruction bugs preventing full palette initialization
- Infinite recursion bug in log function (print→log→log→...) caused silent crash — fixed

### Current State
- All 4 PPU unit tests PASS
- Zelda title screen renders with correct colors for sprites (gold triforce, white text)
- The BG chr-base theory above was not the final fix; keep the current `<< 13` BG addressing unless later evidence says otherwise.
- Need to investigate: why does Zelda only enable sprites (`tm=0x10`) and not BGs?

## 2026-03-09: Sprite Chr Base Address Fix (OBSEL $2101)

### Bug Fix: Sprite name base and gap addressing
- **Root cause**: Sprite chr base used `<< 13` for both nameBase and nameGap. Should be `<< 14` and `<< 13` respectively.
- **Confirmed via bsnes source** (`bsnes/sfc/ppu/io.cpp` and `bsnes/sfc/ppu/object.cpp`):
  - `tiledataAddress = (data & 7) << 13` (word addr) → `<< 14` bytes
  - `nameGap = (1 + nameselect) << 12` (word addr) → `<< 13` bytes
- Changed `PPU.swift` lines 589-590:
  - `nameBase`: `<< 13` → `<< 14` (8K-word = 16KB steps, byte addressed)
  - `nameGap`: `<< 13` stays `<< 13` (4K-word = 8KB steps, byte addressed)
- **Result**: Sword and NINTENDO text now render correctly on title screen (name table 0 sprites)

### Investigation: ZELDA text still missing
- ZELDA/triforce sprites use name table 1 (OAM attr bit 0 = 1), tiles 0x80-0xAE
- With objsel=0x02: table0=0x8000 (byte), table1=0xA000 (byte) — matches bsnes formula
- **Debug findings**: VRAM at table 1 tile 0x80 offset (0xB000) is all zeros
  - Data exists at 0xA000-0xBD3A but only for tiles 0x00-0x69
  - Game hasn't DMA'd the ZELDA tile data (tiles 0x80+) into VRAM
- **Root cause**: CPU emulation bugs preventing full title screen initialization
  - Only 14/256 CGRAM colors loaded
  - Only `tm=0x10` (sprites only, no BGs)
  - Game code that loads later animation tiles (ZELDA letters) not executing correctly
- **Next step**: Fix CPU bugs to allow full game initialization

## 2026-03-09: Three Bug Fixes for Title Screen Rendering

### Bug Fix 1 (Critical): HVBJOY auto-joypad timing
- **Root cause**: `enterVBlank()` sets `hvbjoy |= 0x01` (auto-read in progress), but it was only cleared in `exitVBlank()` at scanline 0 — holding the flag for the ENTIRE VBlank (37 scanlines).
- On real SNES, auto-joypad read completes ~3 scanlines after VBlank starts.
- Zelda's NMI handler polls HVBJOY bit 0 waiting for auto-read completion before doing DMA transfers. With the flag stuck at 1, the NMI handler spun in a polling loop, never reaching the DMA code.
- **Fix**: Clear `hvbjoy &= ~0x01` at scanline `vBlankStart + 3` in `EmulatorCore.runScanline()`.
- **Impact**: This was likely the root cause of incomplete VRAM/CGRAM initialization (only 14 colors, missing sprite tile data for ZELDA text/triforce).

### Bug Fix 2: PPU sprite hFlip double-flip
- **Root cause**: Both `drawX` and `tileNumOffset` were flipped when hFlip was set, cancelling out the tile reordering. Result: pixel bits were reversed within each 8x8 tile, but tile arrangement stayed in normal order.
- bsnes keeps draw position linear (`x + tileX * 8`) and only flips the data source (`mirrorX = hflip ? width-1-tileX : tileX`).
- **Fix**: Changed drawX to always be `spriteX + tileCol * 8` (linear), kept flip only in tile data fetch (`mirrorCol`).
- **Impact**: Multi-tile hFlipped sprites now correctly mirror at both tile and pixel levels.

### Bug Fix 3: BG scroll register byte order
- **Root cause**: Formula was `value | (scrollLatch << 8)` — new byte in low position, old latch in high. Should be `(value << 8) | scrollLatch` per bsnes.
- The SNES scroll write-twice registers work: each write computes `(new_byte << 8) | previous_latch`. After two writes, result = `(second_write << 8) | first_write`.
- **Fix**: Reversed byte positions in all 8 scroll register handlers ($210D-$2114).
- **Impact**: BG scroll values will be correct once BGs are enabled (currently tm=0x10, sprites only).

## 2026-03-09: ZELDA Title Text Fix — BG Chr Base Shift Bug (HOURS of debugging)

### The Problem
The "ZELDA" logo text on the title screen was garbled/missing. This took **hours** of investigation across multiple sessions involving building real-time debug tooling, DMA logging, VRAM hex dumps, and WRAM comparisons.

### The Investigation (what made this so hard)
1. Initially assumed ZELDA text was sprites — it's actually **BG1 tiles** (TM=$15 = BG1+BG3+OBJ)
2. Built sprite tileset override controls, VRAM tile viewer, PPU register readout, active sprite list, and DMA byte-address logging — all to narrow down the source
3. Found perfect ZELDA tile data at VRAM byte address **0x6000** using the VRAM tile viewer (4bpp, palette 3)
4. Sprites at $B000 were red herrings — those were utility/twinkle animation sprites, not the ZELDA text
5. With bg12nba register value and `<< 14` shift, BG1 chr base pointed to **0x8000** — wrong location
6. Ran VRAM/WRAM comparison diagnostics at frame 1500 (~25 seconds in) to compare DMA source vs destination

### Root Cause
**BG chr base calculation used `nibble << 14` but should be `nibble << 13`.**

- SNES BG character base (BG12NBA $210B / BG34NBA $210C): each nibble = **4K words = 8KB bytes** → `nibble << 13`
- SNES sprite name base (OBJSEL $2101): each value = **8K words = 16KB bytes** → `value << 14`
- These are **different granularities** — BGs and sprites don't use the same shift!

The earlier "fix" from `<< 13` to `<< 14` (logged in a previous DEVLOG entry) was **wrong** — it happened to fix a PPU diagnostic test but broke actual game rendering. The diagnostic test coincidentally worked because it placed tiles at addresses that hit correctly under either shift.

### The Fix
Changed `<< 14` → `<< 13` in three places:
- `PPU.swift` `renderBG4bpp()` — BG chr base calculation
- `PPU.swift` `renderBG2bpp()` — BG chr base calculation
- `EmulatorCore.swift` `updateDebugState()` — debug display chr base

### Lesson Learned
- BGs use 4K-word (8KB) granularity for chr base; sprites use 8K-word (16KB). Don't assume they're the same.
- Unit tests that pass don't mean the value is correct — the test tile placement may accidentally align under multiple interpretations.
- When tile data exists in VRAM but renders wrong, check the **base address calculation** before assuming missing data.

## 2026-03-09: Research — Super Mario World N-SPC Audio Communication Protocol

### SMW Uses the "Koji Kondo Prototype" N-SPC Variant

SMW's SPC700 sound engine is the **prototype version** of the Koji Kondo N-SPC variant. The four APU ports ($2140-$2143, mapped to SPC F4-F7) each serve a distinct purpose:

### Port Assignments (SNES → SPC)

| SNES Port | SPC Port | Purpose | Command Format |
|-----------|----------|---------|----------------|
| $2140 | $F4 | SFX Channel 5 (Sequence Set 1) | $01-$7F = play SFX ID; $80-$FF = "Hurry Up!" |
| $2141 | $F5 | Hard-coded SFX (Ch8) + Yoshi Drums (Ch6) | $01=jump, $02=yoshi drums on, $03=off, $04=two-note SFX, $FF=load data |
| **$2142** | **$F6** | **Music Control** | **$01-$7F = play music by ID; $80-$FF = fade out; $F0 = stop** |
| $2143 | $F7 | SFX Channel 7 (Sequence Set 2) | $01-$FF = play SFX ID |

### Key Finding: Music Playback via $2142

To trigger music, the game writes a **non-zero value ($01-$7F)** to **port $2142**. The value IS the music/song ID. For example, writing $06 to $2142 plays song #6.

The SPC echoes the currently playing music ID back to $2142 on the SNES side. The game's NMI handler checks this echo before sending a new command.

### SMW NMI Audio Dispatch Routine (at $00:8174)

The game does NOT write directly to $2140-$2143 from gameplay code. Instead:
1. Gameplay code writes the desired command to **RAM variables**: $1DFB (music), $1DF9 (SFX port0), $1DFA (SFX port1), $1DFC (SFX port3)
2. The **NMI handler** at $00:8174 reads these RAM variables and dispatches them to the actual APU ports each VBlank

Disassembly of the dispatch:
```
$00:8174  SEP #$30           ; 8-bit mode
$00:8176  LDA $4210          ; Ack NMI
$00:8179  LDA $1DFB          ; Music command
$00:817C  BNE $8186          ; If non-zero, send it
$00:817E  LDY $2142          ; Read SPC echo (port 2)
$00:8181  CPY $1DFF          ; Compare with last sent ID
$00:8184  BNE $818F          ; Skip if echo doesn't match yet
$00:8186  STA $2142          ; Write music cmd to port 2
$00:8189  STA $1DFF          ; Remember last sent ID
$00:818C  STZ $1DFB          ; Clear music trigger variable
$00:818F  LDA $1DF9          ; SFX port 0
$00:8192  STA $2140          ; Write to port 0
$00:8195  LDA $1DFA          ; SFX port 1
$00:8198  STA $2141          ; Write to port 1
$00:819B  LDA $1DFC          ; SFX port 3
$00:819E  STA $2143          ; Write to port 3
$00:81A1  STZ $1DF9          ; Clear all SFX triggers
$00:81A4  STZ $1DFA
$00:81A7  STZ $1DFC
```

### Why We Only See $00 Writes

The NMI handler **always** writes all four ports every frame, even when commands are $00 (NOP). After gameplay code sets $1DFB to a music ID, the NMI sends it once, then $1DFB is cleared to $00 — subsequent frames send $00 (NOP) to all ports.

The echo-check protocol at $00:817E-8184 is critical: the game reads $2142 back from the SPC to confirm the last command was acknowledged before sending a new one. If our SPC700 doesn't echo the music ID back on port 2 ($F6), the game will keep re-sending the command or get stuck.

### Why No Music Command is Sent

If $1DFB is never set to a non-zero value, no music command reaches $2142. Possible causes:
1. Game code that sets $1DFB hasn't executed (CPU emulation bug in game init)
2. Game init is blocked before reaching the music setup routine
3. The SPC echo protocol is broken (game reads $2142 back but our SPC doesn't echo correctly)

There are **33 locations** in the ROM that write to $1DFB (music trigger). The earliest ones are at $00:94B4, $00:96C8, $00:9738 — these are in the game's initialization/level-load code.

### SMW Music IDs (partial, from N-SPC documentation)
- $01-$7F: Music tracks (overworld, underground, castle, etc.)
- IDs $09-$0C, $0F, $10, $16: Reset tempo speedup from "Hurry Up!"
- $80-$FF on port $2142: Fade out (240 tempo ticks)
- $F0 on port $2142: Stop music

## 2026-03-10: Input System Rework Plan

### Goal
- Replace the fixed keyboard-only input path with a persisted binding system that supports both keyboard and GameController devices.
- Fix stuck-button behavior caused by relying on raw `keyDown`/`keyUp` events without reconciling held state when focus changes.

### Implementation Notes
- Add an `InputManager` in the app layer that owns:
  - persisted keyboard and gamepad bindings
  - current pressed keyboard keys
  - current active gamepad controls across connected controllers
  - rebinding capture state for the UI
- Refactor `Joypad` so keyboard and gamepad state are tracked separately and merged when the CPU latches or auto-reads controller state.
- Route `MTKView` keyboard handling through the input manager instead of a hard-coded map in `Joypad`.
- Clear transient keyboard state when the view resigns first responder or the app deactivates, then resync controller state when the app becomes active again.

### UI Plan
- Add an input settings sheet to the toolbar.
- Show connected controllers and profile support.
- Allow rebinding one keyboard key and one gamepad control per SNES button, with defaults and clear/reset actions.

## 2026-03-10: Latency Reduction Pass

### Problem
- Input still felt delayed because the emulator only uploaded the framebuffer after the entire frame, including VBlank, finished.
- The `MTKView` was rendering on its own cadence instead of right after a new emulator frame became available.
- Frame pacing used `usleep`, which can oversleep and miss the next display refresh.

### Changes
- Upload the completed framebuffer immediately after the last visible scanline instead of waiting through the rest of VBlank.
- Switch the Metal view to on-demand draws and request a draw as soon as the emulator uploads a new frame.
- Configure the underlying `CAMetalLayer` for lower queue depth and non-transaction presentation.
- Replace `usleep` pacing with `mach_wait_until` plus a short final spin for tighter frame delivery.

## 2026-03-10: Configurable 1-Frame Run-Ahead

### Goal
- Reduce end-to-end input latency further without changing normal frame pacing.
- Keep the feature optional because it trades CPU time for lower latency and does not make animation smoother by itself.

### Changes
- Extended save-state coverage for per-frame speculative execution:
  - PPU latch/fixed-color state
  - APU DSP timing accumulators
  - DSP envelope/echo/latch internals
  - joypad auto-read and manual shift state
- Reused that save-state path inside the core emulation loop for a configurable 0/1-frame run-ahead mode:
  - run one real frame with audio
  - snapshot post-frame machine state
  - run one speculative frame with audio output suppressed
  - present the speculative frame and restore to the post-real-frame state
- Added a persisted toolbar latency menu with `Off` and `1 Frame` options.
- Added a `--run-ahead 1` CLI override for app launches so the path can be smoke-tested directly.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build`
- GUI smoke: `/tmp/MetalSNESDerived/Build/Products/Debug/MetalSNES.app/Contents/MacOS/MetalSNES --run-ahead 1 --rom mario.sfc`
- Baseline benchmark with run-ahead off remained stable at `120 frames in 9.733 sec = 12.3 FPS`

## 2026-03-10: Display-Linked Pacing + Audio Drift Control

### Problem
- Throughput benchmarks were not matching subjective smoothness.
- The emulator was still pacing itself from a software timer and manually posting `draw()` requests to the main queue, which can introduce jitter even when average emulation throughput is high.
- Audio output was buffered independently, with no feedback loop to keep long-term emulation timing aligned to the real audio device clock.

### Changes
- Switched the live Metal view to display-linked presentation instead of manual per-frame `draw()` requests:
  - `MTKView` now runs while emulation is active and targets the screen refresh rate.
  - the renderer presents the latest completed frame on each display refresh
  - repeated refreshes no longer recompute the GPU PPU output unless a new emulated frame arrived
- Added a small audio-buffer-based drift correction in the emulation pacing loop so frame timing is nudged by real audio queue occupancy instead of only a fixed 60.0988 Hz software target.
- Added pacing instrumentation to the debug sidebar:
  - average/worst display interval
  - average/worst frame age at presentation
  - produced vs presented frame counts
  - repeated and dropped presents
  - audio buffer depth, underruns/overruns, and current timing correction
- Changed persisted run-ahead default to `1 Frame` when the setting has never been stored before, without overriding explicit user choices.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build`
- 5-second GUI smoke run of `mario.sfc` completed with no captured runtime output

## 2026-03-10: Display Configuration + UI Cleanup

### Goal
- Make the presentation path configurable for actual play instead of only exposing low-level debug controls.
- Improve fullscreen/pixel presentation quality with integer scaling and a configurable post-process pass.
- Clean up the main window so the emulator surface is the focus instead of a row of utility buttons.

### Changes
- Added persisted display configuration:
  - integer scaling toggle
  - display filter modes: `Clean`, `Scanlines`, `CRT Glass`
- Moved integer scaling to the final Metal display pass instead of relying on SwiftUI view sizing.
  - the renderer now computes a centered content rect in drawable pixels
  - fullscreen and arbitrary window sizes now letterbox correctly while preserving aspect
  - integer scaling falls back to fitted scaling below 1x instead of clipping
- Added a CRT-style post-process shader with:
  - scanline contrast
  - triad mask
  - light bloom
  - curvature
  - vignette
- Refreshed the main window UI:
  - dedicated header card with ROM/status summary
  - focused display stage with overlay status chips
  - bottom control deck for run/pause/step/fullscreen/state actions
  - reduced toolbar clutter by moving utility actions into a tools menu
  - new display settings sheet for screen + latency options
- Increased the default window size so the display-first layout has room by default.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build`
- 5-second GUI smoke run of `mario.sfc` completed with no captured runtime output

## 2026-03-10: Aperture-Grille Phosphor Filter

### Goal
- Try a CRT-inspired presentation mode that prioritizes phosphor glow and RGB bleed over the more obvious scanline/curvature tricks.
- Keep it visually distinct from the existing `CRT Glass` mode so it is useful as an alternative rather than a minor tweak.

### Changes
- Added a new persisted display preset: `Aperture Bloom`.
- Implemented a dedicated fragment path for the preset in the final Metal pass:
  - anisotropic source-texel blending over a `5x3` neighborhood to create localized phosphor spread
  - brighter horizontal halo contribution so hot pixels bleed into nearby phosphors instead of staying perfectly boxed
  - a softer aperture-grille RGB mask applied in display space, without scanlines, curvature, or vignette
- Kept the existing `CRT Glass` path intact for users who want the stronger retro stylization.

### Notes
- This is the closest match to the "beautiful CRT glow" described for Trinitron-style displays:
  - aperture-grille RGB structure
  - localized color bleed from bright texels
  - no forced barrel distortion
- It is intentionally a little heavier than the other display presets because the phosphor bloom comes from neighborhood sampling, not just a cheap overlay.

## 2026-03-10: Alternate Phosphor Variant

### Goal
- Keep the first phosphor preset intact and add a second option for users who prefer a hotter, more bleeding look.

### Changes
- Added a second selectable phosphor-style preset and refined it into a distinct `Trinitron` look.
- Tuned the alternate preset away from the first phosphor pass instead of just making it hotter:
  - explicit RGB cell structure within each emulated pixel footprint
  - darker scanline gaps between source rows
  - more restrained highlight bloom so the cell/slot-mask structure stays visible
- Left `Aperture Bloom` unchanged so users can choose between the softer bloom look and the more structured Trinitron-style presentation.
- Follow-up tuning pushed the `Trinitron` preset further toward the target look:
  - taller rounded-rectangle phosphor bars
  - more glow around each RGB cell
  - slightly softer slot-mask gap so the cells feel emissive instead of cut out
- Additional tuning increased the overall emissive feel:
  - brighter cluster bleed from hot/white texels into nearby phosphor cells
  - a low gray pedestal so darker texels still carry a subtle non-black glow

## 2026-03-10: Top-Edge Sprite Leak + Fullscreen Controls

### Problem
- The top of the frame could show a few junk sprite fragments on scanline `0`.
- The artifact appeared to track gameplay state, which pointed away from the display filter and toward OBJ rendering.
- Toggling fullscreen only fullscreened the macOS window reliably; the emulator stage itself was not stretching to fill the available space.

### Changes
- Adjusted the OBJ top-edge handling in `PPU.swift`:
  - preserved the existing `y + 1` seam math for sprite row selection
  - clipped the common hidden-sprite wrap case instead of letting parked sprites leak onto scanline `0`
- This stops the stray top-edge fragments without introducing seams inside larger sprites.
- Made the main emulator column and display stage expand to fill the fullscreen window instead of holding near their windowed size.
- Added direct fullscreen hotkeys from the Metal view:
  - `F`
  - `Command-Return`

### Follow-up
- Restored the original `y + 1` sprite row seam handling after it introduced missing horizontal seams inside larger sprites.
- Kept the top-edge fix by clipping the common hidden-sprite wrap case (`Y >= 0xF0`) instead of shifting all sprite row math.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build`
- 5-second GUI smoke run of `mario.sfc` completed with no captured runtime output

## 2026-03-10: Single-Header Shell + Clean ROM Replacement

### Problem
- The app had two competing header/tool areas: the custom stylized header plus the native macOS toolbar.
- Opening a new ROM did not suspend the current emulation session first, which could leave the old core feeding the renderer while the new core booted.
- Fullscreening the window still left the emulator stage visually boxed in by extra chrome.
- The user wanted the primary controls consolidated into the stylized header, with secondary tools behind a hamburger menu, and the header to auto-hide while the game is active.

### Changes
- Removed the native toolbar and bottom control deck, and consolidated the primary actions into a single in-stage header overlay:
  - visible actions for run/pause, open ROM, save state, load state, and fullscreen
  - inline `Filter`, `Scale`, and `Latency` controls as pill menus
  - a hamburger menu for input settings, display settings, debug panel toggle, stepping, tests, benchmark, and diagnostics
- Reworked the layout so the emulator stage is the main surface and the header sits on top of it instead of consuming separate vertical space.
- Added header auto-hide behavior driven by pointer movement while emulation is active:
  - movement or clicks reveal the header
  - the header hides again after a short timeout when the game is running
- Switched the window to a hidden-titlebar/full-size-content presentation and tracked fullscreen state from the window so the stage can actually use the available space.
- Fixed ROM replacement flow:
  - pause/stop and join the old emulation thread before loading a new cart
  - save SRAM before tearing the old session down
  - clear the renderer before the new ROM presents
  - if the ROM picker is canceled, resume the previous session when it had been running

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build`
- 5-second GUI smoke run of `mario.sfc` completed with no captured runtime output

## 2026-03-10: Heavier Trinitron Neighbor Bleed

### Goal
- Push the `Trinitron` preset much further toward an emissive Sony-style look where bright RGB cell clusters visibly influence neighboring pixels instead of staying mostly confined to their own texel footprint.

### Changes
- Retuned the `Trinitron` preset in `MetalRenderer.swift` to run hotter and softer:
  - higher bloom strength
  - slightly lower mask strength
  - slightly softer focus
- Expanded the hot-phosphor shader path in `Shaders.metal`:
  - wider bloom sigma in both X and Y
  - broader sampling support for the `Trinitron` branch than the standard phosphor branch
  - additional far-lateral and vertical spill so hot cells push light into nearby cells more aggressively
  - larger rounded-cell glow lobes in the mask itself
  - stronger post-mask highlight lift and brighter low-level pedestal

### Expected Result
- White and near-white clusters should now bleed farther into adjacent phosphor bars.
- Darker content should still keep a soft gray emissive floor instead of dropping to hard black between cells.
- The grille structure should remain visible, but the overall look should be noticeably more luminous than the prior `Trinitron` pass.

## 2026-03-10: Persisted Image Controls for Display Filters

### Goal
- Add a proper image-control section with CRT-style tuning knobs instead of hardcoded presets only.
- Make the controls persistent and apply them to every display mode.
- Let phosphor-heavy presets react more aggressively to brightness so cranking it up feels like a true emissive bloom control, not just a flat gain stage.

### Changes
- Expanded `DisplayConfiguration` to persist:
  - brightness
  - contrast
  - sharpness
  - saturation
- Added backward-compatible decoding so older saved display settings still load and default the new fields cleanly.
- Threaded the new values through the final-pass display uniforms and shader path for all filters.
- Added an `Image` section to the display sheet with sliders for all four controls.
- Updated shader grading behavior:
  - all filters now get post-process brightness, contrast, and saturation grading
  - sharpness now acts as a user multiplier on the filter’s base beam/focus sharpness
  - `Aperture Bloom` and `Trinitron` use brightness as both output gain and extra glow/bloom drive

### Expected Result
- `Brightness` now lifts or darkens the whole image, but on the phosphor presets it also makes the glow hotter and spreads it farther.
- `Contrast` changes the light-dark separation after filtering.
- `Sharpness` changes beam focus and perceived edge crispness without needing a new preset.
- `Saturation` ranges from washed-out to heavily boosted phosphor color.

### Follow-up
- The initial image controls lived in a modal display sheet, which dimmed the emulator and could feel oversized.
- Moved display controls into a compact in-stage HUD panel instead:
  - no modal dimming
  - anchored inside the emulator stage
  - scrollable, narrower layout
  - explicit close button
