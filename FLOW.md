# MetalSNES — Code Flow & Architecture

## Top-Level File Map

```
MetalSNES/
├── App/
│   ├── MetalSNESApp.swift         @main entry, WindowGroup
│   ├── EmulatorViewModel.swift    ObservableObject, ROM loading, SRAM persistence, thread mgmt
│   └── ContentView.swift          SwiftUI layout, HSplitView, file picker, controls
├── CPU/
│   ├── CPU.swift                  Swift wrapper around C dispatch, trace logging
│   └── CPUInstructions.swift      Opcode→mnemonic table for disassembly
├── CCore/
│   ├── cpu_dispatch.c             65C816 executor, 256-entry dispatch table
│   └── cpu_dispatch.h             CPURegisters struct, BusReadFunc/BusWriteFunc
├── Emulator/
│   ├── EmulatorCore.swift         Frame/scanline loop, H/V IRQ, HDMA integration
│   ├── Bus.swift                  24-bit address decode, register routing, SRAM persistence
│   ├── PPU.swift                  Scanline renderer, priority system, Mode 0/1, MPY regs
│   ├── APU.swift                  APU orchestration: SPC700, DSP, audio output, port bridge
│   ├── SPC700.swift               SPC700 CPU, timers, boot ROM, DSP/port I/O
│   ├── DSP.swift                  S-DSP voices, BRR decode, ADSR/GAIN, echo/FIR
│   ├── AudioOutput.swift          AVAudioEngine source node + ring buffer
│   ├── DMA.swift                  8-channel general DMA + HDMA
│   ├── Cartridge.swift            LoROM header parsing, address translation
│   ├── Joypad.swift               Thread-safe keyboard→button mapping, strobe/auto-read
│   ├── DebugServer.swift          HTTP debug endpoints for CPU/SPC/DSP inspection
│   ├── SaveState.swift            Full emulator save/load state serialization
│   └── Timing.swift               Clock constants, mach_absolute_time helpers
├── Renderer/
│   ├── MetalRenderer.swift        MTLDevice, thread-safe texture upload, fullscreen quad
│   ├── EmulatorView.swift         KeyCaptureMTKView, NSViewRepresentable
│   └── Shaders.metal              Vertex + fragment (nearest-neighbor sampler)
├── Debug/
│   ├── DebugState.swift           ObservableObject for register/memory snapshots
│   ├── RegisterView.swift         CPU register display
│   ├── DisassemblerView.swift     Instruction disassembly around PC
│   └── MemoryViewer.swift         Hex dump
├── Tests/
│   ├── CPUTestRunner.swift        Headless test ROM runner
│   └── PPUDiagnostic.swift        Unit tests for PPU rendering
├── Support/
│   ├── Constants.swift            Clock, screen, memory size constants
│   └── Types.swift                Address/Byte/Word type aliases
└── MetalSNES-Bridging-Header.h    C→Swift bridge
```

---

## Main Loop

```
User clicks "Run"
  │
  ▼
EmulatorViewModel.toggleEmulation()
  │  creates Thread("EmulatorCore")
  │  (on pause: saves SRAM to .srm file)
  ▼
EmulatorCore.run()                          ← infinite loop
  │
  ├─ runOneFrame()                          ← 262 scanlines
  │   │
  │   ├─ for scanline in 0..<262:
  │   │     runScanline(scanline)
  │   │
  │   ├─ ppu.swapBuffers()                  ← front↔back
  │   └─ renderer.uploadFramebuffer(ptr)    ← RGBA8 → MTLTexture (NSLock protected)
  │
  ├─ frameCount++
  ├─ (debug logging gated behind EmulatorCore.debugLogging)
  ├─ drift-free frame pacing (interval-advancing, spiral protection)
  └─ updateDebugState() every 10 frames (snapshot on emu thread, dispatch to main)
```

---

## Scanline Execution

```
runScanline(y):
  │
  ├─ if y == 0:
  │     ├─ bus.exitVBlank()
  │     │     └─ clears inVBlank, hvbjoy bits
  │     └─ if hdmaen != 0: dma.initHDMA()
  │           └─ read first line-counter byte per enabled channel
  │
  ├─ reset irqFiredThisScanline = false
  │
  ├─ if y == vBlankStart+3: clear auto-joypad bit
  │
  ├─ CPU loop (≈227 cycles):
  │   │
  │   │  while cyclesRemaining > 0:
  │   │    cycles = cpu.step()
  │   │    cyclesRemaining -= cycles
  │   │
  │   └─ cpu.step():
  │       ├─ forward bus.nmiPending → regs.nmiPending
  │       └─ cpu_step(&regs, readCb, writeCb, ctx)   [C code]
  │           ├─ check NMI pending → vector $FFEA/$FFFA
  │           ├─ check IRQ pending (if I clear) → vector $FFEE/$FFFE
  │           ├─ fetch opcode at PBR:PC
  │           └─ dispatch_table[opcode](regs, read, write, ctx)
  │
  ├─ checkTimerIRQ(scanline):
  │     ├─ NMITIMEN bits 4-5 → irqMode (0=off, 1=H, 2=V, 3=HV)
  │     ├─ H-IRQ: fires once per scanline (simplified)
  │     ├─ V-IRQ: fires when scanline == VTIME
  │     ├─ HV-IRQ: fires when scanline == VTIME (H simplified)
  │     └─ sets bus.timeup = 0x80, cpu.regs.irqPending = true
  │
  ├─ if y < 224:
  │     ├─ ppu.renderScanline(y)
  │     └─ if hdmaen != 0: dma.doHDMA()
  │           └─ per-channel: read data from table → write to B-bus register
  │
  └─ if y == 225: bus.enterVBlank()
        ├─ set inVBlank, hvbjoy, rdnmi
        ├─ if NMI enabled: nmiPending = true
        └─ if auto-joypad enabled: joypad.autoRead()
```

---

## CPU ↔ Bus ↔ Subsystems

```
cpu_step() calls read/write via C function pointers
  │
  ▼
Bus.read(fullAddress) / Bus.write(fullAddress, value)
  │
  ├─ Split into bank + offset
  ▼
  readBankOffset / writeBankOffset:
  │
  ├─ Bank $00-$3F, $80-$BF → readSystemBank/writeSystemBank:
  │   ├─ $0000-$1FFF  →  WRAM mirror (first 8KB)
  │   ├─ $2100-$213F  →  PPU registers (ppu.read/write)
  │   │                   includes MPY result ($2134-$2136)
  │   ├─ $2140-$217F  →  APU I/O ports (mirrored /4)
  │   ├─ $2180-$2183  →  WRAM indirect access
  │   ├─ $4016-$4017  →  Joypad strobe/read
  │   ├─ $4200-$42FF  →  CPU I/O (NMI, timers, multiply/divide)
  │   │                   $4210: RDNMI (clears on read)
  │   │                   $4211: TIMEUP (IRQ flag, clears on read)
  │   ├─ $4300-$43FF  →  DMA channel registers
  │   └─ $8000-$FFFF  →  Cartridge ROM
  │
  ├─ Bank $40-$6F, $C0-$FF → Cartridge ROM
  ├─ Bank $70-$7D → SRAM (persisted to .srm file)
  ├─ Bank $7E → WRAM first 64KB
  └─ Bank $7F → WRAM second 64KB
```

---

## DMA Flow

### General DMA
```
CPU writes $420B (mdmaen):
  │
  ▼
Bus.writeSystemBank → dma.executeGeneralDMA(mask, bus)
  │
  ├─ for each enabled channel (bit set in mask):
  │   ├─ read control, dest, src, size
  │   ├─ select transfer mode offsets (modes 0-7)
  │   └─ transfer loop:
  │       while remaining > 0:
  │         for each offset in mode pattern:
  │           A→B: bus.read(aBank:aAddr) → bus.write(0x2100+dest+off)
  │           B→A: bus.read(0x2100+dest+off) → bus.write(aBank:aAddr)
  │           adjust aAddr (increment/decrement/fixed)
  │           remaining--
  └─ update channel srcAddr, zero size
```

### HDMA (per-scanline)
```
Frame start (scanline 0):
  dma.initHDMA(channels, bus)
  │
  ├─ for each enabled channel:
  │   ├─ set hdmaTableAddr from srcBank:srcAddr
  │   ├─ read first line-counter byte
  │   └─ counter == 0 → deactivate; else activate
  │
Each visible scanline (0-223):
  dma.doHDMA(channels, bus)
  │
  ├─ for each active channel:
  │   ├─ if doTransfer: read N data bytes → write to B-bus (using mode offsets)
  │   ├─ decrement line counter (bits 0-6)
  │   ├─ if counter == 0: read next entry's counter (0 = terminate)
  │   └─ if repeat flag (bit 7): transfer every scanline; else only on reload
```

---

## PPU Rendering Pipeline

```
ppu.renderScanline(y):
  │
  ├─ y == 0: buildSpriteScanlineCache()
  │   └─ for each of 128 OAM entries (reverse order):
  │       for each visible scanline: append to cache (max 32/line)
  │
  ├─ forced blank check (inidisp bit 7)
  │
  ├─ fill scanline with backdrop (CGRAM[0])
  │
  ├─ Priority-ordered rendering (back to front, painter's algorithm):
  │
  │   Mode 0 (4×2bpp BGs):
  │     BG4p0 → BG3p0 → OBJp0 → BG4p1 → BG3p1 → OBJp1 →
  │     BG2p0 → BG1p0 → OBJp2 → BG2p1 → BG1p1 → OBJp3
  │
  │   Mode 1 (2×4bpp + 1×2bpp):
  │     BG3p0 → OBJp0 → BG3p1* → OBJp1 → BG2p0 → BG1p0 →
  │     OBJp2 → BG2p1 → BG1p1 → OBJp3 → (BG3p1 at top if BGMODE bit 3)
  │
  │   Modes 2-6 (simplified):
  │     BG1p0 → BG2p0 → OBJp0 → OBJp1 → BG1p1 → BG2p1 → OBJp2 → OBJp3
  │
  │   Mode 7: renderMode7() stub + all sprites
  │
  │   BG render functions accept tilePriority filter (0 or 1):
  │   ├─ extract bit 13 from tilemap entry → skip non-matching tiles
  │   └─ supports both 8x8 and 16x16 tile sizes (2bpp and 4bpp)
  │
  │   Sprite render accepts spritePriority filter (0-3):
  │   └─ extract bits 4-5 from OAM attr → skip non-matching sprites
  │
  │   Per-BG rendering (tile-first loop):
  │   ├─ compute tilemap base, chr base (nibble << 13), scroll offsets
  │   ├─ for each 8px tile column across 256px:
  │   │   ├─ compute tile coords (with 16x16 sub-tile if needed)
  │   │   ├─ read tilemap entry (tile#, palette, priority, flip bits)
  │   │   ├─ read chr bitplane bytes (2 or 4)
  │   │   └─ for each pixel in tile slice:
  │   │       └─ extract color index → CGRAM lookup → write backBuffer
  │   └─ skip transparent pixels (index 0)
  │
  └─ sprite rendering:
      for each sprite in scanline cache matching priority filter:
        ├─ read OAM attrs (x, y, tile, palette, priority, flip, name table)
        ├─ for each 8px tile column in sprite width:
        │   ├─ compute chr address (nameBase << 14, nameGap << 13)
        │   ├─ read 4 bitplane bytes
        │   └─ for each pixel: extract → CGRAM[128+pal*16+idx] → write
        └─ clip to screen bounds
```

---

## Rendering to Screen (Metal)

```
ppu.swapBuffers()
  └─ swap(frontBuffer, backBuffer)

renderer.uploadFramebuffer(ptr)           [emulator thread]
  ├─ textureLock.lock()
  ├─ texture.replace(region, withBytes: ptr, bytesPerRow: 1024)
  └─ textureLock.unlock()

MTKView draw callback (60 Hz):            [main thread]
  │
  ▼
MetalRenderer.draw(in:)
  ├─ commandBuffer = queue.makeCommandBuffer()
  ├─ encoder.setRenderPipelineState(pso)
  ├─ textureLock.lock()
  ├─ encoder.setFragmentTexture(texture, 0)
  ├─ textureLock.unlock()
  ├─ encoder.drawPrimitives(.triangleStrip, 4 vertices)
  ├─ encoder.endEncoding()
  └─ commandBuffer.present(drawable) + commit()

Shaders.metal:
  vertex:   4 hardcoded positions → fullscreen quad
  fragment: nearest-neighbor sample from RGBA8 texture
```

---

## Input Flow

```
macOS keyboard event
  │
  ▼
KeyCaptureMTKView.keyDown/keyUp (EmulatorView.swift)     [main thread]
  │
  ▼
joypad.keyDown(keyCode) / keyUp(keyCode)
  └─ keyMap lookup → OSAllocatedUnfairLock { joy1State |= bit / &= ~bit }

Manual read path ($4016):                                 [emu thread]
  CPU writes strobe → joypad.writeStrobe()
    └─ on falling edge: joy1Shift = lock { joy1State }
  CPU reads $4016 → joypad.readJoy1() → shift register bit

Auto-read path (VBlank):                                  [emu thread]
  bus.enterVBlank() → joypad.autoRead()
    └─ joy1Auto = lock { joy1State }
  CPU reads $4218/$4219 → joy1Auto (full 16-bit state)
```

---

## SRAM Persistence Flow

```
ROM load:
  EmulatorViewModel.loadROM(url)
    ├─ cartridge.romURL = url
    ├─ bus.loadSRAM(from: url.srm)    ← load existing save
    └─ register NSApplication.willTerminateNotification → saveSRAM()

Pause:
  EmulatorViewModel.toggleEmulation() [stopping]
    └─ bus.saveSRAM(to: url.srm)      ← atomic write

App quit:
  willTerminateNotification
    └─ bus.saveSRAM(to: url.srm)
```

---

## Object Ownership

```
EmulatorViewModel (SwiftUI @StateObject)
  ├── .emulatorCore: EmulatorCore
  │     ├── .bus: Bus (owns all subsystems)
  │     │     ├── .ppu: PPU
  │     │     ├── .apu: APU
  │     │     ├── .dma: DMA (general + HDMA state)
  │     │     ├── .joypad: Joypad (OSAllocatedUnfairLock on joy1State)
  │     │     ├── .cartridge: Cartridge (+ romURL)
  │     │     ├── .wram: UnsafeMutableBufferPointer (128KB)
  │     │     └── .sram: UnsafeMutableBufferPointer (up to 32KB, persisted)
  │     ├── .cpu: CPU (weak ref to Bus, C dispatch via Unmanaged<Bus>)
  │     └── .renderer: MetalRenderer? (set externally)
  ├── .renderer: MetalRenderer? (NSLock on texture)
  ├── .romURL: URL? (for SRAM path derivation)
  ├── .terminationObserver (saves SRAM on quit)
  └── .debugState: DebugState (ObservableObject for UI)
```

---

## Threading Model

```
Main thread:
  - SwiftUI UI updates
  - MTKView draw callbacks (Metal rendering, textureLock)
  - Keyboard events → Joypad (OSAllocatedUnfairLock)

Emulator thread ("EmulatorCore"):
  - EmulatorCore.run() loop
  - CPU execution, PPU scanline rendering, HDMA
  - Bus read/write, general DMA transfers
  - H/V timer IRQ checking
  - ppu.swapBuffers() + renderer.uploadFramebuffer() (textureLock)
  - Reads joypad.joy1State via OSAllocatedUnfairLock (thread-safe)

Synchronization:
  - EmulatorCore.isRunning: OSAllocatedUnfairLock
  - Joypad.joy1State: OSAllocatedUnfairLock
  - MetalRenderer.texture: NSLock
  - DebugState: snapshots on emu thread, dispatched to main queue

Debug logging:
  - Gated behind EmulatorCore.debugLogging (default: false)
  - Covers: CPU trace, DMA log, sprite dump, VRAM/WRAM comparison
```

---

## APU Boot + Runtime Flow

```
Boot sequence:
  1. APU returns $AA on port 0, $BB on port 1 (waitingForCC)
  2. CPU writes $CC to port 0 and uploads the SPC program through the boot ROM protocol
  3. SPC700 writes `$F1` with bit 7 clear, disabling the IPL ROM
  4. Game audio code executes on the SPC700, with DSP register access via `$F2/$F3`
  5. CPU/SPC communication continues over `$2140-$2143` ↔ `$F4-$F7`
  6. DSP samples are generated while SPC cycles run and are pushed to `AudioOutput`
```
