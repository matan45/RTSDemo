# RTSDemo project conventions (for review)

Review-oriented distillation of the patterns in `C:\matan\RTSDemo\CLAUDE.md` and the existing
controllers. These are the project-specific checks; mType-language and engine-API checks live in
the sibling reference files.

## Directory roles (`scripts/game/`)

- `controllers/` — the `@Script` classes; this is where behavior lives (camera, selection,
  building placement/command, HUD, minimap).
- `data/` — plain data/model classes (`GameState`, `BuildingDef`, `UnitDef`, `PlacedBuilding`,
  `QueueItem`, `Harvester`, `BuildingInfo`). No engine-driving logic.
- `util/` — shared helpers / small value types (`Config`, `Util`, `DragState`, `HState`,
  `InputEdge`, `RTSFog`).

A check that's "in the wrong layer" (e.g. engine calls in a `data/` model, or behavior in `util/`)
is worth flagging.

## @Script lifecycle

- Class is annotated `@Script` and implements `onStart()`, `onUpdate(float deltaTime)`,
  `onDestroy()`. Get the owning entity via `Entity::self()`.
- **All fields initialized in the constructor** (or at declaration) — no null surprises. Entity-id
  fields default to `-1`.
- **`onStart` caches lookups**; `onUpdate` uses the cached values. The `deltaTime` parameter is
  present and used for time-dependent motion (not ignored).

## Entity handles

- Entity ids are `int` with **`-1` = "no entity"**. Initialize id fields to `-1`.
- Check with `>= 0` / `< 0` (preferred over `== -1` / `!= -1`).

## Cross-controller access

Most gameplay controllers are attached to a single `GameSystems` entity; the HUD/minimap look them
up there. Two distinct patterns, and the distinction matters:

- **`Entity::findByName(...)`** is safe in `onStart` — named entities exist at scene load.
- **`Entity::getScript<T>(id, "ClassName")`** is resolved **lazily** via a cached nullable helper,
  because script init order across controllers is **not guaranteed**:
  ```
  private RTSHUDController? hudRef = null;
  private function hud(): RTSHUDController? {
      if (this.hudRef == null && this.hudControllerId >= 0) {
          this.hudRef = Entity::getScript<RTSHUDController>(this.hudControllerId, "RTSHUDController");
      }
      return this.hudRef;
  }
  ```
  Callers then null-check: `RTSHUDController? hud = this.hud(); if (hud == null) { return; }`.
  The `"ClassName"` string must exactly match the class. (Pattern lives in
  `scripts/game/controllers/BuildingPlacementController.mt`.)

## Imports

- Always `import * from "..."` with relative paths. Grouped: engine libs
  (`../../lib/engine/...`, `../../lib/math/...`) first, then local game scripts (`./...`,
  `../controllers/...`), then util (`../util/...`). (Example header:
  `scripts/game/controllers/RTSCameraController.mt:17`.)

## Input

- Buttons/keys use the **`InputEdge`** helper to detect transitions. `InputEdge.step(now)` is called
  **exactly once per frame** with the current state; code reads `.wasPressed` / `.wasReleased`
  (never the result of `step()`). A `step()` placed inside a conditional (so it's skipped some
  frames) breaks edge detection — flag it.
- Input is consumed by **action/axis name only** (`InputAction::isDown("RotateCamera")`,
  `InputAxis::getValue2DX("CameraPan")`). Scripts **never register bindings** — those are authored
  in the editor's Input Mapping window. A script calling `InputAction::register(...)` is a smell.

## Config & tuning

- `util/Config.mt` holds only **genuinely cross-file** constants: `DEG_TO_RAD`, the map bounds
  `MAP_MIN_X/MAX_X/MIN_Z/MAX_Z` (±256, used by camera, minimap, placement clamping), `TEAM_PLAYER = 0`.
- A single-controller tuning knob belongs as a **named field on that controller**, not in `Config`.
  Conversely, a magic number duplicated across files should be promoted to `Config`. Bare magic
  numbers in logic (`if (gold > 50)`) are worth a Nit.

## Style

- **VK-#### header** — files open with a comment block stating purpose, usually citing a
  `VK-####` work-item id. Check presence and that the description still matches the code.
- **Comments explain *why*** (non-obvious formulas, guards, engine quirks), not the mechanics.
  Obvious restating-the-code comments are a Nit; missing rationale on a tricky formula is a Warning.
- **Stub-then-replace** — data sources (e.g. `GameState`) expose a stable public API over
  placeholder internals. When filling a stub, the **public signature must be preserved** so callers
  don't break.

## Quick anti-pattern list (lint targets)

- `Entity::findByName` / `instantiate` / `getScript` result used without a `< 0` / `null` guard.
- Entity lookup or `new` allocation inside `onUpdate` that should be cached / hoisted.
- `getScript<T>` resolved eagerly in `onStart` instead of lazily (init-order fragility).
- `InputEdge.step()` skipped on some frames; or `isKeyDown` used for a one-shot action.
- `InputAction::register(...)` in a script (bindings belong in the editor).
- Number/bool concatenated to a string without `parsePrimitive(...)`.
- New cross-file constant left as a magic number, or a single-use knob dumped into `Config`.
- Missing/stale `VK-####` header; comments that restate the code; broken stub public API.
