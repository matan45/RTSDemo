# VertexForge engine API usage (for review)

The API contract is the set of `.mt` modules in `C:\matan\RTSDemo\scripts\lib\engine\` (~150
files). Ground-truth behavior of each native lives in the C++ bindings at
`C:\matan\VertexForge\VFEngine\core\adapters\api\*.cpp` (e.g. `EntityAPI.cpp`, `UIApi.cpp`,
`InputAPI.cpp`, `CameraAPI.cpp`, `PhysicsAPI.cpp`). When a signature or return value is in doubt,
read the `.mt` file first, the `.cpp` binding second.

## Key modules cheat-sheet

All API classes are **static** — call with `::`. Entity handles are `int`; **`-1` means "none"**.

- **Entity** — `self(): int`, `findByName(string): int` (**-1 if not found**), `findAll(string): int[]`,
  `findWithComponent(string): int[]`, `isValid(int): bool`, `instantiate(string prefab): int`
  (**-1 on failure**), `instantiateChild`, `create`/`destroy`, `getScript<T>(int, "ClassName"): T`,
  `hasScriptOfType`, `getPosition/setPosition/getRotation/setRotation/getScale/setScale(int, Vec3f)`,
  `getParent/setParent/getChildren`, `setMesh/setMaterial`, `sendMessage`/`broadcastMessage`.
- **Input** (real-time polling) — `isKeyDown/isKeyReleased(int)`, `isMouseButtonDown/Released(int)`,
  `isDoubleClick(int)`, `getMouseX/Y`, `getViewportMouseX/Y`, `getMouseDeltaX/Y`,
  `getMouseScrollDeltaX/Y`, `setCursorVisible`.
- **InputAction / InputAxis** (named bindings, authored in the editor) —
  `InputAction::isDown/isPressed/isReleased(string)`, `InputAxis::getValue2DX/getValue2DY(string)`.
- **Camera** — `get/setPosition(int, Vec3f)`, `get/setRotation` (Euler degrees), `get/setFOV`,
  `getViewMatrix/getProjectionMatrix`, `getPrimary(): int` (**-1 if none**).
- **UI** — large surface (see `scripts/lib/engine/UI.mt`). Common: `get/setLabelText(int, string)`,
  `setLabelColor`, `setLabelRichText`, `isButtonHovered/Pressed`, `getButtonState(int): int`,
  `setButtonInteractable`, `get/setSliderValue`, `get/setProgressBarValue`, `isPointerOverUI(): bool`,
  `setListItemCount`, `getListItem(int,int): int` (**-1 on miss**), `openWindow/closeWindow`,
  `setRectPixels`. All take a widget entity id first.
- **Terrain** — `heightAt(float x, float z): float` (returns 0.0 off-terrain), `hasHeightAt(...)`.
- **Picker** — world raycasts from screen coords (`pickEntity(...) : RaycastHit`, `.hit`, `.entityId`).
- **Log** — `Log::info/warn/error(string)`.

## Listener interfaces & scope

Listener interfaces (`I*Listener` in `scripts/lib/engine/`) are implemented by `@Script` classes and
**invoked by the engine** (not polled). The critical distinction is *who receives the callback*:

| Listener | Scope | Review rule |
|----------|-------|-------------|
| `IUIButtonListener`, `IUICheckboxListener`, `IUISliderListener`, `IUIDropdownListener`, `IUIListViewListener`, `IUITabsListener`, `IUITextInputListener`, `IUIWindowListener`, `IUIProgressBarListener`, `IUIDragDropListener` | **Broadcast** — fires on **every** implementing script in the scene | Handler MUST filter by `buttonEntityId`/`entityName` before acting, else it fires on unrelated widgets |
| `ICollisionListener`, `ITriggerListener`, `IAnimationEventListener`, `INavigationEventListener`, `ISocketAttachmentListener`, `IRagdollListener`, `IDestructionListener`, `IWaterListener`, `IVFXEventListener` | **Single-entity** — fires only for the entity this script is attached to | No scene-wide filtering needed |
| `ISceneEventListener`, `ISceneLoadCallback` | **Global** — scene lifecycle | Expect to fire scene-wide |

Any interface you `implements` must have **all** its methods defined (mType: missing → MT-E4001),
each marked `@Override`.

## Correct-vs-misuse patterns

1. **Unguarded `findByName`** — every lookup returns `-1` when missing; guard before use.
   ```
   int id = Entity::findByName("Terrain");
   if (id < 0) { Log::warn("[Ctrl] Terrain not found"); return; }   // ✅
   float y = Terrain::heightAt(id, x, z);
   ```
   ❌ using the raw return without a `< 0` check. (Real example of the good pattern:
   `scripts/game/controllers/RTSCameraController.mt:56`.)
2. **Unguarded `instantiate`** — `int b = Entity::instantiate(prefab); if (b < 0) { Log::error(...); return; }`.
3. **Unguarded `getScript`** — result is nullable; check before calling: `if (hud == null) { return; }`.
4. **Incomplete listener impl** — implementing `IUIButtonListener` but omitting
   `onButtonPressed/Released/HoverEnter/HoverExit`. ❌ Blocker.
5. **Unfiltered broadcast handler** — `onButtonClicked` acting on any click:
   ```
   public function onButtonClicked(int id, string name): void {
       if (id != this.playButtonId) { return; }   // ✅ filter first
       ...
   }
   ```
6. **Per-frame entity lookup** — `Entity::findByName(...)` / `findAll(...)` inside `onUpdate`. ❌
   Cache in `onStart` (or lazily). Warning (perf).
7. **Allocation in a hot loop** — `new X(...)` inside a per-frame loop over many items. Warning.
8. **`isKeyDown` for one-shot actions** — fires every held frame; use `InputEdge` /
   `InputAction::isPressed` for press/release edges (see rts-conventions). 
9. **Unguarded UI call** — `UI::setLabelText(id, ...)` without `if (id >= 0)`. (Good pattern:
   `scripts/game/controllers/RTSHUDController.mt`.)
10. **`== -1` / `!= -1`** instead of `< 0` / `>= 0` — works but less robust; flag as Nit.

## Authoritative references

- API contract: `C:\matan\RTSDemo\scripts\lib\engine\*.mt`.
- Native ground truth: `C:\matan\VertexForge\VFEngine\core\adapters\api\*.cpp`.
- Engine architecture / UI runtime: `C:\matan\VertexForge\docs\ENGINE_ARCHITECTURE.md`,
  `C:\matan\VertexForge\docs\UI_RUNTIME.md`.
