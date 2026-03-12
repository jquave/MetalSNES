# MetalSNES Development Log

## 2026-03-12: Star Fox Live Performance Regression Check

### Findings
- The new slowdown report does not line up with an always-on console logging bug.
- `EmulatorCore.debugLogging` is still off by default, and the real Star Fox save state remains fast in headless Release benchmarking:
  - `--benchmark-state-gpu "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" "/Users/macos/src/MetalSNES/Star Fox (USA).state" 120`
    -> `161.5 FPS`
- I added a reusable live-audio benchmark path to measure the app execution profile more honestly:
  - `--benchmark-state-live-gpu "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" "/Users/macos/src/MetalSNES/Star Fox (USA).state" 120`
    -> `162.4 FPS`
  - so the post-DMA-timing regression is not coming from “SPC/audio now runs during DMA stalls” in the core itself.
- A real sampled GUI run using:
  - `MetalSNES --rom "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" --state "/Users/macos/src/MetalSNES/Star Fox (USA).state"`
  showed:
  - the main thread spending most of its sampled time blocked in `MTKView.currentDrawable` / `CAMetalLayer.nextDrawable`,
  - the emulation thread still spending its real work in CPU PPU mode-2 rendering (`PPU.renderBGMode2(...)`, `PPU.writePixel(...)`),
  - no meaningful sample concentration in debug-server code, CPU-write logging, or `print`.
- There was still one real app-only debug cost left on by default:
  - normal GUI sessions always started the HTTP debug server,
  - which also turned on `Bus.captureCPUWriteLog`.
  - That was unnecessary for normal play even if it was not the dominant sampled hotspot on this machine.

### Changes
- Normal GUI emulation no longer auto-starts the debug server.
- The debug server now starts only when the debug UI is enabled, or when explicit headless `--serve-rom` / `--serve-state` modes are used.
- Stopping the debug server now also disables CPU write capture and clears the retained write-log buffer.
- Added reusable live-audio state benchmarking:
  - `--benchmark-state-live <rom> <state> [frames]`
  - `--benchmark-state-live-gpu <rom> <state> [frames]`
- Batched APU sample delivery into the audio ring buffer so normal audio output does one lock/unlock per sample batch instead of per generated sample.

### Validation
- Release build succeeded.
- Headless Release benchmark on the exact user Star Fox state:
  - `--benchmark-state-gpu ... 120` -> `161.5 FPS`
- Live-audio Release benchmark on the same state:
  - `--benchmark-state-live-gpu ... 120` -> `162.4 FPS`
  - audio stats after the run: buffer filled as expected while benchmarking faster than realtime (`buffered=16383`, large overrun count, zero underruns).
- Real GUI sampling from the same ROM/state showed the window thread pacing on drawable acquisition, not spinning in logging or debug-server code.

### Remaining
- I still have not reproduced the user-observed “about 1 FPS” window behavior on this machine after removing the auto debug server path.
- If that persists for the user after this build, the next investigation target is display-path specific:
  - current display filter/profile,
  - drawable pacing / frame presentation,
  - or scene-specific CPU PPU cost in mode 2.

## 2026-03-12: Audio Popping Follow-up

### Findings
- After the performance fix, the remaining user complaint was intermittent audio popping while framerate stayed solid.
- The first low-risk place to tighten was buffer behavior, not emulation timing:
  - the audio ring buffer was relatively small for a desktop app (`16384` samples/channel),
  - and on overrun it discarded the oldest queued samples, which can create an audible discontinuity because playback effectively jumps forward.

### Changes
- Increased audio ring-buffer headroom:
  - `bufferSize`: `16384 -> 32768`
  - `prebufferSamples`: `1024 -> 1536`
- Changed overrun handling so the audio queue now preserves already-buffered continuity and drops incoming samples when full instead of discarding the oldest queued audio.

### Validation
- Release build succeeded after the audio-buffer change.
- Live-audio Release benchmark on the exact Star Fox state remained healthy:
  - `--benchmark-state-live-gpu "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" "/Users/macos/src/MetalSNES/Star Fox (USA).state" 120`
    -> `160.8 FPS`
  - audio stats in that faster-than-realtime benchmark:
    - `buffered=32767`
    - `underruns=0`
    - `overruns=16882`
- The overrun count there is expected because the benchmark intentionally runs far faster than realtime; the point of the change is preserving continuity in the live paced app when the producer briefly gets ahead.

## 2026-03-12: Star Fox Super FX DMA Timing Fix

### Findings
- The remaining Star Fox city/frame corruption was no longer pointing at final PPU composition.
- The reusable layer dumps showed the bad art was already inside `BG1`, and the CPU write log on the same scripted state transition showed why:
  - the game was DMA-copying large chunks from Super FX RAM in bank `$70` into VRAM (`$2118/$2119`),
  - so the visible garbage had to be wrong before the PPU ever sampled the tiles.
- On the exact `state -> run 1 frame -> Start -> run 30 frames` canary, the CPU write log included two large VRAM blits:
  - `70:2C00 -> VRAM $0000`, size `$2A00`
  - `70:5600 -> VRAM $1500`, size `$2A00`
- Our timing model was still giving those DMA transfers zero duration:
  - `$420B` executed the copy immediately inside `Bus.writeSystemBank(...)`,
  - but the main loop only advanced Super FX and SPC time when the CPU executed instructions.
- For Star Fox, that means the GSU was being starved exactly while the CPU was blitting its framebuffer into VRAM, which is a credible cause of partially rendered or stale bitmap scenes.

### Changes
- `DMA.executeGeneralDMA(...)` now returns a coarse master-cycle charge based on active channels plus bytes transferred.
- `Bus` now accumulates that DMA penalty when `$420B` starts a transfer.
- `EmulatorCore` now consumes that pending master-cycle penalty after each CPU step and advances:
  - Super FX time,
  - SPC time,
  - and scanline/master-cycle position
  through the same stall window instead of pretending DMA was free.
- The headless benchmark loop now uses the same coprocessor-advance path, so benchmark timing matches the normal run loop more closely.

### Validation
- Release and Debug builds both succeeded after the timing change.
- Re-ran the exact user canary on the Release build:
  - load `/Users/macos/src/MetalSNES/Star Fox (USA).state`
  - run `1` frame
  - press `Start`
  - run `30` frames
- Result: the later static city frame materially improved.
  - Before: the `BOMBED` text and nearby BG1 tiles were visibly garbled.
  - After: `BOMBED` is readable and the scene is noticeably cleaner.
- Release state benchmark remains healthy:
  - `--benchmark-state-gpu "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" "/Users/macos/src/MetalSNES/Star Fox (USA).state" 120`
    -> `172.2 FPS`

### Remaining
- The original save state's first restored city frame is still visibly bad after only `1` frame.
- That is now more likely to be stale/corrupted GSU RAM already baked into that older save state than a live PPU bug, because the next scene loaded through fresh GSU->VRAM DMA is clearly improved on the fixed build.
- General DMA timing is now modeled; HDMA timing is still simplified and may still matter for later Star Fox cleanup.

## 2026-03-12: Star Fox Briefing Artifacts Investigation

### Findings
- The current `/Users/macos/src/MetalSNES/Star Fox (USA).state` is not a clean gameplay state; it restores into a mostly static briefing/city scene and, after a scripted `Start` press through the debug server, advances into a different but still static `BOMBED` city frame.
- Two obvious PPU accuracy gaps were real:
  - mode 2 was still using the plain tiled BG path with no offset-per-tile support,
  - and `BGxHOFS/BGxVOFS` writes still used the wrong shared-latch formula.
- Neither of those fixes materially changed the restored city image on this state:
  - the loaded briefing frame remained visually the same after rerunning,
  - and the later `BOMBED` frame still showed the same broken skyline / edge seam.
- New PPU sampling confirmed why the first screenshot was a weak canary:
  - that scene is mostly BG2,
  - BG1 samples were transparent at several “missing ground” points,
  - and the active mode-2 offset entries on those samples only changed BG2 vertical scroll, not horizontal scroll.
- The scene also uses active HDMA on PPU registers:
  - channel 1 -> `$2100` (`INIDISP`)
  - channel 2 -> `$210F` (`BG2HOFS`)
  - channel 3 -> `$2126` (window left edge)
  so future visual debugging needs per-pixel/per-layer observability, not guesses from the final composite alone.

### Changes
- Implemented a CPU mode-2 renderer path that consults BG3 offset entries for BG1/BG2 sampling.
- Fixed PPU scroll-register write semantics:
  - `BGxHOFS` now preserves the low 3 bits from the previous horizontal latch,
  - `BGxVOFS` still uses the shared background offset latch.
- Added reusable PPU debug endpoints:
  - `/ppu/regs`
  - `/ppu/bg-sample?bg=<1-4>&x=<0-255>&y=<0-223>`
- Bumped save states to version `8` so the extra `BGHOFS` latch state is preserved; older v7 states still load by defaulting that latch from the old shared scroll latch.

### Validation
- Release build succeeded after each step.
- On the current Star Fox state:
  - `--benchmark-state` remains fast (`~177 FPS` in Release),
  - `/ppu/regs` reports the expected mode-2 / HDMA-heavy PPU setup,
  - `/ppu/bg-sample` shows BG2 vertical offset entries being applied on the suspect city scanlines.
- Scripted input through `/joypad/state?mask=0x1000` followed by `/emu/run?frames=30` reliably reaches the later static `BOMBED` frame at `PC=0x03BD8F`, which is now a better future canary than the original restored briefing image.

### Follow-up
- The repo's simplified priority notes for modes `2/3/4/5/6` were wrong.
- Cross-checking against the SNESdev background-mode priority table showed the correct back-to-front order is:
  - modes `2/3/4/5`: `BG2L -> OBJ0 -> BG1L -> OBJ1 -> BG2H -> OBJ2 -> BG1H -> OBJ3`
  - mode `6`: `OBJ0 -> BG1L -> OBJ1 -> OBJ2 -> BG1H -> OBJ3`
- Fixed those z tables in:
  - CPU PPU composition (`PPU.swift`)
  - Metal composition (`Shaders.metal`)
- Added a focused PPU diagnostic that now locks the mode-2 BG ordering:
  - BG1 low over BG2 low
  - BG2 high over BG1 low
  - BG1 high over BG2 high
- Added a reusable layer-isolated frame dump endpoint:
  - `/ppu/frame-dump-layer?mask=0x01|0x02|0x10&path=/tmp/file.png`
- That layer dump narrowed the current Star Fox state much more cleanly:
  - `BG1` already contains the city/buildings/text/Arwing cutout,
  - `BG2` is only the sky / mountains / water backdrop,
  - `OBJ` is empty in this scene,
  - window masking is disabled (`TMW=0`, `TSW=0`).
- The visible "floating buildings" on this save state therefore are not caused by missing sprites, color-window clipping, or the final BG1-vs-BG2 composition step.
- The current state still renders the same visually after the priority fix, so the remaining bug is upstream of final compositing:
  - either this save state's BG1 VRAM data is already bad from earlier buggy execution,
  - or the game logic / DMA path that produced this briefing frame is still wrong before the state is saved.

## 2026-03-12: Star Fox Release-State 1 FPS Regression

### Findings
- The new user report was reproducible on the real save state:
  - `--benchmark-state "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" "/Users/macos/src/MetalSNES/Star Fox (USA).state" 120`
  initially ran at only `3.8 FPS` in Release.
- The same saved state is in `BGMODE=2`, so the current Metal renderer eligibility check still falls back to the CPU PPU path there.
- Profiling the Release benchmark with `sample` showed the hottest stack inside `PPU.renderScanline()`:
  - `renderLayers()`
  - `renderBG4bpp(...)`
  - `writePixel(...)`
  - `String.init(format:)`
- That cost was self-inflicted:
  - pixel-trace logging was guarded only **inside** `appendPixelTrace(...)`,
  - but `writePixel(...)` was eagerly building formatted trace strings for every pixel even when no traced pixels were configured.

### Changes
- Made `PPU.appendPixelTrace(...)` take an `@autoclosure` and only materialize the formatted message after confirming:
  - tracing is enabled, and
  - the current pixel actually matches a configured trace target.

### Validation
- Rebuilt Release successfully.
- Re-ran the exact user state benchmarks:
  - `--benchmark-state ... "Star Fox (USA).state" 120` -> `208.8 FPS`
  - `--benchmark-state-gpu ... "Star Fox (USA).state" 120` -> `208.3 FPS`
- The near-identical CPU/GPU numbers on this state are expected because mode 2 is still on the CPU renderer; the 50x speedup came from removing hot-path trace string formatting, not from a renderer switch.

## 2026-03-12: Star Fox Load-State Artifacts and Super FX Performance

### Findings
- The post-load visual junk was a real buffer-sync bug:
  - save states restored only the presented `frontBuffer`,
  - but the next CPU-rendered present swaps `frontBuffer` and `backBuffer`,
  - so the first frame after load could briefly show stale pixels from the old back buffer.
- There was also a second UX gap on normal app load:
  - `EmulatorViewModel.loadState()` restored the state but did not immediately upload the restored framebuffer to the Metal texture.
- The gameplay slowdown was mostly self-inflicted by the conservative Super FX renderer policy:
  - `EmulatorCore` was forcing **all** Super FX carts onto the CPU PPU path,
  - even for scenes already in BG modes that the Metal path implements.
- Benchmarking the recovered Star Fox briefing state made the cost visible:
  - CPU PPU path: `120` frames in `14.065s` = `8.5 FPS`
  - Metal-enabled path on the same state: `120` frames in `5.822s` = `20.6 FPS`
- Release numbers confirmed this was not just "Star Fox is inherently slow" in the new path:
  - Release CPU PPU path: `25.6 FPS`
  - Release Metal-enabled path: `341.1 FPS`

### Changes
- `PPU.restorePresentedFramebuffer()` now copies the restored image into both front and back framebuffers.
- `EmulatorViewModel.loadState()` now uploads the restored framebuffer to the active renderer immediately after state restore.
- Removed the blanket `cartridge.coprocessor == .gsu` CPU-rendering override from `EmulatorCore` so Super FX scenes can use the normal BG-mode-based Metal eligibility checks again.
- Added reusable headless state benchmarking:
  - `--benchmark-state <rom> <state> [frames]`
  - `--benchmark-state-gpu <rom> <state> [frames]`

### Validation
- Restoring `/tmp/starfox-recovered-v7.state` and querying:
  - `/ppu/frame-summary?presented=1`
  - `/ppu/frame-summary?presented=0`
  returned identical coverage, color count, and sample pixels, confirming the restored back buffer now matches the presented buffer before the next frame runs.
- `--benchmark-state "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" /tmp/starfox-recovered-v7.state 120` reported `8.5 FPS`.
- `--benchmark-state-gpu "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" /tmp/starfox-recovered-v7.state 120` reported `20.6 FPS` on the same state.
- The same Release build benchmark commands reported `25.6 FPS` CPU-only and `341.1 FPS` with Metal enabled.

## 2026-03-12: Star Fox Frozen Save-State, Beam-Timing Fix

### Findings
- The original blue-planet Star Fox save state was not hard-dead in the PPU or Super FX core anymore; it was stuck in a CPU wait loop at `$03:C0A0` polling `$2137/$213C` for the horizontal beam counter.
- The first bug there was real 65C816 behavior:
  - `WAI` must resume on an IRQ edge even when the `I` flag masks IRQ vectoring,
  - but `cpu_step()` only resumed wait state when it was actually taking the IRQ vector.
- Fixing that exposed the deeper Star Fox-specific timing bug:
  - the emulator was budgeting each scanline as an isolated integer CPU slice and discarding instruction overrun at the scanline boundary,
  - so Star Fox kept sampling the same six horizontal counter values forever and never hit its accepted beam window.
- After carrying instruction overrun forward in master-clock units, the exact saved state immediately escaped `$03:C0A0` on frame 0 and progressed into later game code.
- A longer headless run from that same state no longer stayed on the tiny blue-planet freeze:
  - by frame `592` it reached the proper Corneria briefing screen with portraits, planet, and subtitle text visible.

### Changes
- Fixed `WAI` handling in `cpu_dispatch.c` so masked IRQs still wake the CPU.
- Changed `EmulatorCore.runScanline()` to schedule CPU execution against the real per-scanline master-clock budget and carry instruction overrun into the next scanline instead of resetting phase every line.
- Added reusable timing observability:
  - `/cpu/regs` now exposes `stopped`, `waiting`, `nmiPending`, `irqPending`, and the scanline `masterCarry`.
- Bumped save states to version `7` and serialized the scanline master-cycle carry so timing-sensitive Super FX states restore to the same execution phase.

### Validation
- `--diagnose-state "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" "/Users/macos/src/MetalSNES/Star Fox (USA).state" 12` now shows:
  - frame `0`: `PC $03C0A0->$03C78B`
  - later frames continue advancing through `$03BDxx` and beyond instead of pinning at the original loop.
- A debug-server run from the same frozen state followed by `/emu/run?frames=592` reached `PC=0x03C75F` and produced a non-black Corneria briefing frame dump at `/tmp/starfox-after-592.png`.
- Saving that recovered state produced `/tmp/starfox-recovered-v7.state` with format version `7`, and restoring it reproduced the same `PC=$03BD83` and `masterCarry=12` snapshot.

## 2026-03-12: Super FX Save States and Star Fox STP Repro

### Findings
- `SaveState.swift` had no Super FX block at all, which is why the app had been explicitly blocking save/load for GSU carts.
- The missing piece was not ROM/RAM ownership; it was serializing the internal GSU execution state:
  - registers, flags, cache, pixel cache, trace ring, cycle budget, and IRQ line.
- A real Star Fox state now restores bit-for-bit at the CPU and GSU register level:
  - a state captured at frame 120 restored to `PC=$7E4F37`,
  - the restored GSU snapshot matched exactly,
  - and the next frame after restore matched the next frame from the original run.
- The presented CPU framebuffer now rides inside the save-state blob as well, so a freshly restored paused Super FX state shows the same saved image immediately instead of waiting for another frame.
- While scripting the slow Star Fox menu path through the debug server, a separate correctness bug showed up:
  - after the title/menu sequence begins advancing, the CPU can fall into repeated `STP`,
  - and the headless process eventually died after log spam with a malloc double-free report.
  - That freeze is separate from save-state support and should be debugged as the next Star Fox correctness issue.

### Changes
- Added native Super FX save/load serialization in `superfx.cpp` / `superfx.h`.
- Added Swift save/load bridging in `SuperFX.swift`.
- Bumped the global save-state format to version `6`, added an optional Super FX block in `SaveState.swift`, and serialized the presented PPU framebuffer for immediate visual restores.
- Re-enabled normal app save/load actions for Super FX carts in `EmulatorViewModel.swift`.
- Added reusable debug-server endpoints:
  - `/emu/save-state?path=...`
  - `/emu/load-state?path=...`
- Taught the debug server to percent-decode query parameters so file paths with spaces work cleanly.

### Validation
- `xcodebuild -project /Users/macos/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build CODE_SIGNING_ALLOWED=NO` succeeded after the save-state work.
- `--serve-rom "/Users/macos/src/MetalSNES/Star Fox (USA).sfc"` + `/emu/run?frames=120` + `/emu/save-state?path=/tmp/starfox-120-v6.state` produced a `555952`-byte Super FX state file with the presented framebuffer included.
- `--serve-state "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" /tmp/starfox-120-v6.state` restored to the same CPU and GSU register snapshots captured before save, and `/ppu/frame-summary` immediately matched the saved non-black frame without advancing.
- Advancing one frame after restore reproduced the same CPU state, GSU state, and frame summary as the original run one frame later.

## 2026-03-12: Star Fox Follow-up, Conservative Super FX CPU-PPU Fallback

### Findings
- The earlier mode-2 fallback fixed the outright black-screen case, but Star Fox still had scene-specific rendering risk on the Metal path.
- Repeated Star Fox debugging from live ROM boot kept converging on the same practical conclusion:
  - the CPU PPU path was the trustworthy renderer for this cart,
  - while the Metal compositor was still only partially validated against Super FX scenes.
- The remaining user report was no longer "nothing renders" but "some scenes still look wrong / incomplete," which is the wrong time to keep splitting output across two different renderers.

### Changes
- Added a conservative `PPU.forceCPURendering` switch.
- `EmulatorCore` now forces CPU PPU rendering for Super FX cartridges during core setup instead of only relying on BG-mode-based Metal gating.

### Validation
- This change is deliberately narrow:
  - it only affects Super FX carts,
  - and it leaves the existing non-Super-FX Metal fast path unchanged.
- A fresh build after the fallback change is required before re-checking the live Star Fox GUI path.

## 2026-03-12: Star Fox "Black Screen" Was the GPU PPU Path

### Findings
- The ROM execution path was not the remaining blocker anymore:
  - headless CPU rendering at frame 240 produced a valid Star Fox image,
  - including a sparse but recognizable Arwing/starfield frame,
  - so the game was not actually "rendering nothing."
- The earlier `INIDISP=0x80` snapshots were misleading on their own because headless diagnostics sample the presented frame from scanline 223, while the PPU register snapshot is taken later during VBlank.
- Reusable observability made the remaining issue tractable:
  - `/cpu/write-log/clear` made it possible to inspect one frame of register traffic at a time,
  - `/bus/regs` now exposes `HTIME`, `VTIME`, `TIMEUP`, `MDMAEN`, and `HDMAEN`,
  - `/ppu/frame-summary` quantified the presented frame instead of guessing from a few pixels,
  - and `/ppu/frame-dump` confirmed the CPU-rendered output visually.
- The actual GUI black-screen bug was in the Metal PPU fast path:
  - `Renderer/Shaders.metal` only has explicit composition logic for modes 0, 1, 3, and 7,
  - but `PPU.shouldUseGPURendering()` still allowed all modes 0 through 7,
  - and Star Fox is running in BG mode 2.
- That meant the app window could take a GPU path that does not correctly implement the mode Star Fox needs, while the CPU PPU path was already producing the right image.

### Changes
- Added debug-server observability for this investigation:
  - `/cpu/write-log/clear`
  - expanded `/bus/regs`
  - `/ppu/frame-summary`
  - `/ppu/frame-dump`
- Restricted GPU PPU rendering in `PPU.swift` to the modes the current Metal shader actually implements.
  - Modes 2, 4, 5, and 6 now fall back to the CPU renderer instead of trying to use the incomplete Metal path.

### Validation
- `--diagnose-rom "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" 240` still showed a sparse presented image with non-black pixels and a wide non-black bounding box instead of a truly empty frame.
- `/ppu/frame-summary?presented=1` at frame 240 reported:
  - `964` non-black pixels,
  - `18` unique colors,
  - bounding box `x=17..236`, `y=24..204`.
- `/ppu/frame-dump?presented=1` wrote `/tmp/metalsnes-frame.png`, which showed a recognizable Star Fox frame on the CPU path.
- `xcodebuild -project /Users/macos/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build CODE_SIGNING_ALLOWED=NO` succeeded after the fallback change.
- `--benchmark-gpu "/Users/macos/src/MetalSNES/Star Fox (USA).sfc"` still completed after the mode-gating change.

## 2026-03-12: Super FX ROM Diagnostics and Debug-Server Introspection

### Findings
- The first-pass Super FX execution path was enough to get Star Fox through benchmarked frames, but it was still hard to debug cleanly from a fresh boot.
- The initial attempt at Super FX register introspection was wrong in two separate ways:
  - several getters were accidentally calling nonexistent methods,
  - and others reused `readIO()`, which can mutate state such as the IRQ latch on `$3031`.
- The existing headless tooling only supported save-state diagnostics or a fully automated benchmark, which made “boot the ROM, inspect state, advance a few frames, inspect again” harder than it needed to be.
- The HTTP debug server also had a latent queue-lifetime bug:
  - `NWListener` and per-connection handlers were started on inline `DispatchQueue(...)` instances,
  - so the server could claim to be listening without reliably keeping those queues alive.

### Changes
- Reworked the Super FX bridge so `superfx.cpp` now exposes side-effect-free debug snapshots of the coprocessor register state.
- Added a Swift-facing `SuperFXSnapshot` in `Emulator/SuperFX.swift`.
- Extended the HTTP debug server with:
  - `/emu/run?frames=N` to advance a paused headless core deterministically,
  - `/superfx/regs` for raw GSU register/flag state,
  - and `/superfx/ram` for cart RAM inspection on Super FX boards.
- Added new headless CLI paths:
  - `--diagnose-rom <rom> [frames]`
  - `--serve-rom <rom>`
- Fixed `DebugServer.swift` queue lifetime by retaining the listener/connection queues and only logging “Listening” from the listener `.ready` state.
- Updated the README so the documented CLI/debug flow matches the new ROM-first diagnostic path.

### Validation
- `xcodebuild -project /Users/macos/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build CODE_SIGNING_ALLOWED=NO` succeeded after the Super FX/debug-server changes.
- `--serve-rom "/Users/macos/src/MetalSNES/Star Fox (USA).sfc"` now starts a usable live debug session.
  - Root endpoint returns the expanded endpoint list including `/emu/run`, `/superfx/regs`, and `/superfx/ram`.
  - `/emu/run?frames=120` advanced the paused core to frame 122 and reported CPU state like `pc=0x02DCC5`, `tm=0x17`, `ts=0x07`.
  - `/superfx/regs` reported live GSU state after that run, including `R15=0xA89D`, `PBR=0x01`, `SFR=0x0006`.
  - `/superfx/ram?addr=0x0000&len=16` returned the expected 32 KB cart RAM window and readable bytes.
- `--diagnose-rom "/Users/macos/src/MetalSNES/Star Fox (USA).sfc" 120` completed from power-on and dumped repeatable runtime/PPU state instead of failing on cartridge parsing or UI startup.

## 2026-03-12: First-pass Super FX / Star Fox Execution

### Findings
- The earlier Super FX rejection path was honest, but it also hid the real work still missing:
  - Star Fox needs a real GSU execution core,
  - Star Fox uses 32 KB of cartridge RAM even though its header reports zero SRAM,
  - and the existing bus only knew plain LoROM/HiROM CPU mappings.
- The current emulator architecture is still usable for a first pass:
  - there was already a C bridge in-tree for the CPU core,
  - the bus already owned the cartridge RAM buffer,
  - and the emulation loop had one clear place to step another coprocessor alongside the CPU/APU.
- Save states and run-ahead were a correctness trap for any new coprocessor path because `SaveState.swift` has no Super FX serialization at all.

### Changes
- Added a native Super FX bridge in `CCore/superfx.cpp` and `CCore/superfx.h`, plus a small Swift wrapper in `Emulator/SuperFX.swift`.
  - The core is adapted from the bsnes GSU implementation and trimmed to the pieces needed for first-pass execution in this codebase.
- `Cartridge.swift` no longer rejects Super FX carts outright.
  - It now detects a first-pass GSU board variant,
  - allocates 32 KB of cart RAM for Star Fox-style GSU carts even when the ROM header reports zero SRAM,
  - and exposes CPU-visible Super FX ROM/RAM mapping helpers for the bus.
- `Bus.swift` now routes Super FX register, ROM, and RAM accesses through the new coprocessor path.
- `EmulatorCore.swift` now steps the GSU alongside CPU execution and forwards the GSU IRQ line into the CPU IRQ path.
- `EmulatorViewModel.swift` now disables run-ahead for Super FX carts and blocks save-state actions until coprocessor state serialization exists.

### Validation
- `xcodebuild -project /Users/macos/src/MetalSNES/MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build CODE_SIGNING_ALLOWED=NO` succeeded.
- `/tmp/MetalSNESDerived/Build/Products/Debug/MetalSNES.app/Contents/MacOS/MetalSNES --benchmark "/Users/macos/src/MetalSNES/Star Fox (USA).sfc"` completed successfully on the real ROM.
  - `CPU Reset: PC=$FF96, P=$34, S=$01FF, E=1`
  - `Benchmark: 120 frames in 4.521 sec = 26.5 FPS (0.4x realtime)`

## 2026-03-12: Star Fox / Super FX Detection

### Findings
- `Cartridge.swift` only implements plain LoROM/HiROM ROM mapping.
- There is no Super FX / GSU path anywhere in the emulator, so Star Fox was never going to be a small renderer bug or mapper bug.
- Worse, the app still treated those ROMs like ordinary carts:
  - GUI load would just surface a generic ROM failure,
  - the benchmark path used `try! Cartridge(data:)`,
  - and headless state-serving collapsed multiple parse failures into "Cannot parse ROM".

### Changes
- Added coprocessor detection from the SNES internal ROM header chipset byte (`$FFD6` / equivalent).
- `Cartridge` now rejects unsupported enhancement-chip carts with a specific error message, including Super FX / GSU carts such as Star Fox.
- Tightened CLI error reporting so benchmark and serve-state modes surface the real cartridge error instead of crashing or printing a generic parse failure.
- Updated the README status line so the repo no longer implies enhancement-chip cartridges are expected to work.

## 2026-03-12: Sub-screen Window Fix + Headless PPU Diagnostics

### Findings
- The CPU renderer still had a real sub-screen window bug despite the earlier notes about `TSW` support:
  - `writePixel()` checked `TSW` while rendering the sub-screen,
  - but `isWindowMasked()` independently re-checked only `TMW`,
  - so sub-screen layer windows were silently skipped whenever `TSW` was enabled without the matching `TMW` bit.
- The built-in `PPUDiagnostic` helper also had a correctness bug of its own:
  - it wrote CGRAM bytes directly,
  - which bypassed the cached RGB conversion table used by the renderer,
  - so the diagnostic path could report misleading results even when the renderer was behaving correctly.
- The headless CLI paths still fell back to hardcoded local ROM/state filenames (`mario.sfc`, `zelda.sfc`, `zelda.state`) that are not present in this checkout, which made missing-argument invocations fail in a confusing way.

### Changes
- Fixed the CPU PPU window path in `PPU.swift` by removing the redundant `TMW`-only gate from `isWindowMasked()`.
  - The caller already decides whether the active screen uses `TMW` or `TSW`, so the helper now only evaluates the actual window geometry and logic.
- Expanded `PPUDiagnostic.swift`:
  - each diagnostic test now gets a fresh `PPU`,
  - CGRAM writes now go through the real `$2121/$2122` register path so the color cache stays coherent,
  - reset now also clears window state and restores internal PPU snapshot state,
  - and a new regression test covers sub-screen masking with `TSW` enabled and `TMW` disabled.
- Added a new headless CLI mode:
  - `--ppu-diagnostic` runs the built-in PPU diagnostic suite without opening the UI.
- Tightened CLI argument handling in `MetalSNESApp.swift`:
  - `--benchmark`, `--benchmark-gpu`, `--diagnose-state`, and `--serve-state` now fail fast with explicit usage text when required paths are omitted instead of guessing nonexistent local files.
- Updated `README.md` and `ISSUES.md` so the repo docs match the current renderer and CLI behavior.

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

## 2026-03-10: Zelda Rain Intro Black Screen Debug

### Symptom
- Loading `zelda.state` in the intro/rain sequence produced a fully black frame and appeared frozen.
- The first question was whether the game logic was still advancing offscreen or whether emulation was actually wedged.

### Investigation
- Added a headless `--diagnose-state <rom> <state> [frames]` path so the app can load a ROM plus save state without the normal window path and dump CPU/PPU/HDMA state per frame.
- Fixed the runtime framebuffer diagnostic to sample the presented/front buffer after `runOneFrame()`, not the back buffer left behind after the headless swap.
- Running `zelda.sfc` + `zelda.state` immediately showed:
  - `PC=$00F3A6` on every frame
  - `INIDISP=$80` on every frame
  - the frame hash and color histogram staying black
- Disassembling the LoROM bytes around `$00:F3A6` showed Zelda polling `$2137/$213D` and comparing the latched vertical counter against `$00C0`.
- Our PPU still returned `0` for `$213C/$213D`, so the game sat in forced blank forever waiting for a beam position that never advanced.

### Fix
- Implemented beam-position tracking in `EmulatorCore.runScanline()` and publish the current scanline/H-dot to the PPU before CPU steps.
- Implemented `$2137` latch behavior plus `$213C/$213D` reads in `PPU.swift`:
  - latches current H/V beam counters on `$2137`
  - returns low/high counter bytes on successive `$213C/$213D` reads
  - resets the read toggles on `$213F`

### Result
- The exact bad save state now leaves the wait loop on the first frame:
  - `PC $00F3A6 -> $008034`
  - `INIDISP $80 -> $0F`
- Over a longer 60-frame diagnostic run:
  - HDMA re-enables on channel 7
  - the frame hash continues changing
  - the runtime framebuffer ends with `9/9` sampled points non-black and `24` sampled colors
- A 5-second live launch with `--rom zelda.sfc --state zelda.state` produced no runtime output/errors.

## 2026-03-10: OBJ Top-Edge Visibility and Non-Square Sprite Fix

### Symptom
- In Zelda, sprites near the top of the screen could disappear even when a tall sprite should still extend down into the visible area.
- The current OBJ path also only modeled square sprite sizes, which is incorrect for SNES size modes 6 and 7.

### Root Cause
- `PPU.swift` used a custom heuristic to suppress wrapped sprites with raw Y values near `$F0`, intended to avoid top-line junk from hidden sprites.
- That heuristic also suppressed legitimate wrapped sprites at the top edge.
- The sprite size table only supported square sizes, so modes with `16x32` / `32x64` style objects were being evaluated and flipped incorrectly.

### Fix
- Added a shared OBJ dimension helper using the bsnes width/height tables for all 8 base-size modes.
- Updated the per-scanline sprite cache to use the true sprite height and restored proper vertical wrap behavior instead of the old hidden-sprite suppression heuristic.
- Updated sprite rendering to use real width/height values and bsnes-style vertical flip handling for non-square sprites.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build`
- Build succeeded cleanly after the OBJ changes.

## 2026-03-10: Zelda Throne Room Layering Investigation

### Symptom
- A Zelda save state that drops directly into the altar/throne-room scene still looked wrong from a layering perspective.
- The open question was whether this was a Metal-only composition bug, a shared CPU/GPU PPU priority bug, or a scene-specific sprite ordering issue.

### Investigation
- Corrected the Mode 1 priority tables to match bsnes for `BGMODE` bit 3 set:
  - CPU path in `PPU.swift`
  - Metal path in `Shaders.metal`
- Added a CPU-vs-GPU framebuffer comparison to the save-state diagnostic.
- Added headless framebuffer readback from the Metal renderer so the diagnostic can compare real GPU output against the CPU reference.
- Dumped the save-state scene registers and found:
  - `BGMODE=$09`
  - `TM=$16`
  - `TS=$01`
  - `CGWSEL=$02`
  - `CGADSUB=$20`
- That means the scene is using Mode 1 with the special priority bit set, main screen = `BG2 + BG3 + OBJ`, and sub screen = `BG1`.
- Verified that OAM priority rotation is not involved here:
  - `OAMADD=$0000`
  - rotation bit off
- Dumped the visible sprites in the altar region after the first frame and found two distinct sprite groups:
  - Link/body sprites at OBJ priority `2`
  - altar/front-piece sprites at OBJ priority `3`
- Dumped the rendered save-state frame to `/tmp/metalsnes-zelda-frame0.png` for direct inspection.

### Result
- The CPU and GPU framebuffers match exactly for frame 0, so this is not a Metal-only bug.
- The altar/front-piece occluders in this scene are already being emitted as higher-priority OBJ entries than Link, so the remaining issue is not explained by missing GPU priority handling or missing OAM rotation.
- At this point the bug is narrowed to shared PPU behavior or to a mismatch between the expected game scene and the current reference assumptions.

### Additional Tracing
- Added per-pixel trace hooks in `PPU.swift` plus save-state diagnostics that:
  - dump the winning/losing writes at exact overlap pixels
  - dump visible altar/link OAM entries
  - dump BG2/BG3 tile samples at those same pixels
  - write the rendered frame to `/tmp/metalsnes-zelda-frame0.png`
- The traced overlap points in the center of the altar show:
  - BG2 writes the floor/background at `z=4`
  - the altar/front-piece OBJ sprites win at `z=9`
  - Link's body/head OBJ sprites lose there at `z=6`
- Just below the altar edge:
  - the altar OBJ is no longer present
  - Link's OBJ wins over BG2 as expected
- BG3 is not the missing occluder at those pixels:
  - the sampled BG3 tile entries exist, but the pixel value is `0` (transparent) at the traced overlap points

### Current Interpretation
- The user-visible overlap pixels that were traced are already composited in the expected order:
  - altar/front OBJ above Link OBJ above BG2
- So the remaining throne-room complaint is unlikely to be a simple OBJ-vs-BG priority-table bug.
- The next debugging step was to determine whether the shared OBJ compositor was resolving sprite-vs-sprite overlap incorrectly.

## 2026-03-10: Zelda Throne Room Fix - OBJ OAM Order vs Priority

### Root Cause
- The shared CPU and Metal renderers were resolving sprite overlap purely by the SNES OBJ priority bits.
- bsnes does not do that. It first resolves the winning OBJ pixel by OAM order, and only then uses that winning sprite pixel's priority value when comparing OBJ against BG layers.
- In the throne-room state, Link uses a lower OAM index than the altar/front-piece sprite, so Link's cap should win at the marked overlap pixel even though the altar sprite carries a higher OBJ priority value.

### Changes
- `PPU.swift` now builds a per-scanline OBJ winner buffer first:
  - sprite pixels are resolved in cached OAM order,
  - later writes in that pass win because the cache is already ordered high-index to low-index,
  - and only the final winning OBJ pixel for each X coordinate is compared against the BG stack.
- `Shaders.metal` now mirrors the same rule on the Metal path:
  - it samples the winning OBJ pixel by OAM order first,
  - then applies the winning sprite sample to the composed BG result using the sprite's BG-facing priority.

### Expected Result
- In the Zelda throne-room save state, the cap pixel near `(127, 65)` should now come from Link rather than the altar/front overlay sprite.
- This fix should also correct any other scenes where lower-index sprites were being incorrectly hidden by later OAM entries with higher OBJ priority bits.

## 2026-03-10: Phase 2 Architecture Plan

### Context
- The current hybrid renderer keeps a CPU reference path and a Metal live path, but both still independently implement too much SNES rendering policy.
- That makes correctness debugging harder than it needs to be because sprite rules, window rules, color math rules, and mode-specific priority behavior can drift across two implementations.

### Plan
- Added `PHASE2.md` to define the next architecture target:
  - CPU/PPU remains authoritative for correctness-critical decisions
  - Metal remains the default live composition/presentation path
  - the key migration steps are canonical priority tables, resolved per-scanline sprite winner buffers, resolved window masks, and more explicit color-math plans
- The plan is intentionally incremental and keeps the CPU renderer alive as a reference backend and parity oracle.

## 2026-03-10: Trinitron Tuning + Responsive Header + Per-Filter Image Profiles

### Context
- The Trinitron preset was reading too much like a visible overlay mesh instead of a softer phosphor/grille structure.
- The in-stage header could wrap visible buttons in smaller windows.
- The image-tuning HUD was still too large and awkward to use, and the global brightness/contrast/sharpness/saturation settings were not a good fit once the filters diverged more.

### Changes
- Retuned the Trinitron preset in `Shaders.metal` and `MetalRenderer.swift`:
  - reduced mask/scanline harshness,
  - softened the visible grille contrast,
  - and added a dedicated Trinitron `glowAmount` control path.
- Reworked display persistence in `Types.swift` so image tuning is stored per filter profile instead of one global set of values.
- Updated the SwiftUI shell in `ContentView.swift`:
  - the stage header now has responsive regular/medium/compact layouts so action buttons stop wrapping,
  - and the display HUD is now a smaller tuner panel with dial-style controls instead of the larger scrolling settings stack.
- The tuner only shows the `Glow` dial when `Trinitron` is selected.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
- A short `mario.sfc` smoke run produced no runtime output in `/tmp/metalsnes-ui-smoke.txt`.

## 2026-03-10: Image Tuner Drag Fix + Label Layout Cleanup

### Context
- The `Image Tuner` dials were hard to use because dragging them could trigger whole-window dragging.
- The compact tuner chips were also truncating labels too aggressively in the fixed-width HUD.

### Changes
- Disabled global `isMovableByWindowBackground` window dragging and replaced it with a dedicated drag region behind the title block in `ContentView.swift`.
- Reworked the tuner chip row into a small two-column grid, widened the HUD slightly, and allowed chip values to wrap to two lines instead of truncating immediately.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
- A short `mario.sfc` smoke run again produced no runtime output in `/tmp/metalsnes-ui-smoke.txt`.

## 2026-03-10: Header Drag Region Regression + Compact Image Tuner Bar

### Context
- The first pass at restoring custom window dragging expanded the header overlay to nearly the full stage, which also made the display tuner feel like a large side sheet again.
- The tuner controls were still too large, and the action chips could truncate text awkwardly.

### Changes
- Replaced the unconstrained header drag-region layering with a drag handle attached only to the title block background in `ContentView.swift`.
- Reshaped the `Image Tuner` into a compact top utility bar:
  - a smaller title row,
  - a horizontal row of action chips,
  - and a horizontal row of smaller dial controls.
- Widened the tuner bar while reducing the individual control sizes so full words are more likely to fit without the overlay becoming dominant.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
- A short `mario.sfc` smoke run produced no runtime output in `/tmp/metalsnes-ui-smoke.txt`.

## 2026-03-10: Smaller Tuner + Full-Word Header Menus

### Context
- The previous compact tuner was still too large relative to the game viewport.
- At medium window sizes the header status pills were still compressing down to unreadable `FIL...` / `SC...` / `LA...` labels.

### Changes
- Switched medium/compact header status controls to dedicated single-line menu chips with full words instead of two-line label/value pills.
- Reduced the tuner width again and scaled down the individual chips and dial controls so the overlay takes less of the game area.
- Let tuner chip values wrap to two lines where needed instead of forcing aggressive truncation.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
- A short `mario.sfc` smoke run produced no runtime output in `/tmp/metalsnes-ui-smoke.txt`.

## 2026-03-10: Dynamic Trinitron Tuner Width + Header Space Rebalancing

### Context
- The tuner still clipped when the Trinitron-only `Glow` control appeared.
- The header status chips could still ellipsize when the left title area and action cluster competed for width.

### Changes
- Made the display tuner width dynamic in `ContentView.swift`, with a wider cap when `Trinitron` is selected so the extra `Glow` dial has room.
- Rebalanced the header layout in `ContentView.swift` so the title area yields width first, and forced the status/action clusters to keep their intrinsic width instead of collapsing their labels.

### Validation
- `xcodebuild -project MetalSNES.xcodeproj -scheme MetalSNES -configuration Debug -derivedDataPath /tmp/MetalSNESDerived build` succeeded.
