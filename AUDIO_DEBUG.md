# Audio Debug Notes

## Debug Server

A real-time HTTP debug server for inspecting SPC700/DSP state while the emulator runs.

### Performance Impact
The server uses `NWListener` (Network.framework) — event-driven with **zero CPU cost when no client is connected**. It only does work when a `curl` request arrives. Defaults to **off**.

### Starting the Server
The current app starts the debug server automatically when emulation starts (`EmulatorViewModel.toggleEmulation()` calls `core.startDebugServer()`).

### Files
| File | Role |
|------|------|
| `MetalSNES/Emulator/DebugServer.swift` | HTTP server (~170 lines). Uses `NWListener`. Parses GET requests, returns JSON. |
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
| `/audio/stats` | Buffer level, sample count, non-zero count, KON count |
| `/spc/trace?count=500` | Capture N SPC instructions (blocks until done) |

### Example Usage
```bash
curl -s 'http://localhost:8765/spc/ports' | jq .
curl -s 'http://localhost:8765/dsp/voices' | jq '.[] | select(.keyed==true)'
curl -s 'http://localhost:8765/spc/trace?count=200' | jq '.trace[:10]'
```

---

## SPC700 Bug Fixes Applied

### 1. Direct Page 16-bit wrapping (CRITICAL)
`readDP16`/`writeDP16` now wrap within the direct page. Previously, offset $FF would read $00FF and $0100 instead of $00FF and $0000. This broke N-SPC's 16-bit track pointers (MOVW/ADDW/SUBW). Same fix applied to `addrIndirectX` and `addrIndirectY`.

### 2. TSET1/TCLR1 flag note
An earlier note here claimed the flags should use `A & mem`. That was incorrect. The current implementation's `A - mem` flag behavior matches the SPC700 programming manual.

### 3. ADDW/SUBW half-carry
H flag now computed on high byte addition/subtraction with carry/borrow from low byte, instead of incorrect bit-12 boundary test.

---

## Historical Status (kept for reference)
- This section is no longer authoritative; later traces showed SMW sending a music command on port 2 and the DSP generating non-zero samples.
- **SFX work**: Startup ding plays correctly
- **Music did not play in that build**: No audible music on Super Mario World title screen
- KON latch was changed to OR (`|=`) to prevent lost key-on events
- DSP sample generation now interleaved with SPC execution (~32 SPC cycles per DSP sample)
- BRR decoding, ADSR envelopes, gaussian interpolation, echo/FIR all implemented
