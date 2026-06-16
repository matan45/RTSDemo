// UnitSelectionController - RTS unit selection (VK-1302).
//
// Left-click selects a single friendly unit; left-drag draws a screen-space
// selection box and selects every friendly unit inside it on release.
// Shift-click adds to (or removes from) the selection; clicking empty ground
// (or pressing ESC) clears it. Each selected unit gets a ground-projected
// ring decal that follows the unit every frame.
//
// Units are entities carrying the plugin components registered by the engine's
// RTSGameplay plugin: "Selectable" (canBeSelected), "Team" (teamId, 0 = player)
// and the runtime-only "Selected" marker this controller mirrors onto the ECS
// so other systems (VK-1303 move command) can query the selection with
// PluginComponent::findAll("Selected").
//
// The drag box visual is a scene-authored UIImage named "RTS_DragBox" under the
// HUD canvas (semi-transparent, blocksRaycast OFF, initially inactive); it is
// repositioned in viewport pixels each drag frame via UI::setRectPixels.
//
// Attach this @Script to the GameSystems entity alongside SelectionController.
// Building click-selection stays in SelectionController; this controller pushes
// setUnitDragActive() so a box-drag release is never also a building click.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Mouse.mt";
import * from "../../lib/engine/Key.mt";
import * from "../../lib/engine/UI.mt";
import * from "../../lib/engine/Picker.mt";
import * from "../../lib/engine/RaycastHit.mt";
import * from "../../lib/engine/ScreenPoint.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Physics.mt";
import * from "../../lib/engine/Decal.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/core/collections/HashMap.mt";
import * from "../../lib/core/primitives/Int.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "./SelectionController.mt";
import * from "./BuildingPlacementController.mt";
import * from "../util/Config.mt";
import * from "../util/Util.mt";
import * from "../util/DragState.mt";
import * from "../util/InputEdge.mt";

@Script
class UnitSelectionController {
    // Drag state machine: 0 = idle, 1 = maybe-drag (button down, under the
    // drag threshold), 2 = dragging (box visible).
    private int state;
    private float dragStartX;
    private float dragStartY;

    // Input edge tracking (Input exposes state, not edges).
    private InputEdge leftEdge;
    private InputEdge escEdge;

    // Selected units: entity id -> ring decal entity id (both boxed as Int).
    // Rings are created on select and destroyed on deselect, so no entities
    // linger in the hierarchy while nothing is selected.
    private HashMap<Int, Int> selectedRings;

    // Scene-authored drag box UIImage ("RTS_DragBox"), -1 if absent.
    private int dragBoxId;

    // setUnitDragActive(false) is deferred one frame after a drag release so
    // SelectionController suppresses the release click in either script order.
    private bool pendingDragClear;

    // Config.
    private float dragThreshold;
    private float ringRadius;
    private float clickPixelRadius;
    private int maxSelected;

    constructor() {
        this.state = DragState::IDLE;
        this.dragStartX = 0.0;
        this.dragStartY = 0.0;
        this.dragBoxId = -1;
        this.pendingDragClear = false;

        this.dragThreshold = 5.0;
        this.ringRadius = 1.6;
        this.clickPixelRadius = 45.0;
        this.maxSelected = 64;
    }

    public function onStart(): void {
        this.leftEdge = new InputEdge();
        this.escEdge = new InputEdge();
        this.selectedRings = new HashMap<Int, Int>();

        this.dragBoxId = Entity::findByName("RTS_DragBox");
        if (this.dragBoxId < 0) {
            Log::warn("[UnitSelection] RTS_DragBox UI entity not found; box-drag has no visual.");
        } else {
            Entity::setActive(this.dragBoxId, false);
        }

        Log::info("[UnitSelection] ready.");
    }

    public function onUpdate(float deltaTime): void {
        // Release the building-click suppression one frame after a drag ended,
        // so SelectionController has seen (and skipped) the release edge first.
        if (this.pendingDragClear && this.state == DragState::IDLE) {
            this.pendingDragClear = false;
            this.pushDragActive(false);
        }

        // ESC clears the selection (edge-detected) and cancels a live drag.
        this.escEdge.step(Input::isKeyDown(Key::ESCAPE));
        if (this.escEdge.wasPressed) {
            if (this.state == DragState::DRAGGING) {
                this.cancelDrag();
            }
            this.clearSelection();
        }

        this.updateDrag();
        this.updateRings();
    }

    public function onDestroy(): void {
    }

    // ---- public API ----

    public function getSelectedCount(): int {
        return this.selectedRings.size();
    }

    public function getSelectedIds(): int[] {
        Int[] keys = this.selectedRings.getKeys();
        int[] ids = new int[keys.length];
        for (int i = 0; i < keys.length; i = i + 1) {
            ids[i] = keys[i].getValue();
        }
        return ids;
    }

    public function isSelected(int id): bool {
        if (id < 0) {
            return false;
        }
        return this.selectedRings.containsKey(new Int(id));
    }

    public function clearSelection(): void {
        Int[] keys = this.selectedRings.getKeys();
        for (int i = 0; i < keys.length; i = i + 1) {
            this.removeUnit(keys[i].getValue());
        }
    }

    // ---- drag state machine ----

    private function updateDrag(): void {
        this.leftEdge.step(Input::isMouseButtonDown(Mouse::LEFT));
        bool leftPressed = this.leftEdge.wasPressed;
        bool leftReleased = this.leftEdge.wasReleased;

        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();
        bool shift = Input::isKeyDown(Key::LEFT_SHIFT) || Input::isKeyDown(Key::RIGHT_SHIFT);

        if (this.state == DragState::IDLE) {
            if (leftPressed && !UI::isPointerOverUI() && !this.placementActive()) {
                this.state = DragState::MAYBE;
                this.dragStartX = mx;
                this.dragStartY = my;
            }
            return;
        }

        if (this.state == DragState::MAYBE) {
            if (leftReleased) {
                this.state = DragState::IDLE;
                this.handleClick(mx, my, shift);
                return;
            }
            float dx = mx - this.dragStartX;
            float dy = my - this.dragStartY;
            if (dx * dx + dy * dy > this.dragThreshold * this.dragThreshold) {
                this.state = DragState::DRAGGING;
                this.pushDragActive(true);
                // Position the box BEFORE activating it, or it renders one
                // frame at its stale previous/authored rect (flash + offset).
                this.updateDragBox(mx, my);
                if (this.dragBoxId >= 0) {
                    Entity::setActive(this.dragBoxId, true);
                }
            }
            return;
        }

        // DRAGGING.
        this.updateDragBox(mx, my);
        if (leftReleased) {
            this.state = DragState::IDLE;
            this.pendingDragClear = true;
            if (this.dragBoxId >= 0) {
                Entity::setActive(this.dragBoxId, false);
            }
            this.applyBoxSelection(mx, my, shift);
        }
    }

    private function cancelDrag(): void {
        this.state = DragState::IDLE;
        this.pendingDragClear = true;
        if (this.dragBoxId >= 0) {
            Entity::setActive(this.dragBoxId, false);
        }
    }

    private function updateDragBox(float mx, float my): void {
        if (this.dragBoxId < 0) {
            return;
        }
        float minX = Util::minF(this.dragStartX, mx);
        float minY = Util::minF(this.dragStartY, my);
        float maxX = Util::maxF(this.dragStartX, mx);
        float maxY = Util::maxF(this.dragStartY, my);
        UI::setRectPixels(this.dragBoxId, minX, minY, maxX - minX, maxY - minY);
    }

    // ---- selection ----

    // Single click: select the friendly unit under the cursor. Plain click
    // replaces the selection (and clears it on a miss); shift-click toggles
    // the clicked unit and leaves the rest alone.
    private function handleClick(float mx, float my, bool shift): void {
        int hitId = this.pickUnit(mx, my);

        if (hitId >= 0) {
            if (shift) {
                if (this.isSelected(hitId)) {
                    this.removeUnit(hitId);
                } else {
                    this.addUnit(hitId);
                }
            } else {
                this.clearSelection();
                this.addUnit(hitId);
            }
            // A unit click is never also a building selection.
            SelectionController sel = this.selection();
            if (sel != null) {
                sel.clearSelection();
            }
            Log::info("[UnitSelection] selected " + this.getSelectedCount() + " unit(s)");
        } else {
            if (!shift) {
                this.clearSelection();
            }
        }
    }

    // Resolve the friendly unit under the cursor. Tries the physics pick first
    // (exact), then falls back to the nearest Selectable player unit whose
    // screen projection is within clickPixelRadius of the cursor -- robust when
    // the physics body lags behind NavmeshAgent-driven movement, where a raw
    // pick would otherwise miss the visible mesh. Returns -1 on a miss.
    private function pickUnit(float mx, float my): int {
        RaycastHit e = Picker::pickEntity(mx, my, "Dynamic");
        if (e.hit && this.isSelectableUnit(e.entityId)) {
            return e.entityId;
        }

        int best = -1;
        float bestSq = this.clickPixelRadius * this.clickPixelRadius;
        int[] ids = PluginComponent::findAll("Selectable");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isActive(id) || !this.isSelectableUnit(id)) {
                continue;
            }
            Vec3f p = Entity::getPosition(id);
            ScreenPoint sp = Picker::worldToScreen(p.x, p.y, p.z);
            if (!sp.visible) {
                continue;
            }
            float dx = sp.x - mx;
            float dy = sp.y - my;
            float d = dx * dx + dy * dy;
            if (d < bestSq) {
                best = id;
                bestSq = d;
            }
        }
        return best;
    }

    // Box release: project every Selectable player unit to the viewport and
    // select the ones inside the drag rectangle.
    private function applyBoxSelection(float mx, float my, bool shift): void {
        if (!shift) {
            this.clearSelection();
        }

        float minX = Util::minF(this.dragStartX, mx);
        float minY = Util::minF(this.dragStartY, my);
        float maxX = Util::maxF(this.dragStartX, mx);
        float maxY = Util::maxF(this.dragStartY, my);

        int added = 0;
        int[] ids = PluginComponent::findAll("Selectable");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (Entity::isActive(id) && this.isSelectableUnit(id)) {
                Vec3f p = Entity::getPosition(id);
                ScreenPoint sp = Picker::worldToScreen(p.x, p.y, p.z);
                if (sp.visible && sp.x >= minX && sp.x <= maxX && sp.y >= minY && sp.y <= maxY) {
                    this.addUnit(id);
                    added = added + 1;
                }
            }
        }

        if (added > 0) {
            SelectionController sel = this.selection();
            if (sel != null) {
                sel.clearSelection();
            }
        }
        Log::info("[UnitSelection] box-selected " + this.getSelectedCount() + " unit(s)");
    }

    // Friendly + selectable filter: needs the RTSGameplay plugin components.
    private function isSelectableUnit(int id): bool {
        if (id < 0) {
            return false;
        }
        if (!PluginComponent::has(id, "Selectable")) {
            return false;
        }
        if (!PluginComponent::getBool(id, "Selectable", "canBeSelected")) {
            return false;
        }
        if (!PluginComponent::has(id, "Team")) {
            return false;
        }
        return PluginComponent::getInt(id, "Team", "teamId") == Config::TEAM_PLAYER;
    }

    private function addUnit(int id): void {
        Int key = new Int(id);
        if (this.selectedRings.containsKey(key)) {
            return;
        }
        if (this.selectedRings.size() >= this.maxSelected) {
            return;
        }
        int ring = this.createRing(this.ringRadiusFor(id));
        Entity::setPosition(ring, Entity::getPosition(id));
        Entity::setActive(ring, true);
        this.selectedRings.put(key, new Int(ring));
        PluginComponent::add(id, "Selected");
    }

    private function removeUnit(int id): void {
        Int key = new Int(id);
        if (!this.selectedRings.containsKey(key)) {
            return;
        }
        Int ring = this.selectedRings.get(key);
        if (ring != null && ring.getValue() >= 0) {
            Entity::destroy(ring.getValue());
        }
        this.selectedRings.remove(key);
        if (Entity::isValid(id)) {
            PluginComponent::remove(id, "Selected");
        }
    }

    // ---- ring decals ----

    // Keep each ring glued to its unit; drop selections whose entity is gone.
    private function updateRings(): void {
        Int[] keys = this.selectedRings.getKeys();
        for (int i = 0; i < keys.length; i = i + 1) {
            int unitId = keys[i].getValue();
            if (!Entity::isValid(unitId)) {
                this.removeUnit(unitId);
            } else {
                Int ring = this.selectedRings.get(keys[i]);
                if (ring != null) {
                    Entity::setPosition(ring.getValue(), Entity::getPosition(unitId));
                }
            }
        }
    }

    // Ring radius sized to the unit's footprint: the larger of its collider
    // half-extents (X/Z) plus a margin, so a big tank/track gets a big ring and
    // a small infantry unit a small one. Falls back to the flat ringRadius when
    // the unit has no collider to measure.
    private function ringRadiusFor(int id): float {
        float r = this.ringRadius;
        if (Physics::hasCollider(id)) {
            Vec3f s = Physics::getColliderSize(id);
            float bigger = s.x;
            if (s.z > bigger) {
                bigger = s.z;
            }
            float scaled = bigger * 1.25 + 0.3;
            if (scaled > r) {
                r = scaled;
            }
        }
        return r;
    }

    // Color-only decal pitched 90 degrees so it projects straight down onto the
    // terrain under the unit (same recipe as SelectionController's highlight,
    // sorted above it so unit rings win where the two overlap).
    private function createRing(float radius): int {
        int id = Entity::create("UnitSelectionRing");
        Entity::addComponent(id, "Decal");
        Decal::setShape(id, Decal::SHAPE_CIRCLE);
        Entity::setRotation(id, new Vec3f(90.0, 0.0, 0.0));
        Decal::setEdgeFalloff(id, 0.35);
        Decal::setSortPriority(id, 11);
        Decal::setColor(id, 0.25, 1.0, 0.4, 0.7);
        Decal::setHalfExtents(id, radius, radius, 4.0);
        Entity::setActive(id, false);
        return id;
    }

    // ---- coordination with the building controllers ----

    private function selection(): SelectionController {
        return Entity::getScript<SelectionController>(Entity::self(), "SelectionController");
    }

    private function placementActive(): bool {
        BuildingPlacementController bp =
            Entity::getScript<BuildingPlacementController>(Entity::self(), "BuildingPlacementController");
        if (bp == null) {
            return false;
        }
        return bp.isPlacing();
    }

    private function pushDragActive(bool active): void {
        SelectionController sel = this.selection();
        if (sel != null) {
            sel.setUnitDragActive(active);
        }
    }

}
