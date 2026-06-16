# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

RTSDemo is a real-time-strategy skirmish game built on the **VertexForge** engine (v1.0.0). The engine itself is not in this repo — this is a *project* consumed by the VertexForge editor/runtime. All gameplay logic is written in **mType** (`.mt`), the engine's scripting language. There is no C++ here.

Project entry points are declared in `RTSDemo.vfproj`:
- `startupScene`: `scenes/Skirmish_01.vfScene` (the playable skirmish; `scenes/main.vfScene` is a near-empty stub)
- `inputMapping`: `assets/input/camera.vfInputMapping`

`docs/GAME_DESIGN_DOCUMENT.md` is the design bible and `docs/MVP_MILESTONE_CHECKLIST.md` tracks implementation against Milestone 1 ("RTS Skirmish Complete"). Read these to understand intended behavior before adding gameplay features — a checklist item is only "done" when it works in a playable build, not when a script merely exists.

## Building / running

The game is built and run **from the VertexForge editor**, not a repo-local CLI. There is no `npm`/`make`/`cmake` here.

- **Scripts** (`scripts/scripts.mtproj`): compiles `game/**/*.mt` to `scripts/compiled/scripts.mtcLib`, with `lib/` on the import search path. Compilation is driven by the editor's mType toolchain. `compiled/` and `*.mtcLib` are gitignored.
- **Debugging mType**: `.vscode/launch.json` defines an `mtype` launch config (debug current file, `stopOnEntry`) and an attach config (`localhost:5005`) for attaching to a running engine. This requires the VertexForge / mType VS Code extension.
- **Assets**: every asset and script has a sibling `.vfmeta` (gitignored) and is indexed in `assetdb.json` by a 64-bit hex id. `assetdb.json` is committed and maps ids → file paths/types; treat it as editor-managed — don't hand-edit unless you know the id scheme. Source art lives under `backup/` and is imported into engine formats (`.vfImage`, `.vfMatInstance`, etc.) under `assets/`.

To verify a change actually works you must run it in the engine; there is no headless test runner wired up in this project (`scripts/lib/mtest` exists as a library but no game tests are present).

## mType scripting model

This is the core architecture. Gameplay is a set of **controllers** — classes annotated `@Script` — attached to scene entities. Understanding how they find and talk to each other is the key to being productive.

- **Lifecycle**: a `@Script` class implements `onStart()`, `onUpdate(float deltaTime)`, `onDestroy()`. Get the owning entity with `Entity::self()`.
- **Engine API**: imported per-file from `scripts/lib/engine/*.mt` (~150 modules: `Entity`, `Camera`, `Input`/`InputAction`/`InputAxis`, `UI`, `Terrain`, `Log`, `RenderTexture`, the `I*Listener` interfaces, etc.). Import with `import * from "../../lib/engine/Camera.mt";`. The `scripts/lib/core` tree is the mType standard library (collections, json, reflect, stream, primitives).
- **Entity lookup**: controllers find peers and widgets by name via `Entity::findByName("Terrain")`. Returns `-1` when not found — code guards on `< 0`. Names are defined in the scene and are an implicit contract (e.g. `"GameSystems"`, `"camera"`, `"Terrain"`, `"RTS_HUD_*"` widgets).
- **Cross-controller calls**: get another controller instance with the generic `Entity::getScript<SelectionController>(ownerId, "SelectionController")`, then call its public methods directly. Most gameplay controllers (`SelectionController`, `BuildingPlacementController`, `BuildingCommandController`, `MinimapController`, etc.) are attached to a single `GameSystems` entity; the HUD and minimap look them up there. `RTSCameraController` lives on the `camera` entity.
- **UI**: HUD controllers implement listener interfaces (e.g. `IUIButtonListener`), look up widget entities by name in `onStart`, and push state into UI components each frame.

### Layout under `scripts/game/`
- `controllers/` — the `@Script` classes (camera, selection, building placement/command, HUD, minimap). This is where behavior lives.
- `data/` — plain data/model classes (`GameState`, `BuildingDef`, `UnitDef`, `PlacedBuilding`, `QueueItem`, `Harvester`, `BuildingInfo`).
- `util/` — shared helpers and small value types (`Config`, `Util`, `DragState`, `HState`, `InputEdge`, `RTSFog`).

`scripts/game/util/Config.mt` holds the genuinely cross-file constants: `DEG_TO_RAD`, the playable map bounds (`MAP_MIN_X/MAX_X/MIN_Z/MAX_Z` = ±256, used by camera, minimap, and placement clamping), and `TEAM_PLAYER = 0`. Single-controller tuning knobs stay as named fields on their own controller — only promote a constant to `Config` when it is actually duplicated across files.

## Conventions observed in this codebase

- Files open with a comment block explaining purpose, often referencing a `VK-####` work-item id (e.g. `VK-1324`). Keep that style and reference ids when relevant.
- Input is consumed by action/axis *name* only (`InputAction::isDown("RotateCamera")`, `InputAxis::getValue2DX("CameraPan")`); the bindings themselves are authored in the editor's Input Mapping window and persisted to `.vfInputMapping` — scripts never register bindings.
- Stub-then-replace pattern: data sources like `GameState` expose a stable public API backed by placeholder values, so real systems can replace internals without touching callers. Preserve the public API when filling in a stub.
- Comments frequently capture *why* a non-obvious formula or guard exists (e.g. the camera yaw rotation note). Match that density — explain the reasoning, not the mechanics.
