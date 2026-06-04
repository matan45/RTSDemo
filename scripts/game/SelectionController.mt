// SelectionController - minimal building click-selection for the RTS demo (VK-1348).
//
// VK-1302 (full unit selection) is not implemented; this provides the building
// half: left-click a building to select it, click empty ground / press ESC to
// deselect. It is the single source of selection truth -- RTSHUDController reads
// getSelectedInfo() each frame to drive the selection context panel, and
// BuildingPlacementController calls registerBuilding() when it places one.
//
// The engine exposes no per-entity game components to mType, so a registry of
// (entityId -> BuildingInfo) is kept here in a HashMap (entity id boxed as Int).
// Attach this @Script to the GameSystems entity alongside BuildingPlacementController.

import * from "../lib/engine/Entity.mt";
import * from "../lib/engine/Input.mt";
import * from "../lib/engine/Mouse.mt";
import * from "../lib/engine/Key.mt";
import * from "../lib/engine/UI.mt";
import * from "../lib/engine/Picker.mt";
import * from "../lib/engine/RaycastHit.mt";
import * from "../lib/engine/Decal.mt";
import * from "../lib/engine/Log.mt";
import * from "../lib/core/collections/HashMap.mt";
import * from "../lib/core/primitives/Int.mt";
import * from "../lib/math/Vec3f.mt";
import * from "./BuildingInfo.mt";

@Script
class SelectionController {
    private int selectedId;

    // Registry of selectable buildings, keyed by entity id (boxed as Int).
    private HashMap<Int, BuildingInfo?> registry;

    // Pushed by BuildingPlacementController while placing, so the placement click
    // is not also treated as a selection click (keeps imports one-directional).
    private bool placementActive;

    private bool prevEscDown;
    private bool prevLeftDown;

    // Reusable ground-projected decal marking the selected building (green =
    // player, red = enemy). -1 until created; lastHighlightId tracks which
    // building it is glued to so commands are only re-issued on change.
    private int highlightId;
    private int lastHighlightId;

    constructor() {
        this.selectedId = -1;
        this.placementActive = false;
        this.prevEscDown = false;
        this.prevLeftDown = false;
        this.highlightId = -1;
        this.lastHighlightId = -1;
    }

    public function onStart(): void {
        this.registry = new HashMap<Int, BuildingInfo>();

        this.registerEnemyBuildings();
        this.createHighlight();

        Log::info("[Selection] ready.");
    }

    public function onUpdate(float deltaTime): void {
        // ESC clears selection (edge-detected).
        bool nowEsc = Input::isKeyDown(Key::ESCAPE);
        bool escPressed = !this.prevEscDown && nowEsc;
        this.prevEscDown = nowEsc;
        if (escPressed) {
            this.clearSelection();
        }

        this.handleClick();
        this.updateHighlight();
    }

    // Select on the left-button RELEASE edge (down -> up this frame).
    // Input::isMouseButtonReleased is LEVEL (true every frame the button is
    // up), so derive the edge from isMouseButtonDown instead.
    private function handleClick(): void {
        bool nowLeft = Input::isMouseButtonDown(Mouse::LEFT);
        bool leftReleased = this.prevLeftDown && !nowLeft;
        this.prevLeftDown = nowLeft;
        if (!leftReleased) {
            return;
        }

        if (this.placementActive) {
            Log::info("[Selection] click ignored (placement active)");
            return;
        }
        if (UI::isPointerOverUI()) {
            Log::info("[Selection] click ignored (over HUD)");
            return;
        }

        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();
        RaycastHit e = Picker::pickEntity(mx, my, "Dynamic");
        if (e.hit && this.isRegistered(e.entityId)) {
            this.selectedId = e.entityId;
            Log::info("[Selection] SELECTED building id=" + this.selectedId);
        } else {
            this.selectedId = -1;
        }
    }

    public function onDestroy(): void {
    }

    // ---- public API (read by RTSHUDController, written by BuildingPlacementController) ----

    public function getSelectedId(): int {
        return this.selectedId;
    }

    public function getSelectedInfo(): BuildingInfo? {
        return this.findInfo(this.selectedId);
    }

    public function clearSelection(): void {
        this.selectedId = -1;
    }

    public function setPlacementActive(bool active): void {
        this.placementActive = active;
    }

    public function registerBuilding(int id, BuildingInfo info): void {
        if (id < 0 || info == null) {
            return;
        }
        this.registry.put(new Int(id), info);
        Log::info("[Selection] registered building id=" + id + " type=" + info.buildingType);
    }

    public function findInfo(int id): BuildingInfo? {
        if (id < 0) {
            return null;
        }
        return this.registry.get(new Int(id));
    }

    public function isRegistered(int id): bool {
        if (id < 0) {
            return false;
        }
        return this.registry.containsKey(new Int(id));
    }

    // ---- helpers ----

    // Build the reusable selection-highlight entity: a color-only decal (no
    // albedo texture renders as a solid tint) pitched 90 degrees so its local
    // +Z projection axis points straight down onto the terrain around the
    // selected building. The default angle fade hides the tint on near-vertical
    // building walls, leaving a clean ground halo.
    private function createHighlight(): void {
        int id = Entity::create("SelectionHighlight");
        Entity::addComponent(id, "Decal");
        Entity::setRotation(id, new Vec3f(90.0, 0.0, 0.0));
        Decal::setEdgeFalloff(id, 0.35);
        Decal::setSortPriority(id, 10);
        Entity::setActive(id, false);
        this.highlightId = id;
    }

    // Keep the highlight decal glued to the current selection; commands are
    // only re-issued when the selected building actually changes.
    private function updateHighlight(): void {
        if (this.highlightId < 0 || this.selectedId == this.lastHighlightId) {
            return;
        }
        this.lastHighlightId = this.selectedId;

        BuildingInfo? info = this.findInfo(this.selectedId);
        if (info == null) {
            Entity::setActive(this.highlightId, false);
            return;
        }

        Entity::setPosition(this.highlightId, Entity::getPosition(this.selectedId));
        // Slightly larger than the footprint so a colored rim shows around the
        // building; z is the projection depth (covers terrain slope).
        Decal::setHalfExtents(this.highlightId, info.halfX + 1.5, info.halfZ + 1.5, 4.0);
        if (info.isPlayer()) {
            Decal::setColor(this.highlightId, 0.25, 1.0, 0.4, 0.6);
        } else {
            Decal::setColor(this.highlightId, 1.0, 0.3, 0.25, 0.6);
        }
        Entity::setActive(this.highlightId, true);
    }

    // Optional: register any scene entity named "EnemyBuilding" as an enemy-faction
    // building so the read-only (no command card) path is testable. No-op if none
    // exist. Such an entity needs a Dynamic-layer collider to be pickable.
    private function registerEnemyBuildings(): void {
        int[] ids = Entity::findAll("EnemyBuilding");
        for (int i = 0; i < ids.length; i = i + 1) {
            string[] noCmds = new string[0];
            BuildingInfo info = new BuildingInfo("Enemy", "Enemy Structure",
                "assets/ui/icons/enemy.vfImage", 1, 100.0, noCmds);
            this.registerBuilding(ids[i], info);
        }
    }
}
