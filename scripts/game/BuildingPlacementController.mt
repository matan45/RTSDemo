// BuildingPlacementController - VK-1311 building placement widget.
//
// Clicking a build-queue slot (RTS_HUD_BuildSlot_0..3) or the Build command
// button enters placement mode. While placing, a grid-snapped ghost footprint
// follows the cursor (DebugDraw box, green when valid / red when not). Left-click
// confirms (spawns a building + deducts gold), right-click / ESC cancels, and R
// rotates the footprint in 90-degree steps.
//
// Spawning creates a fresh entity and assigns a mesh + material to it at runtime
// via Entity::setMesh / Entity::setMaterial (engine API added for VK-1311) -- no
// pre-authored pool required.
//
// Validity (physics-based, no navmesh):
//   a) terrain slope -- the terrain raycast surface normal must be near-vertical
//      (normal.y >= slopeMinNormalY); rejects cliffs
//   b) the footprint stays inside the configured map bounds
//   c) the footprint does not overlap an already-placed building (AABB test)
//
// Attach via a ScriptComponent on an always-active entity (e.g. "GameSystems").

import * from "../lib/engine/Entity.mt";
import * from "../lib/engine/Input.mt";
import * from "../lib/engine/Mouse.mt";
import * from "../lib/engine/Key.mt";
import * from "../lib/engine/UI.mt";
import * from "../lib/engine/Picker.mt";
import * from "../lib/engine/RaycastHit.mt";
import * from "../lib/engine/Terrain.mt";
import * from "../lib/engine/Physics.mt";
import * from "../lib/engine/DebugDraw.mt";
import * from "../lib/engine/Log.mt";
import * from "../lib/engine/IUIButtonListener.mt";
import * from "../lib/math/Vec3f.mt";
import * from "../lib/math/Vec4f.mt";
import * from "./RTSHUDController.mt";
import * from "./BuildingDef.mt";

@Script
class BuildingPlacementController implements IUIButtonListener {
    // Resolved entities.
    private int cmdBuildId;
    private int hudControllerId;
    private int[] buildSlotIds;

    // Placement state machine.
    private bool placing;
    private int selectedSlot;
    private int rotationSteps;
    private Vec3f ghostCenter;
    private bool ghostValid;

    // Reusable ghost entity: a real building mesh that follows the cursor while
    // placing. On confirm it is promoted in-place into the placed building, and a
    // fresh ghost is created for the next placement (-1 = none yet).
    private int ghostEntity;

    // Placed footprints (for overlap testing).
    private int maxPlaced;
    private Vec3f[] placedCenters;
    private float[] placedHalfX;
    private float[] placedHalfZ;
    private int placedCount;

    // Input edge tracking (Input exposes state, not edges).
    private bool prevLeftDown;
    private bool prevRightDown;
    private bool prevRDown;
    private bool prevEscDown;

    // Config.
    private float gridSize;
    private float buildingHeight;
    private float slopeMinNormalY;

    // Add a box collider to placed buildings (so they can be selected / block).
    // Layer stays OFF "Static" (0) so the terrain picker keeps hitting the ground;
    // 1 = Dynamic in this project's physics layers.
    private bool addCollider;
    private int colliderLayer;

    private float mapMinX;
    private float mapMaxX;
    private float mapMinZ;
    private float mapMaxZ;

    // One definition per build-slot 0..3 (Barracks / Command / Refinery / Power):
    // mesh, material, footprint, and cost. Set the asset paths to your imports.
    private BuildingDef[] buildings;

    // Which slot's asset the current ghost was built with (-1 = none / stale).
    private int ghostSlot;

    // Ghost colors.
    private Vec4f colorValid;
    private Vec4f colorInvalid;

    constructor() {
        this.cmdBuildId = -1;
        this.hudControllerId = -1;

        this.placing = false;
        this.selectedSlot = -1;
        this.rotationSteps = 0;
        this.ghostCenter = new Vec3f(0.0, 0.0, 0.0);
        this.ghostValid = false;

        this.maxPlaced = 64;
        this.placedCount = 0;
        this.ghostEntity = -1;

        this.prevLeftDown = false;
        this.prevRightDown = false;
        this.prevRDown = false;
        this.prevEscDown = false;

        this.gridSize = 4.0;
        this.buildingHeight = 4.0;
        this.slopeMinNormalY = 0.85;
        this.addCollider = true;
        this.colliderLayer = 1;
        this.mapMinX = -256.0;
        this.mapMaxX = 256.0;
        this.mapMinZ = -256.0;
        this.mapMaxZ = 256.0;

        // === DEFINE YOUR BUILDINGS HERE (one per build slot) ===
        // new BuildingDef(meshPath, materialPath, halfX, halfZ, cost)
        // Use project-relative, forward-slash asset paths (VK-1346),
        // e.g. "assets/buildings/Barracks.vfMesh" (resolved against the project
        // root). Absolute paths still work but are not portable.
        this.buildings = new BuildingDef[4];
        this.buildings[0] = new BuildingDef("assets/buildings/CommandCenter.vfMesh", "assets/buildings/CommandCenter_inst.vfMatInstance", 6.0, 4.0, 50);  // Command Center
        this.buildings[1] = new BuildingDef("", "", 6.0, 6.0, 75);  // Command
        this.buildings[2] = new BuildingDef("", "", 4.0, 4.0, 40);  // Refinery
        this.buildings[3] = new BuildingDef("", "", 4.0, 4.0, 60);  // Power
        this.ghostSlot = -1;

        this.colorValid = new Vec4f(0.2, 0.9, 0.2, 1.0);
        this.colorInvalid = new Vec4f(0.9, 0.2, 0.2, 1.0);
    }

    public function onStart(): void {
        this.cmdBuildId = Entity::findByName("RTS_HUD_CmdBuild");
        this.hudControllerId = Entity::findByName("RTS_HUD_Controller");
        if (this.hudControllerId < 0) {
            Log::warn("[BuildPlacement] HUD controller entity not found; gold deduction disabled.");
        }

        this.buildSlotIds = new int[4];
        for (int i = 0; i < 4; i = i + 1) {
            this.buildSlotIds[i] = Entity::findByName("RTS_HUD_BuildSlot_" + i);
        }

        this.placedCenters = new Vec3f[this.maxPlaced];
        this.placedHalfX = new float[this.maxPlaced];
        this.placedHalfZ = new float[this.maxPlaced];

        if (this.buildings[0].meshPath == "") {
            Log::warn("[BuildPlacement] building meshes are empty; placed buildings will be invisible until you set BuildingDef mesh/material paths to your imported assets.");
        }

        DebugDraw::setEnabled(true);
        Log::info("[BuildPlacement] ready.");
    }

    public function onUpdate(float deltaTime): void {
        // Derive press edges every frame so previous-state tracking stays fresh.
        bool nowLeft = Input::isMouseButtonDown(Mouse::LEFT);
        bool nowRight = Input::isMouseButtonDown(Mouse::RIGHT);
        bool nowR = Input::isKeyDown(Key::R);
        bool nowEsc = Input::isKeyDown(Key::ESCAPE);

        bool leftPressed = !this.prevLeftDown && nowLeft;
        bool rightPressed = !this.prevRightDown && nowRight;
        bool rPressed = !this.prevRDown && nowR;
        bool escPressed = !this.prevEscDown && nowEsc;

        this.prevLeftDown = nowLeft;
        this.prevRightDown = nowRight;
        this.prevRDown = nowR;
        this.prevEscDown = nowEsc;

        if (!this.placing) {
            return;
        }

        if (rightPressed) {
            Log::info("[BuildPlacement] cancel via RIGHT mouse");
            this.cancel();
            return;
        }
        if (escPressed) {
            Log::info("[BuildPlacement] cancel via ESC");
            this.cancel();
            return;
        }

        if (rPressed) {
            this.rotationSteps = (this.rotationSteps + 1) % 4;
            Log::info("[BuildPlacement] R rotate -> step " + this.rotationSteps
                + " (yaw " + (this.rotationSteps * 90) + " deg)");
        }

        // Resolve the ground point + surface normal under the cursor via physics.
        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();
        RaycastHit hit = Picker::pickTerrainPhysics(mx, my);
        if (!hit.hit) {
            // Cursor is not over the terrain; hide the ghost this frame.
            this.hideGhost();
            return;
        }

        Vec3f snapped = this.snapToGrid(hit.point);
        float groundY = Terrain::heightAt(snapped.x, snapped.z);
        this.ghostCenter = new Vec3f(snapped.x, groundY, snapped.z);
        this.ghostValid = this.isValidPlacement(this.ghostCenter, this.rotationSteps, hit.normal.y);

        // The ghost is the real building mesh following the cursor.
        Vec3f rot = new Vec3f(0.0, (float)(this.rotationSteps * 90), 0.0);
        if (this.ghostEntity >= 0) {
            Entity::setActive(this.ghostEntity, true);
            Entity::setPosition(this.ghostEntity, this.ghostCenter);
            Entity::setRotation(this.ghostEntity, rot);
        }

        // Footprint overlay shows validity (green/red) -- no runtime mesh tint yet.
        float hx = this.halfXFor(this.rotationSteps);
        float hz = this.halfZFor(this.rotationSteps);
        Vec3f extents = new Vec3f(hx, this.buildingHeight, hz);
        if (this.ghostValid) {
            DebugDraw::box(this.ghostCenter, extents, this.colorValid);
        } else {
            DebugDraw::box(this.ghostCenter, extents, this.colorInvalid);
        }

        if (leftPressed) {
            if (this.ghostValid) {
                this.commitPlacement();
            } else {
                Log::info("[BuildPlacement] left-click ignored: invalid spot (slope/bounds/overlap)");
            }
        }
    }

    public function onDestroy(): void {
    }

    @Override
    public function onButtonClicked(int buttonEntityId, string entityName): void {
        int slot = this.slotIndexFor(buttonEntityId);
        if (slot >= 0) {
            this.selectedSlot = slot;
            string label = UI::getLabelText(this.buildSlotIds[slot]);
            this.enterPlacement(label);
            return;
        }
        if (buttonEntityId == this.cmdBuildId || entityName == "RTS_HUD_CmdBuild") {
            this.selectedSlot = -1;
            this.enterPlacement("building");
        }
    }

    @Override
    public function onButtonPressed(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonReleased(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonHoverEnter(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonHoverExit(int buttonEntityId, string entityName): void { }

    private function slotIndexFor(int entityId): int {
        for (int i = 0; i < 4; i = i + 1) {
            if (this.buildSlotIds[i] >= 0 && this.buildSlotIds[i] == entityId) {
                return i;
            }
        }
        return -1;
    }

    private function enterPlacement(string what): void {
        this.placing = true;
        this.rotationSteps = 0;
        this.ensureGhost();
        Log::info("[BuildPlacement] placement mode ON (" + what + ")");
    }

    private function cancel(): void {
        this.placing = false;
        this.hideGhost();
        Log::info("[BuildPlacement] placement cancelled");
    }

    // Normalize the active selection to a 0..3 slot index (Build button -> slot 0).
    private function resolvedSlot(): int {
        if (this.selectedSlot >= 0 && this.selectedSlot < 4) {
            return this.selectedSlot;
        }
        return 0;
    }

    private function meshFor(int slot): string {
        return this.buildings[slot].meshPath;
    }

    private function materialFor(int slot): string {
        return this.buildings[slot].materialPath;
    }

    // Create/refresh the reusable ghost entity for the selected build slot. Rebuilds
    // it when the chosen building type differs from the current ghost's type.
    private function ensureGhost(): void {
        int slot = this.resolvedSlot();
        if (this.ghostEntity >= 0 && this.ghostSlot == slot) {
            return;
        }
        if (this.ghostEntity >= 0) {
            Entity::destroy(this.ghostEntity);
            this.ghostEntity = -1;
        }
        int id = Entity::create("BuildGhost");
        string mp = this.meshFor(slot);
        string xp = this.materialFor(slot);
        if (mp != "") {
            Entity::setMesh(id, mp);
        }
        if (xp != "") {
            Entity::setMaterial(id, xp);
        }
        Entity::setActive(id, false);
        this.ghostEntity = id;
        this.ghostSlot = slot;
    }

    private function hideGhost(): void {
        if (this.ghostEntity >= 0) {
            Entity::setActive(this.ghostEntity, false);
        }
    }

    // Round each axis to the nearest grid node. mType has no floor(), so use the
    // sign-aware add-half-then-truncate idiom ((int) truncates toward zero).
    private function snapToGrid(Vec3f p): Vec3f {
        float kx = p.x / this.gridSize;
        int nx = (int)(kx + 0.5);
        if (kx < 0.0) {
            nx = (int)(kx - 0.5);
        }

        float kz = p.z / this.gridSize;
        int nz = (int)(kz + 0.5);
        if (kz < 0.0) {
            nz = (int)(kz - 0.5);
        }

        return new Vec3f((float)nx * this.gridSize, 0.0, (float)nz * this.gridSize);
    }

    // A 90-degree rotation of an axis-aligned rectangle just swaps its extents
    // on odd steps, so the world AABB stays exact. Footprint comes from the
    // currently-selected building definition.
    private function halfXFor(int steps): float {
        BuildingDef def = this.buildings[this.resolvedSlot()];
        if (steps % 2 == 0) {
            return def.halfX;
        }
        return def.halfZ;
    }

    private function halfZFor(int steps): float {
        BuildingDef def = this.buildings[this.resolvedSlot()];
        if (steps % 2 == 0) {
            return def.halfZ;
        }
        return def.halfX;
    }

    private function isValidPlacement(Vec3f center, int steps, float groundNormalY): bool {
        // (a) slope: the terrain surface normal must be near-vertical (physics).
        if (groundNormalY < this.slopeMinNormalY) {
            return false;
        }

        float hx = this.halfXFor(steps);
        float hz = this.halfZFor(steps);

        // (b) map bounds.
        if (center.x - hx < this.mapMinX || center.x + hx > this.mapMaxX) {
            return false;
        }
        if (center.z - hz < this.mapMinZ || center.z + hz > this.mapMaxZ) {
            return false;
        }

        // (c) overlap against already-placed buildings (AABB vs AABB).
        for (int j = 0; j < this.placedCount; j = j + 1) {
            float dx = center.x - this.placedCenters[j].x;
            if (dx < 0.0) { dx = -dx; }
            float dz = center.z - this.placedCenters[j].z;
            if (dz < 0.0) { dz = -dz; }
            if (dx < hx + this.placedHalfX[j] && dz < hz + this.placedHalfZ[j]) {
                return false;
            }
        }

        return true;
    }

    private function commitPlacement(): void {
        if (this.placedCount >= this.maxPlaced) {
            Log::warn("[BuildPlacement] placed-building cap reached; cannot place more.");
            this.cancel();
            return;
        }

        // Deduct gold from the single source of truth in RTSHUDController/GameState.
        if (this.hudControllerId < 0) {
            Log::warn("[BuildPlacement] no HUD controller; cannot deduct gold.");
            return;
        }
        RTSHUDController hud = Entity::getScript<RTSHUDController>(this.hudControllerId, "RTSHUDController");
        if (hud == null) {
            Log::warn("[BuildPlacement] HUD controller script unavailable; cannot deduct gold.");
            return;
        }
        int buildCost = this.buildings[this.resolvedSlot()].cost;
        if (!hud.trySpendGold(buildCost)) {
            Log::warn("[BuildPlacement] not enough gold (need " + buildCost + ").");
            return;
        }

        // Promote the ghost in place into the placed building (it already has the
        // mesh + material and is at the right pose), then clear the slot so a fresh
        // ghost is created for the next placement.
        int id = this.ghostEntity;
        if (id < 0) {
            int slot = this.resolvedSlot();
            id = Entity::create("Building_" + this.placedCount);
            if (this.meshFor(slot) != "") { Entity::setMesh(id, this.meshFor(slot)); }
            if (this.materialFor(slot) != "") { Entity::setMaterial(id, this.materialFor(slot)); }
        }
        Entity::setName(id, "Building_" + this.placedCount);
        Entity::setActive(id, true);
        Entity::setPosition(id, this.ghostCenter);
        Entity::setRotation(id, new Vec3f(0.0, (float)(this.rotationSteps * 90), 0.0));

        // The placed building (unlike the ghost) gets a box collider so it can be
        // picked / block movement. Uses un-rotated footprint extents -- the box
        // rotates with the entity transform.
        if (this.addCollider) {
            int slot = this.resolvedSlot();
            BuildingDef def = this.buildings[slot];
            Entity::addComponent(id, "Collider");
            Physics::setColliderSize(id, new Vec3f(def.halfX, this.buildingHeight, def.halfZ));
            Physics::setCollisionLayer(id, this.colliderLayer);
        }

        this.ghostEntity = -1;
        this.ghostSlot = -1;

        this.placedCenters[this.placedCount] = this.ghostCenter;
        this.placedHalfX[this.placedCount] = this.halfXFor(this.rotationSteps);
        this.placedHalfZ[this.placedCount] = this.halfZFor(this.rotationSteps);
        this.placedCount = this.placedCount + 1;

        Log::info("[BuildPlacement] placed building; gold now " + hud.getGold());
        this.placing = false;
    }
}
