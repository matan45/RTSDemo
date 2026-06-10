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

import * from "../lib/engine/Entity.mt";
import * from "../lib/engine/Input.mt";
import * from "../lib/engine/Mouse.mt";
import * from "../lib/engine/UI.mt";
import * from "../lib/engine/Picker.mt";
import * from "../lib/engine/RaycastHit.mt";
import * from "../lib/engine/Terrain.mt";
import * from "../lib/engine/Physics.mt";
import * from "../lib/engine/Decal.mt";
import * from "../lib/engine/Log.mt";
import * from "../lib/engine/PluginComponent.mt";
import * from "../lib/engine/IUIButtonListener.mt";
import * from "../lib/core/collections/HashMap.mt";
import * from "../lib/core/primitives/Int.mt";
import * from "../lib/math/Vec3f.mt";
import * from "./RTSHUDController.mt";
import * from "./SelectionController.mt";
import * from "./BuildingPlacementController.mt";
import * from "./BuildingInfo.mt";

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

    // Production queue (FIFO, parallel arrays; head = index 0).
    private int maxQueue;
    private int[] queueBuilding;
    private string[] queueType;
    private float[] queueRemaining;
    private float[] queueTotal;
    private int queueCount;

    // Active harvesters (parallel arrays). state: 0 to-mine, 1 mining,
    // 2 to-home, 3 deposit.
    private int maxHarvesters;
    private int[] harvId;
    private int[] harvRefinery;
    private Vec3f[] harvMine;
    private Vec3f[] harvHome;
    private int[] harvState;
    private float[] harvDwell;
    private int harvCount;

    // Queue HUD (created at runtime under RTS_HUD_Canvas, positioned above the
    // command bar each frame while non-empty).
    private int queuePanelId;
    private int queueLabelId;
    private int queueProgressId;
    private int[] queueSlotIds;
    private int hudCommandBarId;

    private bool prevLeftDown;
    private int unitSerial;

    private float unitSpeed;
    private float arriveEps;

    constructor() {
        this.hudControllerId = -1;
        this.hudRef = null;
        this.pendingRallyBuilding = -1;
        this.queueCount = 0;
        this.harvCount = 0;
        this.maxQueue = 8;
        this.maxHarvesters = 16;
        this.queuePanelId = -1;
        this.queueLabelId = -1;
        this.queueProgressId = -1;
        this.hudCommandBarId = -1;
        this.prevLeftDown = false;
        this.unitSerial = 0;
        this.unitSpeed = 8.0;
        this.arriveEps = 0.4;
    }

    public function onStart(): void {
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

        this.queueBuilding = new int[this.maxQueue];
        this.queueType = new string[this.maxQueue];
        this.queueRemaining = new float[this.maxQueue];
        this.queueTotal = new float[this.maxQueue];

        this.harvId = new int[this.maxHarvesters];
        this.harvRefinery = new int[this.maxHarvesters];
        this.harvMine = new Vec3f[this.maxHarvesters];
        this.harvHome = new Vec3f[this.maxHarvesters];
        this.harvState = new int[this.maxHarvesters];
        this.harvDwell = new float[this.maxHarvesters];

        this.setupQueueUI();
        Log::info("[BuildingCommand] ready.");
    }

    public function onUpdate(float deltaTime): void {
        this.handleRallyClick();
        this.tickQueue(deltaTime);
        this.tickMovers(deltaTime);
        this.tickHarvesters(deltaTime);
        this.updateQueueUI();
    }

    public function onDestroy(): void {
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
        int refund = (info.cost * 70) / 100;
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
        int upCost = (info.cost * 60) / 100;
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
        bool nowLeft = Input::isMouseButtonDown(Mouse::LEFT);
        bool leftReleased = this.prevLeftDown && !nowLeft;
        this.prevLeftDown = nowLeft;

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
        if (existing != null && Entity::isValid(existing.getValue())) {
            Entity::destroy(existing.getValue());
        }
        this.rallyMarkers.remove(key);
        this.rallyPoints.remove(key);
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
        this.queueBuilding[this.queueCount] = buildingId;
        this.queueType[this.queueCount] = type;
        this.queueRemaining[this.queueCount] = time;
        this.queueTotal[this.queueCount] = time;
        this.queueCount = this.queueCount + 1;
        hud.pushAlertMessage("Queued " + type, 1.5);
    }

    private function tickQueue(float dt): void {
        if (this.queueCount <= 0) {
            return;
        }
        int building = this.queueBuilding[0];
        // Building sold while its unit was training: drop the item (no refund).
        if (!Entity::isValid(building)) {
            this.popQueue();
            return;
        }
        this.queueRemaining[0] = this.queueRemaining[0] - dt;
        if (this.queueRemaining[0] <= 0.0) {
            string type = this.queueType[0];
            this.popQueue();
            this.spawnUnit(building, type);
        }
    }

    private function popQueue(): void {
        for (int i = 1; i < this.queueCount; i = i + 1) {
            this.queueBuilding[i - 1] = this.queueBuilding[i];
            this.queueType[i - 1] = this.queueType[i];
            this.queueRemaining[i - 1] = this.queueRemaining[i];
            this.queueTotal[i - 1] = this.queueTotal[i];
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
            Vec3f? target = this.moveTargets.get(keys[i]);
            if (target == null) {
                this.moveTargets.remove(keys[i]);
                continue;
            }
            if (this.stepToward(uid, target, dt)) {
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
        this.harvId[this.harvCount] = id;
        this.harvRefinery[this.harvCount] = refineryId;
        this.harvMine[this.harvCount] = new Vec3f(minePos.x, Terrain::heightAt(minePos.x, minePos.z), minePos.z);
        this.harvHome[this.harvCount] = home;
        this.harvState[this.harvCount] = 0;
        this.harvDwell[this.harvCount] = 0.0;
        this.harvCount = this.harvCount + 1;

        if (hud != null) {
            hud.pushAlertMessage("Harvester dispatched", 1.5);
        }
    }

    private function tickHarvesters(float dt): void {
        int h = 0;
        while (h < this.harvCount) {
            int uid = this.harvId[h];
            if (!Entity::isValid(uid) || !Entity::isValid(this.harvRefinery[h])) {
                if (Entity::isValid(uid)) { Entity::destroy(uid); }
                this.removeHarvester(h);
                continue;
            }
            int state = this.harvState[h];
            if (state == 0) {
                if (this.stepToward(uid, this.harvMine[h], dt)) {
                    this.harvState[h] = 1;
                    this.harvDwell[h] = 1.0;
                }
            } else if (state == 1) {
                this.harvDwell[h] = this.harvDwell[h] - dt;
                if (this.harvDwell[h] <= 0.0) {
                    this.harvState[h] = 2;
                }
            } else if (state == 2) {
                if (this.stepToward(uid, this.harvHome[h], dt)) {
                    this.harvState[h] = 3;
                }
            } else {
                RTSHUDController? hud = this.hud();
                if (hud != null) {
                    hud.addGold(10);
                }
                this.harvState[h] = 0;
            }
            h = h + 1;
        }
    }

    private function removeHarvester(int index): void {
        int last = this.harvCount - 1;
        this.harvId[index] = this.harvId[last];
        this.harvRefinery[index] = this.harvRefinery[last];
        this.harvMine[index] = this.harvMine[last];
        this.harvHome[index] = this.harvHome[last];
        this.harvState[index] = this.harvState[last];
        this.harvDwell[index] = this.harvDwell[last];
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

    private function unitPrefab(string type): string {
        if (type == "Soldier") { return "assets/units/soldier_prefab.vfPrefab"; }
        if (type == "Engineer") { return "assets/units/engineer_prefab.vfPrefab"; }
        if (type == "Tank") { return "assets/units/tank_prefab.vfPrefab"; }
        return "assets/units/harvester_prefab.vfPrefab";
    }

    private function unitCost(string type): int {
        if (type == "Soldier") { return 25; }
        if (type == "Engineer") { return 40; }
        if (type == "Tank") { return 75; }
        return 30;
    }

    private function unitTime(string type): float {
        if (type == "Soldier") { return 3.0; }
        if (type == "Engineer") { return 5.0; }
        if (type == "Tank") { return 8.0; }
        return 4.0;
    }

    private function iconForType(string type): string {
        if (type == "Soldier") { return "assets/ui/icons/barracks.vfImage"; }
        if (type == "Engineer") { return "assets/ui/icons/commandcenter.vfImage"; }
        if (type == "Tank") { return "assets/ui/icons/factory.vfImage"; }
        return "assets/ui/icons/refinery.vfImage";
    }

    // ---- queue HUD ----

    private function setupQueueUI(): void {
        int canvasId = Entity::findByName("RTS_HUD_Canvas");

        this.queuePanelId = this.makeUIImage("RTS_HUD_ProdQueuePanel", canvasId);
        if (this.queuePanelId >= 0) {
            UI::setImageColor(this.queuePanelId, 0.03, 0.04, 0.03, 0.85);
            Entity::setActive(this.queuePanelId, false);
        }

        this.queueLabelId = this.makeUILabel("RTS_HUD_ProdQueueLabel", canvasId);
        if (this.queueLabelId >= 0) {
            UI::setLabelFont(this.queueLabelId, "assets/Roboto-Regular.vfFont");
            UI::setLabelFontSize(this.queueLabelId, 18.0);
            UI::setLabelColor(this.queueLabelId, 1.0, 0.9, 0.5, 1.0);
            UI::setLabelStyle(this.queueLabelId, UI::LABEL_STYLE_BOLD);
            UI::setLabelAlignment(this.queueLabelId, UI::LABEL_ALIGN_LEFT, UI::LABEL_VALIGN_MIDDLE);
            UI::setLabelOverflow(this.queueLabelId, UI::LABEL_CLIP);
            Entity::setActive(this.queueLabelId, false);
        }

        this.queueSlotIds = new int[this.maxQueue];
        for (int i = 0; i < this.maxQueue; i = i + 1) {
            int slot = this.makeUIImage("RTS_HUD_ProdSlot_" + i, canvasId);
            this.queueSlotIds[i] = slot;
            if (slot >= 0) {
                Entity::setActive(slot, false);
            }
        }

        this.queueProgressId = this.makeUIImage("RTS_HUD_ProdProgress", canvasId);
        if (this.queueProgressId >= 0) {
            UI::setImageColor(this.queueProgressId, 0.3, 1.0, 0.45, 0.95);
            Entity::setActive(this.queueProgressId, false);
        }
    }

    private function makeUIImage(string name, int parentId): int {
        int id = -1;
        if (parentId >= 0) {
            id = Entity::createChild(name, parentId);
        } else {
            id = Entity::create(name);
        }
        if (id >= 0) {
            Entity::addComponent(id, "UIRect");
            Entity::addComponent(id, "UIImage");
        }
        return id;
    }

    private function makeUILabel(string name, int parentId): int {
        int id = -1;
        if (parentId >= 0) {
            id = Entity::createChild(name, parentId);
        } else {
            id = Entity::create(name);
        }
        if (id >= 0) {
            Entity::addComponent(id, "UIRect");
            Entity::addComponent(id, "UILabel");
        }
        return id;
    }

    private function updateQueueUI(): void {
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

        if (this.queuePanelId >= 0) {
            Entity::setActive(this.queuePanelId, true);
            UI::setRectPixels(this.queuePanelId, px, py, panelW, panelH);
        }
        if (this.queueLabelId >= 0) {
            Entity::setActive(this.queueLabelId, true);
            UI::setRectPixels(this.queueLabelId, px + 4.0, py - 22.0, panelW, 20.0);
            UI::setLabelText(this.queueLabelId, "Producing: " + this.queueType[0]);
        }

        for (int i = 0; i < this.maxQueue; i = i + 1) {
            int slot = this.queueSlotIds[i];
            if (slot < 0) {
                continue;
            }
            if (i < this.queueCount) {
                Entity::setActive(slot, true);
                UI::setImageTexture(slot, this.iconForType(this.queueType[i]));
                UI::setImageColor(slot, 1.0, 1.0, 1.0, 1.0);
                float sx = px + pad + (float)i * (slotW + pad);
                UI::setRectPixels(slot, sx, py + 6.0, slotW, slotW);
            } else {
                Entity::setActive(slot, false);
            }
        }

        if (this.queueProgressId >= 0) {
            float frac = 0.0;
            if (this.queueTotal[0] > 0.0) {
                frac = 1.0 - this.queueRemaining[0] / this.queueTotal[0];
            }
            if (frac < 0.0) { frac = 0.0; }
            if (frac > 1.0) { frac = 1.0; }
            Entity::setActive(this.queueProgressId, true);
            UI::setRectPixels(this.queueProgressId, px + pad, py + 6.0 + slotW - 5.0, slotW * frac, 4.0);
        }
    }

    private function hideQueueUI(): void {
        if (this.queuePanelId >= 0) { Entity::setActive(this.queuePanelId, false); }
        if (this.queueLabelId >= 0) { Entity::setActive(this.queueLabelId, false); }
        if (this.queueProgressId >= 0) { Entity::setActive(this.queueProgressId, false); }
        for (int i = 0; i < this.maxQueue; i = i + 1) {
            if (this.queueSlotIds[i] >= 0) {
                Entity::setActive(this.queueSlotIds[i], false);
            }
        }
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
