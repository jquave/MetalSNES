# Audio Debug Notes

## Debug Server

A real-time HTTP debug server for inspecting SPC700/DSP state while the emulator runs.

### Performance Impact
The server uses `NWListener` (Network.framework) and is effectively idle when no client is connected. It only does work when a request arrives.

### Starting the Server
The current app starts the debug server automatically when emulation starts (`EmulatorViewModel.toggleEmulation()` calls `core.startDebugServer()`).

### Files
| File | Role |
|------|------|
| `MetalSNES/Emulator/DebugServer.swift` | HTTP server. Uses `NWListener`. Parses GET requests, returns JSON. |
| `MetalSNES/Emulator/EmulatorCore.swift` | Owns `debugServer` property. `startDebugServer()` creates and wires it up. |

### Endpoints (all return JSON, port 8765)

| Endpoint | Description |
|----------|-------------|
| `/spc/ram?addr=0x0000&len=16` | Read SPC RAM range (hex values) |
| `/spc/ram/write?addr=0x01&val=0x01` | Write single byte to SPC RAM |
| `/spc/ports` | Read CPU→SPC and SPC→CPU port values |
| `/spc/ports/write?port=2&val=0x01` | Write to CPU→SPC port (0-3) |
| `/spc/regs` | SPC700 registers (A, X, Y, SP, PC, PSW, flags) |
| `/spc/timers` | Timer state (enabled, divisor, counter, internal) |
| `/dsp/regs` | All 128 DSP register values |
| `/dsp/regs/write?reg=0x4C&val=0x01` | Write a DSP register directly |
| `/dsp/kon?voice=0&srcn=0&pitch=0x1000` | Convenience endpoint to configure a voice and trigger KON |
| `/dsp/voices` | Per-voice: keyed, envLevel, pitch, srcn, brrAddr, volumes |
| `/cpu/wram?addr=0x1DFB&len=16` | Read CPU WRAM range |
| `/cpu/wram/write?addr=0x1DFB&val=0x01` | Write CPU WRAM byte |
| `/cpu/regs` | Main CPU register snapshot |
| `/cpu/write-log` | Recent CPU writes to APU ports / sound mirrors |
| `/cpu/trace?ms=50` | Short live CPU trace capture |
| `/cpu/recent-trace?count=200` | Snapshot of recent CPU execution history |
| `/ppu/vram?addr=0x0000&len=16` | Read PPU VRAM bytes |
| `/bus/regs` | Bus-side interrupt / VBlank register state |
| `/audio/stats` | Buffer level, sample count, non-zero count, KON count |
| `/spc/trace?count=500` | Capture N SPC instructions (blocks until done) |
| `/spc/inject?p0=0x01&p2=0x01` | Pause briefly and atomically inject CPU→SPC ports |
| `/wram/range?addr=0x1DF9&len=8` | Read arbitrary WRAM range |
| `/wram/watch?addr=0x1DFB` | Set a WRAM watchpoint |
| `/wram/watch/log` | Read recent WRAM watchpoint writes |

### Example Usage
```bash
curl -s 'http://localhost:8765/spc/ports' | jq .
curl -s 'http://localhost:8765/dsp/voices' | jq '.[] | select(.keyed==true)'
curl -s 'http://localhost:8765/spc/trace?count=200' | jq '.trace[:10]'
```

---

## Key Audio Fixes Applied

### 1. Direct Page 16-bit wrapping (CRITICAL)
`readDP16`/`writeDP16` now wrap within the direct page. Previously, offset $FF would read $00FF and $0100 instead of $00FF and $0000. This broke N-SPC's 16-bit track pointers (MOVW/ADDW/SUBW). Same fix applied to `addrIndirectX` and `addrIndirectY`.

### 2. TSET1/TCLR1 flag note
An earlier note here claimed the flags should use `A & mem`. That was incorrect. The current implementation's `A - mem` flag behavior matches the SPC700 programming manual.

### 3. ADDW/SUBW half-carry
H flag now computed on high byte addition/subtraction with carry/borrow from low byte, instead of incorrect bit-12 boundary test.

### 4. POP A/X/Y flags
`POP A`, `POP X`, and `POP Y` no longer clobber `N/Z`. That bug was breaking SMW's live DSP pitch-write helper after `POP A`.

### 5. SLEEP/STOP idle semantics + SPC trace logging
`SLEEP`/`STOP` now leave `PC` advanced and idle correctly instead of rewinding `PC` and effectively deadlocking the core. The SPC trace logger was also fixed so its "post" register dump is actually post-instruction.

### 6. APU scheduling clock rate
The APU scheduler now runs the SPC in the correct ~2.048 MHz S-SMP clock domain and generates one DSP sample every 64 SMP clocks. An earlier half-rate scheduler was causing music tempo and SFX timing to skew badly.

---

## Historical Status (kept for reference)
- This section is no longer authoritative; later traces showed SMW sending a music command on port 2 and the DSP generating non-zero samples.
- **SFX work**: Startup ding plays correctly
- **Music did not play in that build**: No audible music on Super Mario World title screen
- In that build, KON was OR-latched to avoid lost key-on events. Current code uses last-write latch semantics instead.
- In that build, DSP sample generation was interleaved at about 32 SPC cycles per sample. Current code uses 64 SMP clocks per sample.
- BRR decoding, ADSR envelopes, gaussian interpolation, echo/FIR all implemented
