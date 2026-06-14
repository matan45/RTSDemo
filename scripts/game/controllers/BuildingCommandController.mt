// BuildingCommandController - executes the per-building command card.
//
// RTSHUDController renders each selected building's command card (Sell / Upgrade
// / Rally / Soldier / Engineer / Tank / Track) but is display-only; this script
// is a second IUIButtonListener on the GameSystems entity that actually carries
// out the clicked command:
//
//   Sell     - destroy the building, refund 70% of its gold cost, reverse its
//              power delta, and free its placement footprint.
//   Upgrade  - spend gold (60% of cost) to boost max health (Power Plant also
//              gains +25 power output). One level.
//   Rally    - the next ground click sets a rally point; units trained at that
//              building walk to it on spawn.
//   Soldier / Engineer / Tank - queue a unit (gold + build time); the unit
//              spawns when the queue head finishes.
//   Track    - spawn a harvester that loops the refinery <-> nearest GoldNode,
//              depositing gold each trip.
//
// Units are placeholder prefabs (assets/units/*_prefab.vfPrefab) reusing an
// imported mesh until real unit art lands; they get Selectable + Team(0) +
// a physics body so the existing UnitSelectionController can select them, and
// move via a self-contained straight-line stepper (no NavmeshAgent dependency).
//
// Attach this @Script to GameSystems alongside SelectionController /
// BuildingPlacementController / UnitSelectionController.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Mouse.mt";
import * from "../../lib/engine/UI.mt";
import * from "../../lib/engine/Picker.mt";
import * from "../../lib/engine/RaycastHit.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Physics.mt";
import * from "../../lib/engine/Decal.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/IUIButtonListener.mt";
import * from "../../lib/core/collections/HashMap.mt";
import * from "../../lib/core/primitives/Int.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "./RTSHUDController.mt";
import * from "./SelectionController.mt";
import * from "./BuildingPlacementController.mt";
import * from "../data/BuildingInfo.mt";
import * from "../data/UnitDef.mt";
import * from "../data/Harvester.mt";
import * from "../data/QueueItem.mt";
import * from "../util/Config.mt";
import * from "../util/HState.mt";
import * from "../util/InputEdge.mt";

@Script
class BuildingCommandController implements IUIButtonListener {
    private int hudControllerId;
    private RTSHUDController? hudRef;

    // Command-card buttons in the same display order RTSHUDController uses.
    private int[] cmdButtons;

    // Rally: building entity id -> rally Vec3f, plus a reusable ground marker.
    private HashMap<Int, Vec3f?> rallyPoints;
    private HashMap<Int, Int?> rallyMarkers;
    private int pendingRallyBuilding;

    // Trained units walking to their rally point: unit id -> destination.
    private HashMap<Int, Vec3f?> moveTargets;

    // Production queue (FIFO; head = index 0).
    private int maxQueue;
    private QueueItem[] queue;
    private int queueCount;

    // Active harvesters (state uses HState::*).
    private int maxHarvesters;
    private Harvester[] harvesters;
    private int harvCount;

    // Unit definitions (cost / time / prefab / icon), scanned by type.
    private UnitDef[] unitDefs;

    // Queue HUD (spawned once from a prefab under RTS_HUD_Canvas, positioned above
    // the command bar each frame while non-empty). Slots are pooled UIListView items.
    private int queueHudId;
    private int queueLabelId;
    private int queueListId;
    private int queueProgressId;
    private int hudCommandBarId;

    private InputEdge leftEdge;
    private int unitSerial;

    private float unitSpeed;
    private float arriveEps;

    // Gameplay tuning.
    private int sellRefundPct;
    private int upgradeCostPct;
    private int harvestDeposit;

    constructor() {
        this.hudControllerId = -1;
        this.hudRef = null;
        this.pendingRallyBuilding = -1;
        this.queueCount = 0;
        this.harvCount = 0;
        this.maxQueue = 8;
        this.maxHarvesters = 16;
        this.queueHudId = -1;
        this.queueLabelId = -1;
        this.queueListId = -1;
        this.queueProgressId = -1;
        this.hudCommandBarId = -1;
        this.unitSerial = 0;
        this.unitSpeed = 8.0;
        this.arriveEps = 0.4;
        this.sellRefundPct = 70;
        this.upgradeCostPct = 60;
        this.harvestDeposit = 10;
    }

    public function onStart(): void {
        this.leftEdge = new InputEdge();
        this.hudControllerId = Entity::findByName("RTS_HUD_Controller");
        this.hudCommandBarId = Entity::findByName("RTS_HUD_CommandBar");

        this.cmdButtons = new int[5];
        this.cmdButtons[0] = Entity::findByName("RTS_HUD_CmdMove");
        this.cmdButtons[1] = Entity::findByName("RTS_HUD_CmdAttackMove");
        this.cmdButtons[2] = Entity::findByName("RTS_HUD_CmdStop");
        this.cmdButtons[3] = Entity::findByName("RTS_HUD_CmdHold");
        this.cmdButtons[4] = Entity::findByName("RTS_HUD_CmdBuild");

        this.rallyPoints = new HashMap<Int, Vec3f>();
        this.rallyMarkers = new HashMap<Int, Int>();
        this.moveTargets = new HashMap<Int, Vec3f>();

        this.queue = new QueueItem[this.maxQueue];
        this.harvesters = new Harvester[this.maxHarvesters];

        this.defineUnits();
        this.setupQueueUI();
        Log::info("[BuildingCommand] ready.");
    }

    // Unit table (single source of cost / build time / prefab / icon). The
    // "Harvester" entry (index 3) doubles as the default for unknown types.
    private function defineUnits(): void {
        this.unitDefs = new UnitDef[4];
        this.unitDefs[0] = new UnitDef("Soldier", 25, 3.0, "assets/units/soldier_prefab.vfPrefab", "assets/ui/icons/units/soldier.vfImage");
        this.unitDefs[1] = new UnitDef("Engineer", 40, 5.0, "assets/units/engineer_prefab.vfPrefab", "assets/ui/icons/units/engineer.vfImage");
        this.unitDefs[2] = new UnitDef("Tank", 75, 8.0, "assets/units/tank_prefab.vfPrefab", "assets/ui/icons/units/tank.vfImage");
        this.unitDefs[3] = new UnitDef("Harvester", 30, 4.0, "assets/units/harvester_prefab.vfPrefab", "assets/ui/icons/units/track.vfImage");
    }

    // Look up a unit definition by type; falls back to the Harvester entry for
    // unknown types (preserves the old default behavior of the unit*() tables).
    private function unitDef(string type): UnitDef {
        for (int i = 0; i < this.unitDefs.length; i = i + 1) {
            if (this.unitDefs[i].unitType == type) {
                return this.unitDefs[i];
            }
        }
        return this.unitDefs[3];
    }

    public function onUpdate(float deltaTime): void {
        this.handleRallyClick();
        this.updateRallyMarkers();
        this.tickQueue(deltaTime);
        this.tickMovers(deltaTime);
        this.tickHarvesters(deltaTime);
        this.updateQueueUI();
    }

    public function onDestroy(): void {
        // Tear down the spawned HUD (root -> list -> pooled item instances) so it
        // does not leak across script reloads.
        if (this.queueHudId >= 0 && Entity::isValid(this.queueHudId)) {
            Entity::destroy(this.queueHudId);
        }
        this.queueHudId = -1;
        this.queueListId = -1;
        this.queueLabelId = -1;
        this.queueProgressId = -1;
    }

    // ---- IUIButtonListener ----

    @Override
    public function onButtonClicked(int buttonEntityId, string entityName): void {
        SelectionController? sel = this.selection();
        if (sel == null) {
            return;
        }
        BuildingInfo? info = sel.getSelectedInfo();
        if (info == null || !info.isPlayer()) {
            return;
        }
        int idx = this.cmdIndexFor(buttonEntityId);
        if (idx < 0 || idx >= info.commands.length) {
            return;
        }
        this.execute(sel.getSelectedId(), info, info.commands[idx]);
    }

    @Override
    public function onButtonPressed(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonReleased(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonHoverEnter(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonHoverExit(int buttonEntityId, string entityName): void { }

    // ---- command dispatch ----

    private function execute(int buildingId, BuildingInfo info, string cmd): void {
        if (cmd == "Sell") { this.sell(buildingId, info); return; }
        if (cmd == "Upgrade") { this.upgrade(buildingId, info); return; }
        if (cmd == "Rally") { this.beginRally(buildingId); return; }
        if (cmd == "Track") { this.spawnHarvester(buildingId); return; }
        if (cmd == "Soldier") { this.enqueue(buildingId, "Soldier"); return; }
        if (cmd == "Engineer") { this.enqueue(buildingId, "Engineer"); return; }
        if (cmd == "Tank") { this.enqueue(buildingId, "Tank"); return; }
    }

    private function sell(int buildingId, BuildingInfo info): void {
        int refund = (info.cost * this.sellRefundPct) / 100;
        RTSHUDController? hud = this.hud();
        if (hud != null) {
            hud.addGold(refund);
            hud.addPower(-info.power);
            hud.pushAlertMessage("Sold " + info.displayName + " (+" + parsePrimitive(refund) + " gold)", 2.0);
        }
        BuildingPlacementController? bp = this.placement();
        if (bp != null) {
            bp.removePlaced(buildingId);
        }
        this.clearRally(buildingId);
        SelectionController? sel = this.selection();
        if (sel != null) {
            sel.unregister(buildingId);
            sel.clearSelection();
        }
        if (Entity::isValid(buildingId)) {
            Entity::destroy(buildingId);
        }
    }

    private function upgrade(int buildingId, BuildingInfo info): void {
        RTSHUDController? hud = this.hud();
        if (hud == null) {
            return;
        }
        if (info.level > 0) {
            hud.pushAlertMessage(info.displayName + " already upgraded", 2.0);
            return;
        }
        int upCost = (info.cost * this.upgradeCostPct) / 100;
        if (!hud.trySpendGold(upCost)) {
            hud.pushAlertMessage("Need " + parsePrimitive(upCost) + " gold to upgrade", 2.0);
            return;
        }
        info.maxHealth = info.maxHealth * 1.5;
        info.currentHealth = info.maxHealth;
        info.level = 1;
        if (info.buildingType == "Power") {
            hud.addPower(25);
            info.power = info.power + 25;
        }
        hud.pushAlertMessage("Upgraded " + info.displayName, 2.0);
    }

    // ---- rally ----

    private function beginRally(int buildingId): void {
        this.pendingRallyBuilding = buildingId;
        // Suppress building re-selection while we capture the next ground click.
        SelectionController? sel = this.selection();
        if (sel != null) {
            sel.setPlacementActive(true);
        }
        RTSHUDController? hud = this.hud();
        if (hud != null) {
            hud.pushAlertMessage("Rally: click ground to set", 2.0);
        }
    }

    private function handleRallyClick(): void {
        this.leftEdge.step(Input::isMouseButtonDown(Mouse::LEFT));
        bool leftReleased = this.leftEdge.wasReleased;

        if (this.pendingRallyBuilding < 0 || !leftReleased) {
            return;
        }

        int building = this.pendingRallyBuilding;
        this.pendingRallyBuilding = -1;
        SelectionController? sel = this.selection();
        if (sel != null) {
            sel.setPlacementActive(false);
        }

        if (UI::isPointerOverUI()) {
            return;
        }
        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();
        RaycastHit hit = Picker::pickTerrainPhysics(mx, my);
        if (!hit.hit) {
            return;
        }
        Vec3f p = new Vec3f(hit.point.x, Terrain::heightAt(hit.point.x, hit.point.z), hit.point.z);
        this.setRally(building, p);
        RTSHUDController? hud = this.hud();
        if (hud != null) {
            hud.pushAlertMessage("Rally point set", 1.5);
        }
    }

    private function setRally(int buildingId, Vec3f p): void {
        Int key = new Int(buildingId);
        this.rallyPoints.put(key, p);

        int marker = -1;
        Int? existing = this.rallyMarkers.get(key);
        if (existing != null) {
            marker = existing.getValue();
        }
        if (marker < 0 || !Entity::isValid(marker)) {
            marker = this.createRallyMarker();
            this.rallyMarkers.put(key, new Int(marker));
        }
        Entity::setPosition(marker, p);
        Entity::setActive(marker, true);
    }

    private function clearRally(int buildingId): void {
        Int key = new Int(buildingId);
        Int? existing = this.rallyMarkers.get(key);
        if (existing != null) {
            int marker = existing.getValue();
            if (Entity::isValid(marker)) {
                Entity::destroy(marker);
            }
        }
        this.rallyMarkers.remove(key);
        this.rallyPoints.remove(key);
    }

    // Show only the selected building's rally marker: it appears when its
    // building is selected and hides again on deselect / other-building select.
    private function updateRallyMarkers(): void {
        int selectedId = -1;
        SelectionController? sel = this.selection();
        if (sel != null) {
            selectedId = sel.getSelectedId();
        }
        Int[] keys = this.rallyMarkers.getKeys();
        for (int i = 0; i < keys.length; i = i + 1) {
            int buildingId = keys[i].getValue();
            Int? markerBox = this.rallyMarkers.get(keys[i]);
            if (markerBox == null) {
                continue;
            }
            int marker = markerBox?.getValue();
            if (marker < 0 || !Entity::isValid(marker)) {
                continue;
            }
            Entity::setActive(marker, buildingId == selectedId);
        }
    }

    private function createRallyMarker(): int {
        int id = Entity::create("RallyMarker");
        Entity::addComponent(id, "Decal");
        Decal::setShape(id, Decal::SHAPE_CIRCLE);
        Entity::setRotation(id, new Vec3f(90.0, 0.0, 0.0));
        Decal::setEdgeFalloff(id, 0.4);
        Decal::setSortPriority(id, 9);
        Decal::setColor(id, 1.0, 0.85, 0.2, 0.7);
        Decal::setHalfExtents(id, 1.5, 1.5, 4.0);
        Entity::setActive(id, false);
        return id;
    }

    // ---- production queue ----

    private function enqueue(int buildingId, string type): void {
        RTSHUDController? hud = this.hud();
        if (hud == null) {
            return;
        }
        if (this.queueCount >= this.maxQueue) {
            hud.pushAlertMessage("Production queue full", 1.5);
            return;
        }
        int cost = this.unitCost(type);
        if (!hud.trySpendGold(cost)) {
            hud.pushAlertMessage("Need " + parsePrimitive(cost) + " gold for " + type, 2.0);
            return;
        }
        float time = this.unitTime(type);
        this.queue[this.queueCount] = new QueueItem(buildingId, type, time);
        this.queueCount = this.queueCount + 1;
        hud.pushAlertMessage("Queued " + type, 1.5);
    }

    private function tickQueue(float dt): void {
        if (this.queueCount <= 0) {
            return;
        }
        QueueItem head = this.queue[0];
        // Building sold while its unit was training: drop the item (no refund).
        if (!Entity::isValid(head.buildingId)) {
            this.popQueue();
            return;
        }
        head.remaining = head.remaining - dt;
        if (head.remaining <= 0.0) {
            int building = head.buildingId;
            string type = head.unitType;
            this.popQueue();
            this.spawnUnit(building, type);
        }
    }

    private function popQueue(): void {
        for (int i = 1; i < this.queueCount; i = i + 1) {
            this.queue[i - 1] = this.queue[i];
        }
        this.queueCount = this.queueCount - 1;
    }

    // ---- unit spawning + movement ----

    private function spawnUnit(int buildingId, string type): void {
        string prefab = this.unitPrefab(type);
        int id = Entity::instantiate(prefab);
        if (id < 0) {
            Log::warn("[BuildingCommand] failed to spawn unit '" + type + "' (" + prefab + ")");
            return;
        }
        this.unitSerial = this.unitSerial + 1;
        Entity::setName(id, "Unit_" + parsePrimitive(this.unitSerial));

        Vec3f spawn = this.spawnPointNear(Entity::getPosition(buildingId));
        Entity::setPosition(id, spawn);
        Entity::setActive(id, true);

        // Make it a selectable player unit (UnitSelectionController + fog Vision).
        PluginComponent::add(id, "Selectable");
        PluginComponent::setBool(id, "Selectable", "canBeSelected", true);
        PluginComponent::add(id, "Team");
        PluginComponent::setInt(id, "Team", "teamId", 0);
        // Physics body so single-click picking (Picker "Dynamic") hits the unit.
        Physics::createBody(id);

        // Walk to the building's rally point if one is set.
        Vec3f? rally = this.rallyPoints.get(new Int(buildingId));
        if (rally != null) {
            this.moveTargets.put(new Int(id), rally);
        }
    }

    private function spawnPointNear(Vec3f bp): Vec3f {
        float ox = 6.0;
        float oz = 6.0;
        int k = this.unitSerial % 4;
        if (k == 1) { ox = -6.0; oz = 6.0; }
        if (k == 2) { ox = 6.0; oz = -6.0; }
        if (k == 3) { ox = -6.0; oz = -6.0; }
        float x = bp.x + ox;
        float z = bp.z + oz;
        return new Vec3f(x, Terrain::heightAt(x, z), z);
    }

    private function tickMovers(float dt): void {
        Int[] keys = this.moveTargets.getKeys();
        for (int i = 0; i < keys.length; i = i + 1) {
            int uid = keys[i].getValue();
            if (!Entity::isValid(uid)) {
                this.moveTargets.remove(keys[i]);
                continue;
            }
            // Positive narrowing into the then-branch: mType does not narrow a
            // variable across an `if (x == null) { continue; }` loop guard.
            Vec3f? target = this.moveTargets.get(keys[i]);
            if (target != null) {
                if (this.stepToward(uid, target, dt)) {
                    this.moveTargets.remove(keys[i]);
                }
            } else {
                this.moveTargets.remove(keys[i]);
            }
        }
    }

    // Straight-line step toward target on the XZ plane, riding the terrain
    // height. Returns true once arrived.
    private function stepToward(int id, Vec3f target, float dt): bool {
        Vec3f p = Entity::getPosition(id);
        float dx = target.x - p.x;
        float dz = target.z - p.z;
        float dist = new Vec3f(dx, 0.0, dz).length();
        float step = this.unitSpeed * dt;
        if (dist <= this.arriveEps || step >= dist) {
            Entity::setPosition(id, new Vec3f(target.x, Terrain::heightAt(target.x, target.z), target.z));
            return true;
        }
        float nx = p.x + dx / dist * step;
        float nz = p.z + dz / dist * step;
        Entity::setPosition(id, new Vec3f(nx, Terrain::heightAt(nx, nz), nz));
        return false;
    }

    // ---- harvesters (refinery Track) ----

    private function spawnHarvester(int refineryId): void {
        RTSHUDController? hud = this.hud();
        if (this.harvCount >= this.maxHarvesters) {
            if (hud != null) { hud.pushAlertMessage("Too many harvesters", 1.5); }
            return;
        }
        int node = this.nearestGoldNode(Entity::getPosition(refineryId));
        if (node < 0) {
            if (hud != null) { hud.pushAlertMessage("No GoldNode found on map", 2.0); }
            return;
        }
        int id = Entity::instantiate(this.unitPrefab("Harvester"));
        if (id < 0) {
            Log::warn("[BuildingCommand] failed to spawn harvester");
            return;
        }
        this.unitSerial = this.unitSerial + 1;
        Entity::setName(id, "Harvester_" + parsePrimitive(this.unitSerial));
        Vec3f home = this.spawnPointNear(Entity::getPosition(refineryId));
        Entity::setPosition(id, home);
        Entity::setActive(id, true);

        Vec3f minePos = Entity::getPosition(node);
        Vec3f mineGround = new Vec3f(minePos.x, Terrain::heightAt(minePos.x, minePos.z), minePos.z);
        this.harvesters[this.harvCount] = new Harvester(id, refineryId, mineGround, home);
        this.harvCount = this.harvCount + 1;

        if (hud != null) {
            hud.pushAlertMessage("Harvester dispatched", 1.5);
        }
    }

    private function tickHarvesters(float dt): void {
        int h = 0;
        while (h < this.harvCount) {
            Harvester harv = this.harvesters[h];
            if (!Entity::isValid(harv.unitId) || !Entity::isValid(harv.refineryId)) {
                if (Entity::isValid(harv.unitId)) { Entity::destroy(harv.unitId); }
                this.removeHarvester(h);
                continue;
            }
            if (harv.state == HState::TO_MINE) {
                if (this.stepToward(harv.unitId, harv.minePos, dt)) {
                    harv.state = HState::MINING;
                    harv.dwell = 1.0;
                }
            } else if (harv.state == HState::MINING) {
                harv.dwell = harv.dwell - dt;
                if (harv.dwell <= 0.0) {
                    harv.state = HState::TO_HOME;
                }
            } else if (harv.state == HState::TO_HOME) {
                if (this.stepToward(harv.unitId, harv.homePos, dt)) {
                    harv.state = HState::DEPOSIT;
                }
            } else {
                RTSHUDController? hud = this.hud();
                if (hud != null) {
                    hud.addGold(this.harvestDeposit);
                }
                harv.state = HState::TO_MINE;
            }
            h = h + 1;
        }
    }

    private function removeHarvester(int index): void {
        int last = this.harvCount - 1;
        this.harvesters[index] = this.harvesters[last];
        this.harvCount = last;
    }

    private function nearestGoldNode(Vec3f fromVec): int {
        int[] nodes = Entity::findAll("GoldNode");
        int best = -1;
        float bestSq = 0.0;
        for (int i = 0; i < nodes.length; i = i + 1) {
            Vec3f p = Entity::getPosition(nodes[i]);
            float dx = p.x - fromVec.x;
            float dz = p.z - fromVec.z;
            float d = dx * dx + dz * dz;
            if (best < 0 || d < bestSq) {
                best = nodes[i];
                bestSq = d;
            }
        }
        return best;
    }

    // ---- unit tables ----

    // Thin accessors over the unitDefs table (see defineUnits / unitDef).
    private function unitPrefab(string type): string {
        return this.unitDef(type).prefab;
    }

    private function unitCost(string type): int {
        return this.unitDef(type).cost;
    }

    private function unitTime(string type): float {
        return this.unitDef(type).buildTime;
    }

    private function iconForType(string type): string {
        return this.unitDef(type).icon;
    }

    // ---- queue HUD ----

    // Spawn the production-queue HUD once from a prefab under RTS_HUD_Canvas. The
    // slots are engine-pooled UIListView items (template = prod_slot_prefab), so no
    // per-slot entities are created here and nothing leaks into the saved scene.
    // Idempotent: if a HUD root already exists (e.g. saved during a play session)
    // it is reused instead of spawning a duplicate.
    private function setupQueueUI(): void {
        this.queueHudId = Entity::findByName("RTS_HUD_ProdQueueHUD");
        if (this.queueHudId < 0) {
            int canvasId = Entity::findByName("RTS_HUD_Canvas");
            if (canvasId < 0) {
                Log::warn("[BuildingCommand] RTS_HUD_Canvas missing; no queue HUD.");
                return;
            }
            this.queueHudId = Entity::instantiateChild("assets/ui/prefabs/prod_queue_hud_prefab.vfPrefab", canvasId);
        }
        if (this.queueHudId < 0) {
            Log::warn("[BuildingCommand] Failed to spawn prod queue HUD prefab.");
            return;
        }
        this.queueLabelId = Entity::findByName("RTS_HUD_ProdQueueLabel");
        this.queueListId = Entity::findByName("RTS_HUD_ProdQueueList");
        this.queueProgressId = Entity::findByName("RTS_HUD_ProdProgress");
        Entity::setActive(this.queueHudId, false);
    }

    private function updateQueueUI(): void {
        if (this.queueHudId < 0) {
            return;
        }
        if (this.queueCount <= 0) {
            this.hideQueueUI();
            return;
        }

        float[] bar = UI::getRectPixels(this.hudCommandBarId);
        if (bar.length < 5 || bar[0] < 0.5) {
            return;
        }
        float bx = bar[1];
        float by = bar[2];
        float bw = bar[3];

        float slotW = 56.0;
        float pad = 6.0;
        float panelW = (float)this.maxQueue * (slotW + pad) + pad;
        float panelH = slotW + 14.0;
        float px = bx + (bw - panelW) / 2.0;
        float py = by - panelH - 10.0;

        // This engine's screen-space UI is flat: child rects resolve against the
        // canvas, not their parent, so every element is positioned in viewport
        // pixels each frame. The list's UILayoutGroup then arranges the pooled
        // slot items within the list's own rect.
        Entity::setActive(this.queueHudId, true);
        UI::setRectPixels(this.queueHudId, px, py, panelW, panelH);

        if (this.queueLabelId >= 0) {
            UI::setRectPixels(this.queueLabelId, px + 4.0, py - 22.0, panelW, 20.0);
            UI::setLabelText(this.queueLabelId, "Producing: " + this.queue[0].unitType);
        }

        if (this.queueListId >= 0) {
            // Position the slot strip; the layout group lays slots out left-to-right.
            UI::setRectPixels(this.queueListId, px + pad, py + 6.0, panelW - pad * 2.0, slotW);
            // Reconciles synchronously: getListItem(i) is valid this same frame.
            UI::setListItemCount(this.queueListId, this.queueCount);
            for (int i = 0; i < this.queueCount; i = i + 1) {
                int item = UI::getListItem(this.queueListId, i);
                if (item < 0) {
                    continue;
                }
                UI::setImageTexture(item, this.iconForType(this.queue[i].unitType));
                UI::setImageColor(item, 1.0, 1.0, 1.0, 1.0);
            }
        }

        // Single progress bar over the head slot (only the head is building).
        if (this.queueProgressId >= 0) {
            float frac = 0.0;
            QueueItem head = this.queue[0];
            if (head.total > 0.0) {
                frac = 1.0 - head.remaining / head.total;
            }
            if (frac < 0.0) { frac = 0.0; }
            if (frac > 1.0) { frac = 1.0; }
            Entity::setActive(this.queueProgressId, true);
            UI::setRectPixels(this.queueProgressId, px + pad, py + 6.0 + slotW - 5.0, slotW * frac, 4.0);
        }
    }

    private function hideQueueUI(): void {
        if (this.queueHudId >= 0) { Entity::setActive(this.queueHudId, false); }
        if (this.queueListId >= 0) { UI::setListItemCount(this.queueListId, 0); }
    }

    // ---- script resolution ----

    private function cmdIndexFor(int buttonEntityId): int {
        for (int i = 0; i < 5; i = i + 1) {
            if (this.cmdButtons[i] >= 0 && this.cmdButtons[i] == buttonEntityId) {
                return i;
            }
        }
        return -1;
    }

    private function hud(): RTSHUDController? {
        if (this.hudRef == null && this.hudControllerId >= 0) {
            this.hudRef = Entity::getScript<RTSHUDController>(this.hudControllerId, "RTSHUDController");
        }
        return this.hudRef;
    }

    private function selection(): SelectionController? {
        return Entity::getScript<SelectionController>(Entity::self(), "SelectionController");
    }

    private function placement(): BuildingPlacementController? {
        return Entity::getScript<BuildingPlacementController>(Entity::self(), "BuildingPlacementController");
    }
}
