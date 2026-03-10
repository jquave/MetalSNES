# MetalSNES Development Log

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
Added HTTP debug server (`DebugServer.swift`) on port 8765 for real-time SPC/DSP inspection via `curl`. See `AUDIO_DEBUG.md` for endpoints and usage. Defaults to off — call `emulatorCore.startDebugServer()` to enable.

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

## 2026-03-09: PPU Diagnostic Tests + Chr Base Address Fix

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

### Bug Fix: Chr base address was 2× too small
- **Root cause**: BG12NBA/BG34NBA chr base calculation used `nibble << 13` (8KB steps).
- **Correct**: Each nibble = 8K words = 16KB bytes, so should be `nibble << 14`.
- DMA evidence: Zelda sets bg12nba=0x22, writes chr data at VRAM word 0x4000 (byte 0x8000).
  Old code: chr base = 2 << 13 = 0x4000 bytes. Correct: 2 << 14 = 0x8000 bytes.
- This caused tile graphics to be read from the wrong VRAM location, producing garbled fills
  inside the ZELDA title screen letters (outlines were correct because tilemap positions were fine).
- Fixed in both `renderBG4bpp` and `renderBG2bpp`.

### Findings from Runtime Dump
- Zelda title screen: `tm=0x10` (sprites only) — all visible content rendered as sprites
- CGRAM: only 14/256 colors loaded (palette 13 = sprite palette), BG palettes empty
- WRAM CGRAM source ($7E:C500): 27/512 non-zero bytes — palette buffer not fully initialized
- This suggests CPU instruction bugs preventing full palette initialization
- Infinite recursion bug in log function (print→log→log→...) caused silent crash — fixed

### Current State
- All 4 PPU unit tests PASS
- Zelda title screen renders with correct colors for sprites (gold triforce, white text)
- Chr base fix should improve BG tile rendering once tm enables BGs
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
