// BuildingPlacementController - VK-1311 building placement widget.
//
// Clicking a build-queue slot (RTS_HUD_BuildSlot_0..3) or the Build command
// button enters placement mode. While placing, a grid-snapped ghost building
// mesh follows the cursor, tinted green when the spot is valid / red when not
// by swapping its material (no DebugDraw overlay). Left-click confirms (spawns a
// building + deducts gold), right-click / ESC cancels, and R rotates the
// footprint in 90-degree steps.
//
// Spawning instantiates the slot's .vfPrefab via Entity::instantiate (engine
// API added for VK-1359 follow-up) -- the prefab carries the mesh, material,
// and box collider authored together in the editor, so nothing is assembled by
// hand here. Prefabs keep their Blender-import base rotation (-90 deg X) and
// scale; the cursor yaw is composed on top (see composedRotation).
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
import * from "../lib/engine/Log.mt";
import * from "../lib/engine/PluginComponent.mt";
import * from "../lib/engine/IUIButtonListener.mt";
import * from "../lib/math/Vec3f.mt";
import * from "./RTSHUDController.mt";
import * from "./BuildingDef.mt";
import * from "./BuildingInfo.mt";
import * from "./SelectionController.mt";

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

    // Reusable ghost entity: a real building prefab instance that follows the
    // cursor while placing. On confirm it is promoted in-place into the placed
    // building, and a fresh ghost is created for the next placement (-1 = none yet).
    private int ghostEntity;

    // The prefab's authored base rotation (captured right after instantiate).
    // Blender OBJ imports arrive Z-up, so prefabs carry a -90 deg X rotation;
    // the engine transform applies Euler as Rx*Ry*Rz, which means world-up yaw
    // must be composed into the right component (see composedRotation).
    private Vec3f ghostBaseRot;

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
    private float slopeMinNormalY;

    // Build a physics body for placed buildings (so they can be selected /
    // block). The collider itself (shape/size/offset/layer) is authored in the
    // prefab; its layer stays off "Static" (0) so the terrain picker keeps
    // hitting the ground (1 = Dynamic in this project's physics layers).
    private bool addCollider;

    private float mapMinX;
    private float mapMaxX;
    private float mapMinZ;
    private float mapMaxZ;

    // One definition per build-slot 0..3 (Barracks / Command / Refinery / Power):
    // prefab, material, footprint, and cost. Set the asset paths to your imports.
    private BuildingDef[] buildings;

    // Which slot's asset the current ghost was built with (-1 = none / stale).
    private int ghostSlot;

    // Ghost tint materials (swapped onto the ghost mesh to signal validity), and
    // the last applied state so we only re-issue the swap when validity flips.
    private string ghostMatValid;
    private string ghostMatInvalid;
    private bool lastGhostValid;

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
        this.ghostBaseRot = new Vec3f(0.0, 0.0, 0.0);

        this.prevLeftDown = false;
        this.prevRightDown = false;
        this.prevRDown = false;
        this.prevEscDown = false;

        this.gridSize = 4.0;
        this.slopeMinNormalY = 0.85;
        this.addCollider = true;
        this.mapMinX = -256.0;
        this.mapMaxX = 256.0;
        this.mapMinZ = -256.0;
        this.mapMaxZ = 256.0;

        // === DEFINE YOUR BUILDINGS HERE (one per build slot) ===
        // new BuildingDef(prefabPath, materialPath, halfX, halfZ, cost, power,
        //                 displayType, displayName, iconPath, maxHealth)
        // power: net contribution to GameState.power once placed -- the Power
        // Plant produces (+), every other building consumes (-).
        // prefabPath is the self-contained .vfPrefab (mesh + material +
        // collider); materialPath is the prefab's own material instance, used
        // to restore the ghost from its tint on confirm. Use project-relative,
        // forward-slash asset paths (VK-1346, resolved against the project
        // root). Absolute paths still work but are not portable. iconPath is
        // the selection-panel portrait (.vfImage) shown by VK-1348.
        this.buildings = new BuildingDef[4];
        // Order must match the build-queue slot labels (GameState.buildQueue):
        // slot 0 = Barracks, slot 1 = Command, slot 2 = Refinery, slot 3 = Power.
        this.buildings[0] = new BuildingDef("assets/buildings2/barracks_prefab.vfPrefab", "assets/buildings2/barracks_inst.vfMatInstance", 6.0, 6.0, 75, -20, "Barracks", "Barracks", "assets/ui/icons/barracks.vfImage", 1000.0);
        this.buildings[1] = new BuildingDef("assets/buildings2/command_center_prefab.vfPrefab", "assets/buildings2/command_center_inst.vfMatInstance", 6.0, 4.0, 50, -30, "CommandCenter", "Command Center", "assets/ui/icons/commandcenter.vfImage", 1500.0);
        this.buildings[2] = new BuildingDef("assets/buildings2/refinery_prefab.vfPrefab", "assets/buildings2/refinery_inst.vfMatInstance", 4.0, 4.0, 40, -25, "Refinery", "Refinery", "assets/ui/icons/refinery.vfImage", 800.0);
        this.buildings[3] = new BuildingDef("assets/buildings2/power_plant_prefab.vfPrefab", "assets/buildings2/power_plant_inst.vfMatInstance", 4.0, 4.0, 60, 50, "Power", "Power Plant", "assets/ui/icons/power.vfImage", 600.0);
        this.ghostSlot = -1;

        this.ghostMatValid = "assets/buildings/GhostValid_inst.vfMatInstance";
        this.ghostMatInvalid = "assets/buildings/GhostInvalid_inst.vfMatInstance";
        this.lastGhostValid = false;
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

        if (this.buildings[0].prefabPath == "") {
            Log::warn("[BuildPlacement] building prefabs are empty; placement will do nothing until you set BuildingDef prefab paths to your authored .vfPrefab assets.");
        }

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

        // Cursor over the HUD: hide the ghost and swallow the click so a
        // building can never be committed behind the HUD. Cancel keys above
        // still work while hovering the HUD.
        if (UI::isPointerOverUI()) {
            this.hideGhost();
            return;
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

        // The ghost is the real building prefab following the cursor. Yaw is
        // composed on top of the prefab's authored base rotation.
        if (this.ghostEntity >= 0) {
            Entity::setActive(this.ghostEntity, true);
            Entity::setPosition(this.ghostEntity, this.ghostCenter);
            Entity::setRotation(this.ghostEntity, this.composedRotation());
        }

        // Tint the ghost mesh to signal validity (green = valid, red = invalid).
        // Swap only when the state flips so we do not re-issue the material-load
        // command every frame.
        if (this.ghostValid != this.lastGhostValid) {
            if (this.ghostEntity >= 0) {
                if (this.ghostValid) {
                    Entity::setMaterial(this.ghostEntity, this.ghostMatValid);
                } else {
                    Entity::setMaterial(this.ghostEntity, this.ghostMatInvalid);
                }
            }
            this.lastGhostValid = this.ghostValid;
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

    // Read by SelectionController so a placement click is not also a selection
    // click (it instead pushes its state via setPlacementActive, below).
    public function isPlacing(): bool {
        return this.placing;
    }

    // Resolve the SelectionController sharing this entity (GameSystems). May be
    // null if it is not attached / not yet loaded.
    private function selection(): SelectionController {
        return Entity::getScript<SelectionController>(Entity::self(), "SelectionController");
    }

    private function enterPlacement(string what): void {
        this.placing = true;
        this.rotationSteps = 0;
        this.ensureGhost();
        SelectionController sel = this.selection();
        if (sel != null) {
            sel.setPlacementActive(true);
            sel.clearSelection();
        }
        Log::info("[BuildPlacement] placement mode ON (" + what + ")");
    }

    private function cancel(): void {
        this.placing = false;
        // Destroy (not just hide) the ghost so repeated enter/cancel cycles do
        // not accumulate hidden tinted prefab instances in the scene.
        if (this.ghostEntity >= 0) {
            Entity::destroy(this.ghostEntity);
            this.ghostEntity = -1;
            this.ghostSlot = -1;
        }
        SelectionController sel = this.selection();
        if (sel != null) {
            sel.setPlacementActive(false);
        }
        Log::info("[BuildPlacement] placement cancelled");
    }

    // Fresh BuildingInfo for the just-placed building, built from its slot's
    // BuildingDef (single source of per-building data). A new instance per
    // building is required because currentHealth is mutated per-entity, so a
    // shared/cached value (e.g. from a map) must not be handed out.
    private function infoForSlot(int slot): BuildingInfo {
        BuildingDef d = this.buildings[slot];
        return new BuildingInfo(d.displayType, d.displayName, d.iconPath, 0, d.maxHealth, this.defaultCommands());
    }

    private function defaultCommands(): string[] {
        string[] cmds = new string[3];
        cmds[0] = "Train";
        cmds[1] = "Rally";
        cmds[2] = "Cancel";
        return cmds;
    }

    // Normalize the active selection to a 0..3 slot index (Build button -> slot 0).
    private function resolvedSlot(): int {
        if (this.selectedSlot >= 0 && this.selectedSlot < 4) {
            return this.selectedSlot;
        }
        return 0;
    }

    private function prefabFor(int slot): string {
        return this.buildings[slot].prefabPath;
    }

    private function materialFor(int slot): string {
        return this.buildings[slot].materialPath;
    }

    // World-up yaw composed onto the prefab's authored base rotation. The engine
    // applies Euler as Rx*Ry*Rz, so for a Blender-import base of -90 deg X the
    // identity Ry(yaw)*Rx(-90) == Rx(-90)*Rz(yaw) puts the yaw into the Z slot
    // (negated for a +90 base); an upright base takes it in Y as usual.
    private function composedRotation(): Vec3f {
        float yaw = (float)(this.rotationSteps * 90);
        float bx = this.ghostBaseRot.x;
        if (bx < -45.0) {
            return new Vec3f(bx, this.ghostBaseRot.y, this.ghostBaseRot.z + yaw);
        }
        if (bx > 45.0) {
            return new Vec3f(bx, this.ghostBaseRot.y, this.ghostBaseRot.z - yaw);
        }
        return new Vec3f(bx, this.ghostBaseRot.y + yaw, this.ghostBaseRot.z);
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
        string pp = this.prefabFor(slot);
        if (pp == "") {
            Log::warn("[BuildPlacement] slot " + slot + " has no prefab path; cannot build ghost.");
            return;
        }
        // The prefab carries mesh + material + collider. No physics body is
        // created for the ghost (colliders are inert until Physics::createBody,
        // VK-1351), so it never blocks the terrain picker.
        int id = Entity::instantiate(pp);
        if (id < 0) {
            Log::warn("[BuildPlacement] failed to instantiate prefab '" + pp + "'.");
            return;
        }
        Entity::setName(id, "BuildGhost");
        // Capture the authored base rotation so cursor yaw composes on top of
        // the Blender-import tilt instead of clobbering it.
        this.ghostBaseRot = Entity::getRotation(id);
        // The ghost wears a tint material (red until the first valid check); the
        // prefab's real material is restored on confirm in commitPlacement().
        if (this.ghostMatInvalid != "") {
            Entity::setMaterial(id, this.ghostMatInvalid);
        }
        this.lastGhostValid = false;
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

        // Resolve the entity to promote BEFORE spending gold so a failed prefab
        // instantiate can never burn resources. Normally the ghost already
        // exists; the fresh-instantiate path is defensive only.
        int slot = this.resolvedSlot();
        int id = this.ghostEntity;
        if (id < 0) {
            id = Entity::instantiate(this.prefabFor(slot));
            if (id < 0) {
                Log::warn("[BuildPlacement] cannot place: prefab instantiate failed for slot " + slot + ".");
                return;
            }
            this.ghostBaseRot = Entity::getRotation(id);
            // Adopt it as the ghost so it is cleaned up if the gold check fails.
            this.ghostEntity = id;
            this.ghostSlot = slot;
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
        int buildCost = this.buildings[slot].cost;
        if (!hud.trySpendGold(buildCost)) {
            Log::warn("[BuildPlacement] not enough gold (need " + buildCost + ").");
            return;
        }
        // Apply the building's power delta (Power Plant produces, others consume).
        hud.addPower(this.buildings[slot].power);

        // Promote the ghost in place into the placed building (the prefab already
        // carries the mesh, material, and collider, and the ghost is at the right
        // pose). The ghost wears a tint material, so restore the prefab's real
        // material, then clear the slot so a fresh ghost is created for the next
        // placement.
        if (this.materialFor(slot) != "") { Entity::setMaterial(id, this.materialFor(slot)); }
        Entity::setName(id, "Building_" + this.placedCount);
        Entity::setActive(id, true);
        Entity::setPosition(id, this.ghostCenter);
        Entity::setRotation(id, this.composedRotation());

        // The placed building (unlike the ghost) gets a real physics body so it
        // can be picked / block movement. VK-1351: the Jolt body is built from
        // the box collider authored in the prefab -- no manual sizing needed.
        if (this.addCollider) {
            Physics::createBody(id);
        }

        // Fog of war (VK-1314): player buildings are vision sources — reveal a
        // generous area around the new building. Team marks it player-owned for
        // the engine-side fog system.
        PluginComponent::add(id, "Team");
        PluginComponent::setInt(id, "Team", "teamId", 0);
        PluginComponent::add(id, "Vision");
        PluginComponent::setFloat(id, "Vision", "sightRadius", 45.0);

        this.ghostEntity = -1;
        this.ghostSlot = -1;

        this.placedCenters[this.placedCount] = this.ghostCenter;
        this.placedHalfX[this.placedCount] = this.halfXFor(this.rotationSteps);
        this.placedHalfZ[this.placedCount] = this.halfZFor(this.rotationSteps);
        this.placedCount = this.placedCount + 1;

        // Make the new building selectable (VK-1348) and release the placement
        // lock so the next click selects instead of placing.
        SelectionController sel = this.selection();
        if (sel != null) {
            BuildingInfo info = this.infoForSlot(this.resolvedSlot());
            // Rotation-adjusted footprint sizes the selection-highlight decal.
            info.halfX = this.halfXFor(this.rotationSteps);
            info.halfZ = this.halfZFor(this.rotationSteps);
            sel.registerBuilding(id, info);
            sel.setPlacementActive(false);
        }

        Log::info("[BuildPlacement] placed building; gold now " + hud.getGold()
            + ", power now " + hud.getPower());
        this.placing = false;
    }
}
