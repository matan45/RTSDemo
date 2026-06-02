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
import * from "../lib/engine/Log.mt";
import * from "../lib/core/collections/HashMap.mt";
import * from "../lib/core/primitives/Int.mt";
import * from "./BuildingInfo.mt";

@Script
class SelectionController {
    private int selectedId;

    // Registry of selectable buildings, keyed by entity id (boxed as Int).
    private HashMap<Int, BuildingInfo> registry;

    // HUD buttons the world-picker must ignore clicks over, so clicking a command
    // button / build slot does not pick the terrain behind the HUD and deselect.
    private int[] guardButtons;
    private int guardCount;

    // Pushed by BuildingPlacementController while placing, so the placement click
    // is not also treated as a selection click (keeps imports one-directional).
    private bool placementActive;

    private bool prevEscDown;

    constructor() {
        this.selectedId = -1;
        this.guardCount = 0;
        this.placementActive = false;
        this.prevEscDown = false;
    }

    public function onStart(): void {
        this.registry = new HashMap<Int, BuildingInfo>();

        this.guardButtons = new int[9];
        this.guardCount = 0;
        this.addGuard("RTS_HUD_CmdMove");
        this.addGuard("RTS_HUD_CmdAttackMove");
        this.addGuard("RTS_HUD_CmdStop");
        this.addGuard("RTS_HUD_CmdHold");
        this.addGuard("RTS_HUD_CmdBuild");
        this.addGuard("RTS_HUD_BuildSlot_0");
        this.addGuard("RTS_HUD_BuildSlot_1");
        this.addGuard("RTS_HUD_BuildSlot_2");
        this.addGuard("RTS_HUD_BuildSlot_3");

        this.registerEnemyBuildings();

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

        // Selection happens on the left-click release edge.
        if (!Input::isMouseButtonReleased(Mouse::LEFT)) {
            return;
        }
        if (this.placementActive) {
            return;
        }
        if (this.isPointerOverHUD()) {
            return;
        }

        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();
        RaycastHit e = Picker::pickEntity(mx, my, "Dynamic");
        if (e.hit && this.isRegistered(e.entityId)) {
            this.selectedId = e.entityId;
            Log::info("[Selection] selected building id=" + this.selectedId);
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

    public function getSelectedInfo(): BuildingInfo {
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
    }

    public function findInfo(int id): BuildingInfo {
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

    private function addGuard(string name): void {
        int id = Entity::findByName(name);
        if (id >= 0) {
            this.guardButtons[this.guardCount] = id;
            this.guardCount = this.guardCount + 1;
        }
    }

    private function isPointerOverHUD(): bool {
        for (int i = 0; i < this.guardCount; i = i + 1) {
            if (UI::isButtonHovered(this.guardButtons[i])) {
                return true;
            }
        }
        return false;
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
