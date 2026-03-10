# MetalSNES — Issues, Stubs & Bugs

## Resolved Issues

The following were identified and fixed:

- **BG chr base addressing** — rechecked: BG bases use `<< 13`, sprite name bases use `<< 14`
- **Joypad data race** — `joy1State` now protected by `OSAllocatedUnfairLock`
- **OAM high table write mask** — fixed to `0x200 + (addr & 0x1F)`
- **Sprite priority** — sprites now interleave with BGs via priority filter (0-3)
- **BG tile priority bit** — tilemap bit 13 extracted, used for priority-filtered rendering
- **16x16 tiles in 2bpp** — `renderBG2bpp` now supports 16x16 tiles (matching `renderBG4bpp`)
- **Frame pacing drift** — now uses interval-advancing with spiral protection
- **MPY multiplication registers** — $2134-$2136 return signed M7A * M7B result
- **SRAM persistence** — .srm file saved on pause/quit, loaded on ROM open
- **H/V timer IRQ** — V-IRQ, H-IRQ, HV-IRQ modes implemented
- **HDMA** — direct mode implemented, all 8 transfer modes, per-scanline execution
- **Debug logging cleanup** — gated behind `EmulatorCore.debugLogging` flag
- **Renderer thread safety** — `NSLock` around texture access
- **Unused import** — `import simd` removed from PPU.swift

---

## Remaining Issues

### 1. APU/DSP accuracy gaps still affect game compatibility
**Files:** `APU.swift`, `SPC700.swift`, `DSP.swift`
**Severity:** High

The emulator now has a real SPC700, DSP, and audio output path, and recent fixes removed several hard failures (`POP` flags, `SLEEP/STOP` idle semantics, half-rate SPC scheduling). Audio is still not cycle-accurate, so tempo, envelopes, pitch modulation, and game-specific behavior still need hardware-accuracy validation.

### 2. Modes 2/4/5/6 are still simplified
**File:** `PPU.swift`
**Severity:** Medium

Modes 2/4/5/6 are not yet modeled with their real per-mode behavior. Offset-per-tile, hi-res details, and mode-specific differences are still incomplete.

### 3. Window clipping is stored but not applied
**File:** `PPU.swift`
**Severity:** Medium

Window registers (`W12SEL`, `W34SEL`, `WOBJSEL`, `WH0-WH3`, `WBGLOG`, `WOBJLOG`, `TMW`, `TSW`) are tracked, but the masking rules are not used during rendering.

### 4. Color math is present but still not hardware-accurate
**File:** `PPU.swift`
**Severity:** Medium

`CGWSEL`, `CGADSUB`, `COLDATA`, and the sub-screen path are implemented, but window-gated color math and exact per-layer/subscreen rules still need a hardware-accuracy pass.

### 5. Mosaic is not applied
**File:** `PPU.swift`
**Severity:** Low

The MOSAIC register is stored, but the blocky pixel expansion effect is not currently rendered.

### 6. CGRAM read behavior could still use a hardware-accuracy pass
**File:** `PPU.swift`
**Severity:** Low

The normal read path works, but odd-address edge cases and exact latch behavior have not been fully validated against hardware.
