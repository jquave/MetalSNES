# Phase 2 Plan: CPU-Authoritative PPU State, Metal Composition

## Goal

Move the project toward a simpler split:

- CPU/PPU is the single source of truth for tricky SNES rendering rules.
- Metal remains the default live renderer and post-process/presentation path.
- The GPU should consume canonical intermediate state instead of re-deriving as many SNES rules as it does today.

This is the "option 2" architecture:

- not a full rollback to CPU-only rendering
- not a full GPU-only PPU
- a hybrid where the CPU owns correctness-critical decisions and Metal owns most pixel fill and presentation

## Why This Exists

Today both the CPU path and the Metal path independently implement too much PPU policy:

- sprite arbitration
- BG mode-specific priority behavior
- window masking decisions
- color math eligibility
- some mode-specific sampling rules

That duplication makes debugging harder because correctness bugs can live in two places. The Zelda throne-room issue was a concrete example: the bad rule existed in shared CPU and Metal composition logic.

## Non-Goals

- Do not remove the CPU renderer as a reference/debug path.
- Do not attempt a full bsnes-style cycle-accurate GPU PPU.
- Do not regress live gameplay performance back to CPU-only presentation.
- Do not rewrite every rendering path at once.

## Design Principles

1. One source of truth for hard rules.
2. Metal should consume explicit state, not infer as much hardware behavior.
3. Refactor incrementally with CPU-vs-GPU parity checks after every step.
4. Keep the current CPU renderer alive as the oracle until the new split is proven.

## Target End State

### CPU-owned decisions

- sprite visibility and sprite-vs-sprite arbitration
- per-mode priority table selection
- window-mask decisions or window-mask inputs simplified enough that Metal does not duplicate the rule engine
- color-math enable/disable decisions
- any special-case raster/state behavior that is easier to express on CPU than in Metal

### Metal-owned work

- BG texel sampling from VRAM using already-authoritative per-line/per-span state
- final per-pixel composition from CPU-produced intermediate buffers
- palette lookup where safe
- display scaling, filtering, CRT/phosphor effects, presentation

## Proposed Intermediate Data Model

The current `GPULineState` is the right direction, but it is not authoritative enough yet. Phase 2 should add explicit resolved buffers.

### New canonical GPU inputs to add

1. `ResolvedSpriteLine`
- one entry per visible pixel or packed span data per scanline
- contains the winning OBJ sample after OAM-order arbitration
- minimum fields:
  - `colorIndex`
  - `z`
  - `layer`
  - optional: `opaque` flag instead of colorIndex `0`

2. `ResolvedWindowMask`
- per-scanline packed masks or spans for:
  - main screen layer visibility
  - sub screen layer visibility
  - color window gating
- goal: Metal should evaluate simple mask bits/spans, not reimplement the window rule matrix

3. `ResolvedPriorityPlan`
- one compact authoritative encoding of mode-specific BG/OBJ z-order tables for the frame or scanline
- the shader should use provided z values, not rebuild mode tables ad hoc

4. `ResolvedColorMathPlan`
- explicit per-scanline decisions for:
  - whether color math applies
  - whether it blends with subscreen or fixed color
  - half-color conditions

### Nice-to-have later

5. `ResolvedBGSpan` or `ResolvedTileSpan`
- predecoded per-scanline tile/span descriptors for BGs
- useful if BG logic remains too duplicated after sprites/windows are cleaned up

## Implementation Phases

## Phase 2.0: Guardrails First

Before moving logic, tighten the test/debug loop.

### Deliverables

- keep the existing CPU-vs-GPU framebuffer comparison path working
- add at least a few named save-state parity cases:
  - Zelda throne room
  - Zelda rain intro
  - Mario baseline gameplay
- add a small "trace one pixel" diagnostic path that works for both CPU reference and GPU-composed output

### Exit Criteria

- a code change in shared rendering logic can be checked against reproducible save states in one command

## Phase 2.1: Make Priority Tables Fully Canonical

Today priority mapping still exists in both CPU and Metal code.

### Work

- move mode-specific priority table selection into CPU-owned data
- store the resolved z-order tables in `GPULineState` or a companion buffer
- update Metal to consume those resolved values directly

### Files Likely Touched

- `MetalSNES/Emulator/PPU.swift`
- `MetalSNES/Renderer/Shaders.metal`

### Exit Criteria

- no mode-specific z-table literals remain in Metal

## Phase 2.2: Move Sprite Arbitration to CPU-Owned Buffers

This is the highest-impact simplification step and already partially aligns with the Zelda fix.

### Work

- compute the winning OBJ pixel per X for each visible scanline on CPU
- emit a `ResolvedSpriteLine` buffer for the frame
- keep the CPU reference compositor using the same resolved sprite winners
- simplify the Metal path so it samples only the resolved winning OBJ data instead of re-running:
  - OAM iteration
  - tile selection
  - OAM-order arbitration
  - sprite-vs-sprite conflict handling

### Expected Outcome

- sprite rules become authoritative in one place
- Zelda-style sprite overlap bugs stop being dual-path bugs
- Metal shader gets simpler and cheaper

### Exit Criteria

- Metal no longer iterates OAM to decide sprite winners

## Phase 2.3: Move Window Resolution Out of Metal

Window logic is policy-heavy and easy to drift.

### Work

- compute per-line resolved window masks or spans on CPU
- include separate resolved masks for:
  - main screen
  - sub screen
  - color window
- make Metal consume these masks directly
- remove the rule engine for `W12SEL/W34SEL/WOBJSEL/WBGLOG/WOBJLOG/TMW/TSW` from the shader where possible

### Exit Criteria

- Metal does not independently interpret the SNES window-register matrix

## Phase 2.4: Centralize Color Math Decisions

The shader should not need to independently rediscover when color math is legal.

### Work

- compute explicit per-line/per-pixel color-math eligibility inputs on CPU
- provide:
  - blend source selection
  - half-color conditions
  - fixed-color usage
  - subscreen/backdrop usage flags
- reduce shader logic to straightforward blending with authoritative flags

### Exit Criteria

- color math behavior is driven by resolved CPU-produced state, not register interpretation scattered across both paths

## Phase 2.5: Re-evaluate BG Logic Duplication

After sprites, windows, and color math are centralized, decide whether BG sampling duplication is still too costly.

### Options

1. Keep BG texel fetch in Metal
- likely best for performance
- acceptable if the remaining logic is mostly simple sampling from authoritative line state

2. Move more BG decision-making to CPU
- if debugging still suffers
- possibly via per-scanline tile/span descriptors instead of full CPU-rendered pixels

### Decision Rule

Do not move BG work to CPU unless it meaningfully reduces duplicated policy. Moving raw texel fetch alone is not the goal.

## Phase 2.6: Demote the CPU Renderer from "Runtime Peer" to "Reference Backend"

Once the Metal path consumes authoritative CPU-owned state:

- keep the CPU compositor for diagnostics, test parity, and fallback
- stop treating it as a second place where new behavior should be invented first unless debugging requires it
- document clearly which layer is authoritative for each class of behavior

### Exit Criteria

- normal runtime uses the Metal path
- CPU renderer remains available for:
  - headless tests
  - parity comparison
  - low-risk fallback

## Validation Strategy

Every phase should ship with explicit parity checks.

### Required checks

1. Save-state framebuffer parity
- CPU reference vs Metal-composed output

2. Pixel-targeted diagnostics
- exact known-problem pixels for Zelda/Mario scenes

3. Hot-path smoke tests
- GUI launch for common ROMs
- headless benchmark for regression tracking

4. Fallback safety
- CPU-only path still builds and renders correctly when Metal composition is unavailable

## Risks

### Risk: intermediate buffers become too large

Mitigation:
- start with sprites/windows first
- use packed line buffers or spans instead of naive 32-bit-per-field layouts when needed

### Risk: CPU authoritative work erodes performance

Mitigation:
- keep CPU work focused on rule-heavy arbitration, not full per-pixel final rendering
- benchmark after each phase

### Risk: partial migration leaves the architecture even more confusing

Mitigation:
- require each phase to delete duplicated logic, not just add another layer

## Concrete First Milestone

If this plan is executed, the first implementation milestone should be:

1. make priority tables canonical CPU-owned data
2. emit resolved per-scanline winning OBJ buffers
3. update Metal to consume those buffers
4. keep CPU-vs-GPU parity tooling green on Zelda and Mario save states

That is the smallest slice with the highest debugging payoff.

## Success Criteria

Phase 2 is successful when:

- the hard rendering bugs are debugged against one authoritative rules engine
- Metal remains the default live renderer
- CPU-vs-GPU mismatches become rare and localized
- shaders get materially simpler because they consume resolved state instead of inferring SNES behavior
- future fixes like the Zelda throne-room issue land in one place first, not two
