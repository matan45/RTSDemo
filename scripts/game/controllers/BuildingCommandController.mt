// BuildingCommandController - executes the per-building command card (VK-1352)
// and the world move/gather orders it produces (VK-1303).
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
//   Soldier / Engineer / Tank / Track - queue a unit (gold + build time); the
//              unit spawns when the queue head finishes.
//
// Units are placeholder prefabs (assets/units/*_prefab.vfPrefab) reusing an
// imported mesh until real unit art lands; they get Selectable + Team(0) +
// a physics body (UnitSelectionController selection) + a NavmeshAgent so they
// pathfind on the baked navmesh. A world right-click on the ground issues one
// generic Navmesh group-destination order for the movable selected units; the
// minimap right-click move uses the same route without harvest-node gathering.
//
// Attach this @Script to GameSystems alongside SelectionController /
// BuildingPlacementController / UnitSelectionController.

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Mouse.mt";
import * from "../../lib/engine/UI.mt";
import * from "../../lib/engine/Picker.mt";
import * from "../../lib/engine/RaycastHit.mt";
import * from "../../lib/engine/ScreenPoint.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Blackboard.mt";
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
import * from "./UnitSelectionController.mt";
import * from "./SoldierCombatController.mt";
import * from "../ai/PatrolDemo.mt";
import * from "../ai/EnemyGuards.mt";
import * from "../ai/EnemyBases.mt";
import * from "../data/BuildingInfo.mt";
import * from "../data/UnitDef.mt";
import * from "../data/UnitInfo.mt";
import * from "../data/QueueItem.mt";
import * from "../util/Config.mt";
import * from "../util/InputEdge.mt";

@Script
class BuildingCommandController extends Behaviour implements IUIButtonListener {
    private int hudControllerId;
    private RTSHUDController? hudRef;

    // Command-card buttons in the same display order RTSHUDController uses.
    private int[] cmdButtons;

    // Rally: building entity id -> rally Vec3f, plus a reusable ground marker.
    private HashMap<Int, Vec3f?> rallyPoints;
    private HashMap<Int, Int?> rallyMarkers;
    private int pendingRallyBuilding;

    // Per-building production queues. Stored interleaved in one FIFO array -- each
    // QueueItem carries its buildingId and array order preserves each building's
    // own order. Buildings produce IN PARALLEL: tickQueue advances the head (first
    // queued item) of every building each frame. maxQueue caps items PER building;
    // queueCap is the backing array capacity across all buildings.
    private int maxQueue;
    private int queueCap;
    private QueueItem[] queue;
    private int queueCount;

    // Active Track harvesters. A Track spawns with no behavior tree; right-clicking
    // a gold node attaches the per-Track HarvesterLoop tree (VK-1447) and a ground
    // move cancels it. trackHomes holds each Track's refinery drop-off so a gather
    // order can seed the tree's homePos.
    private HashMap<Int, Vec3f?> trackHomes;

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
    private InputEdge rightEdge;
    private int unitSerial;

    // Max agent speed applied to each spawned unit's NavmeshAgent.
    private float unitSpeed;

    // Attack component tuning for combat units (Soldier/Tank). range matches
    // SoldierCombatController.fireRange so the data-driven attack agrees with the
    // soldier's stop-and-fire distance; cooldown is the min seconds between shots.
    private float unitAttackRange;
    private float unitAttackCooldown;

    // Gameplay tuning.
    private int sellRefundPct;
    private int upgradeCostPct;
    private float harvestDeposit;
    // Screen-space pixel radius for right-click enemy targeting (pickEnemy).
    private float attackPickRadius;
    // World spacing between formation slots when a multi-select move spreads units
    // over a grid (a bit more than the agent diameter, radius 0.6 in the prefab, so
    // the crowd never has to pack many agents onto one point).
    private float moveFormationSpacing;

    // VK-1446/1447 AI showcase, bootstrapped from onStart so it needs no extra scene
    // wiring. Remove these fields + their setup/update calls to drop the demo.
    private PatrolDemo patrolDemo;
    private EnemyGuards enemyGuards;
    // VK-1589: enemy command structures + their World-Sector streaming sources. Same
    // bootstrap-from-onStart shape; also needs teardown() so the sources do not survive
    // a play-stop or a script reload. Nullable, unlike the two above, precisely because
    // onDestroy must be able to run on a script that never reached onStart.
    private EnemyBases? enemyBases;

    public constructor() : super() {
        this.hudControllerId = -1;
        this.hudRef = null;
        this.enemyBases = null;
        this.pendingRallyBuilding = -1;
        this.queueCount = 0;
        this.maxQueue = 8;
        this.queueCap = 64;
        this.queueHudId = -1;
        this.queueLabelId = -1;
        this.queueListId = -1;
        this.queueProgressId = -1;
        this.hudCommandBarId = -1;
        this.unitSerial = 0;
        this.unitSpeed = 8.0;
        this.unitAttackRange = 14.0;
        this.unitAttackCooldown = 1.0;
        this.sellRefundPct = 70;
        this.upgradeCostPct = 60;
        this.harvestDeposit = 10.0;
        this.attackPickRadius = 40.0;
        this.moveFormationSpacing = 2.0;
    }

    public function onStart(): void {
        this.leftEdge = new InputEdge();
        this.rightEdge = new InputEdge();
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

        this.queue = new QueueItem[this.queueCap];
        this.trackHomes = new HashMap<Int, Vec3f>();

        this.defineUnits();
        this.setupQueueUI();

        // VK-1446/1447 AI showcase (patrol route + scene enemy guards).
        this.patrolDemo = new PatrolDemo();
        this.patrolDemo.setup();
        this.enemyGuards = new EnemyGuards();
        this.enemyGuards.setup();

        // VK-1589 (after the guards, so the bases spawn onto settled terrain height).
        this.enemyBases = new EnemyBases();
        this.enemyBases.setup();

        Log::info("[BuildingCommand] ready.");
    }

    // Unit table (single source of cost / build time / prefab / icon). The
    // Track entry (index 3) also serves as the default for unknown types.
    private function defineUnits(): void {
        // UnitDef(type, cost, buildTime, prefab, icon, maxHealth, damage). damage
        // > 0 = combat unit -> gets an Attack component at spawn; 0.0 = non-combat
        // (Engineer, Track) gets Health only. Soldier 10 matches the
        // SoldierCombatController default; Tank hits harder.
        this.unitDefs = new UnitDef[4];
        this.unitDefs[0] = new UnitDef("Soldier", 25, 3.0, "assets/units/soldier_prefab.vfPrefab", "assets/ui/icons/units/soldier.vfImage", 60.0, 10.0);
        this.unitDefs[1] = new UnitDef("Engineer", 40, 5.0, "assets/units/engineer_prefab.vfPrefab", "assets/ui/icons/units/engineer.vfImage", 50.0, 0.0);
        this.unitDefs[2] = new UnitDef("Tank", 75, 8.0, "assets/units/tank_prefab.vfPrefab", "assets/ui/icons/units/tank.vfImage", 200.0, 25.0);
        this.unitDefs[3] = new UnitDef("Track", 30, 4.0, "assets/units/track/track_prefab.vfPrefab", "assets/ui/icons/units/track.vfImage", 120.0, 0.0);
    }

    // Look up a unit definition by type; falls back to the Track entry for
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
        this.handleMoveCommand();
        this.updateQueueUI();
        this.patrolDemo.update(deltaTime);

        // Narrow a local - mType field-narrowing across a call is unreliable.
        EnemyBases? bases = this.enemyBases;
        if (bases != null) {
            bases.update();
        }
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

        // VK-1589: release the base streaming sources. onDestroy fires on play-stop and on
        // script reload; neither deletes the base entities, so the engine's owner-UUID hook
        // would not fire for them.
        EnemyBases? bases = this.enemyBases;
        if (bases != null) {
            bases.teardown();
        }
        this.enemyBases = null;
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
        if (cmd == "Track") { this.enqueue(buildingId, "Track"); return; }
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
        // Mirror the boost onto the live plugin Health component (the HUD bar's
        // source of truth) so the upgrade restores it to a full, larger pool. Falls
        // back to the info fields above when the building has no Health component.
        if (info.entityId >= 0 && PluginComponent::has(info.entityId, "Health")) {
            float newMax = PluginComponent::getFloat(info.entityId, "Health", "maxHP") * 1.5;
            PluginComponent::setFloat(info.entityId, "Health", "maxHP", newMax);
            PluginComponent::setFloat(info.entityId, "Health", "currentHP", newMax);
        }
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
            int marker = markerBox.getValue();
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
        if (this.buildingQueueCount(buildingId) >= this.maxQueue || this.queueCount >= this.queueCap) {
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
        // Drop items whose building was sold mid-production (no refund).
        int i = 0;
        while (i < this.queueCount) {
            if (!Entity::isValid(this.queue[i].buildingId)) {
                this.removeAt(i);
            } else {
                i = i + 1;
            }
        }
        // Parallel production: tick only the head (first queued item) of each
        // building this frame. Two passes -- tick all heads first, then process
        // finished ones -- so popping a completed head never double-ticks the
        // next item of that building in the same frame.
        for (int h = 0; h < this.queueCount; h = h + 1) {
            if (this.isHeadIndex(h)) {
                this.queue[h].remaining = this.queue[h].remaining - dt;
            }
        }
        // Removal shifts the array, so rescan from the start after each spawn.
        bool again = true;
        while (again) {
            again = false;
            for (int j = 0; j < this.queueCount; j = j + 1) {
                if (this.isHeadIndex(j) && this.queue[j].remaining <= 0.0) {
                    int building = this.queue[j].buildingId;
                    string type = this.queue[j].unitType;
                    this.removeAt(j);
                    this.spawnUnit(building, type);
                    again = true;
                    break;
                }
            }
        }
    }

    // The head item for a building is its first queued item -- no earlier item in
    // the array shares its buildingId. That head is the one currently building.
    private function isHeadIndex(int idx): bool {
        int b = this.queue[idx].buildingId;
        for (int i = 0; i < idx; i = i + 1) {
            if (this.queue[i].buildingId == b) {
                return false;
            }
        }
        return true;
    }

    // Remove the item at idx and shift the tail down (generalised popQueue).
    private function removeAt(int idx): void {
        for (int i = idx + 1; i < this.queueCount; i = i + 1) {
            this.queue[i - 1] = this.queue[i];
        }
        this.queueCount = this.queueCount - 1;
    }

    // Number of queued items owned by a building (its per-building queue length).
    private function buildingQueueCount(int id): int {
        int n = 0;
        for (int i = 0; i < this.queueCount; i = i + 1) {
            if (this.queue[i].buildingId == id) {
                n = n + 1;
            }
        }
        return n;
    }

    // Array index of a building's head item, or -1 if it has none queued.
    private function buildingHeadIndex(int id): int {
        for (int i = 0; i < this.queueCount; i = i + 1) {
            if (this.queue[i].buildingId == id) {
                return i;
            }
        }
        return -1;
    }

    // ---- unit spawning + movement ----

    private function spawnUnit(int buildingId, string type): void {
        string prefab = this.unitPrefab(type);
        int id = Entity::instantiate(prefab);
        if (id < 0) {
            // Spawn failed (e.g. the prefab is missing): refund the gold that
            // enqueue() spent up front so the player isn't silently charged for
            // a unit that never appears.
            Log::warn("[BuildingCommand] failed to spawn unit '" + type + "' (" + prefab + ")");
            RTSHUDController? hud = this.hud();
            if (hud != null) {
                hud.addGold(this.unitCost(type));
                hud.pushAlertMessage("Could not build " + type + " (refunded)", 2.0);
            }
            return;
        }
        this.unitSerial = this.unitSerial + 1;
        Entity::setName(id, "Unit_" + parsePrimitive(this.unitSerial));

        Vec3f spawn = this.spawnPointNear(Entity::getPosition(buildingId));
        Entity::setPosition(id, spawn);
        Entity::setActive(id, true);

        UnitDef def = this.unitDef(type);

        // Make it a selectable player unit (UnitSelectionController + fog Vision).
        PluginComponent::add(id, "Selectable");
        PluginComponent::setBool(id, "Selectable", "canBeSelected", true);
        PluginComponent::add(id, "Team");
        PluginComponent::setInt(id, "Team", "teamId", 0);

        // Runtime-add the RTSGameplay Health component to every unit (HUD health
        // bar + Combat::applyDamage target). maxHP from the unit's def; currentHP
        // starts full.
        PluginComponent::add(id, "Health");
        PluginComponent::setFloat(id, "Health", "maxHP", def.maxHealth);
        PluginComponent::setFloat(id, "Health", "currentHP", def.maxHealth);

        // Combat-capable units (damage > 0: Soldier, Tank) also get an Attack
        // component so SoldierCombatController can drive its damage from data
        // and future logic can read range/cooldown. Non-combat units (Engineer,
        // Track) carry Health only.
        if (def.damage > 0.0) {
            PluginComponent::add(id, "Attack");
            PluginComponent::setFloat(id, "Attack", "damage", def.damage);
            PluginComponent::setFloat(id, "Attack", "range", this.unitAttackRange);
            PluginComponent::setFloat(id, "Attack", "cooldown", this.unitAttackCooldown);
            PluginComponent::setFloat(id, "Attack", "lastAttackTime", 0.0);
        }
        // The unit's NavmeshAgent comes from its prefab (track_prefab carries one
        // sized to the vehicle) -- it pathfinds + avoids on the baked navmesh and
        // the agent owns movement + facing. No runtime physics body is created: it
        // would fight the agent (a static body won't follow it, a dynamic one
        // falls), and selection is screen-space (UnitSelectionController.pickUnit),
        // so no collider body is needed. setSpeed applies the controller's speed
        // (and persists onto the agent component before crowd registration).
        Navmesh::setSpeed(id, this.unitSpeed);

        // Register the unit's selection-panel info (icon + health) so the HUD can
        // show it when the unit is selected. Routed through UnitSelectionController
        // -> SelectionController (the HUD's single selection source); see UnitInfo.
        UnitSelectionController? usel = this.unitSelection();
        if (usel != null) {
            UnitInfo ui = new UnitInfo(def.unitType, def.icon, Config::TEAM_PLAYER, def.maxHealth);
            // Bind the panel info to this entity so its health bar reads the live
            // plugin Health component (currentHP/maxHP) -- one source of truth, so
            // Combat::applyDamage shows up on the bar.
            ui.entityId = id;
            usel.registerUnit(id, ui);
        }

        // The Track is a harvester, but it spawns IDLE -- it only starts the
        // refinery <-> gold-node loop once the player right-clicks a gold node
        // (so no rally move here). Other unit types just walk to the rally point.
        if (type == "Track") {
            this.trackHomes.put(new Int(id), spawn);
            return;
        }

        // Pathfind to the building's rally point if one is set.
        Vec3f? rally = this.rallyPoints.get(new Int(buildingId));
        if (rally != null) {
            Navmesh::moveTo(id, rally);
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

    // ---- world move command ----

    // Right-click on open ground issues one generic Navmesh group-destination
    // order for selected player units (the "Selected" marker is written by
    // UnitSelectionController). Suppressed
    // while placing a building / capturing a rally click (right-click cancels
    // placement there) and while the pointer is over UI (which also covers the
    // minimap, so its own right-click move never double-fires).
    private function handleMoveCommand(): void {
        this.rightEdge.step(Input::isMouseButtonDown(Mouse::RIGHT));
        if (!this.rightEdge.wasReleased) {
            return;
        }
        if (this.pendingRallyBuilding >= 0) {
            return;
        }
        SelectionController? sel = this.selection();
        if (sel != null && sel.isPlacementActive()) {
            return;
        }
        if (UI::isPointerOverUI()) {
            return;
        }
        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();

        // Right-click on an enemy unit/building is an ATTACK order for soldiers:
        // each selected SoldierCombatController locks onto the target (chase +
        // stop-and-fire). Non-combat units fall back to moving to the target's
        // position. pickEnemy mirrors UnitSelectionController.pickUnit (physics
        // pick first, then screen-space proximity) since units carry no runtime
        // collider; a miss falls through to the ground-move path below.
        int target = this.pickEnemy(mx, my);
        if (target >= 0) {
            int[] selUnits = PluginComponent::findAll("Selected");
            for (int i = 0; i < selUnits.length; i = i + 1) {
                int uid = selUnits[i];
                if (!Entity::isValid(uid)) {
                    continue;
                }
                SoldierCombatController? sc =
                    Entity::getScript<SoldierCombatController>(uid, "SoldierCombatController");
                if (sc != null) {
                    sc.setTarget(target);
                } else {
                    Navmesh::moveTo(uid, Entity::getPosition(target));
                }
            }
            return;
        }

        RaycastHit hit = Picker::pickTerrainPhysics(mx, my);
        if (!hit.hit) {
            return;
        }
        Vec3f dest = new Vec3f(hit.point.x, Terrain::heightAt(hit.point.x, hit.point.z), hit.point.z);

        this.issueSelectedGroundMove(dest);
    }

    public function issueSelectedGroundMove(Vec3f dest): void {
        this.issueSelectedMove(dest, true);
    }

    public function issueSelectedMinimapMove(Vec3f dest): void {
        this.issueSelectedMove(dest, false);
    }

    private function issueSelectedMove(Vec3f dest, bool allowGather): void {
        // Right-click on (or near) a gold mine is a "gather that node" order for
        // harvesters; anywhere else is a plain move.
        int goldNode = -1;
        if (allowGather) {
            goldNode = this.goldNodeNear(dest, 6.0);
        }

        int[] selected = PluginComponent::findAll("Selected");
        int[] moveIdsScratch = new int[selected.length];
        int moveCount = 0;

        for (int i = 0; i < selected.length; i = i + 1) {
            int uid = selected[i];
            if (!Entity::isValid(uid)) {
                continue;
            }
            // A ground move cancels any standing attack order on a soldier so it
            // reverts to move/idle (no-op for non-soldier units).
            SoldierCombatController? scc =
                Entity::getScript<SoldierCombatController>(uid, "SoldierCombatController");
            if (scc != null) {
                scc.setTarget(-1);
            }
            Vec3f? home = this.trackHomes.get(new Int(uid));
            if (home != null) {
                if (goldNode >= 0) {
                    // Gather order: (re)attach a fresh HarvesterLoop tree and point
                    // it at the clicked node. The tree now owns gather movement.
                    Vec3f mp = Entity::getPosition(goldNode);
                    Vec3f mine = new Vec3f(mp.x, Terrain::heightAt(mp.x, mp.z), mp.z);
                    this.startHarvest(uid, mine, home);
                } else {
                    // Move order CANCELS gathering: stop+detach the tree FIRST so it
                    // never races the manual move for the Track's NavmeshAgent.
                    this.stopHarvest(uid);
                    moveIdsScratch[moveCount] = uid;
                    moveCount = moveCount + 1;
                }
            } else {
                moveIdsScratch[moveCount] = uid;
                moveCount = moveCount + 1;
            }
        }

        if (moveCount <= 0) {
            return;
        }

        int[] moveIds = new int[moveCount];
        for (int j = 0; j < moveCount; j = j + 1) {
            moveIds[j] = moveIdsScratch[j];
        }

        Navmesh::setGroupDestination(moveIds, dest, this.moveFormationSpacing, Navmesh::FORMATION_GRID);
    }

    // True if the entity belongs to a non-player team (an attackable enemy).
    // Entities without a Team plugin component (terrain, gold nodes) are not
    // enemies, so a pick that lands on them falls through to a move.
    private function isEnemy(int id): bool {
        if (!Entity::isValid(id)) {
            return false;
        }
        if (!PluginComponent::has(id, "Team")) {
            return false;
        }
        return PluginComponent::getInt(id, "Team", "teamId") != Config::TEAM_PLAYER;
    }

    // Enemy unit/building under the cursor, or -1. Physics pick first (enemy
    // buildings may have a static collider), then a screen-space proximity scan
    // over every non-player Team entity (units carry no runtime collider, so a
    // raw physics pick would miss them -- same hybrid as pickUnit).
    private function pickEnemy(float mx, float my): int {
        RaycastHit e = Picker::pickEntity(mx, my, "Dynamic,Static");
        if (e.hit && this.isEnemy(e.entityId)) {
            return e.entityId;
        }

        int best = -1;
        float bestSq = this.attackPickRadius * this.attackPickRadius;
        int[] ids = PluginComponent::findAll("Team");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id) || !Entity::isActive(id)) {
                continue;
            }
            if (!this.isEnemy(id)) {
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

    // ---- harvesters (Track loop: refinery <-> commanded GoldNode) ----
    //
    // The Track gather loop is now a per-Track behavior tree
    // (assets/ai/HarvesterLoop.vfBehaviorTree, VK-1447): mine -> gather -> home ->
    // deposit, owned entirely by the tree's own blackboard. A Track spawns with no
    // tree (idle); a right-click on a gold node attaches a fresh tree seeded with
    // that node + the Track's home; a ground move detaches it. Two Tracks share the
    // one asset but carry independent per-entity blackboards.

    // (Re)start gathering: attach a fresh HarvesterLoop tree, seed the per-unit
    // blackboard, and enable it. Detach first so a re-gather restarts cleanly at the
    // mine leg rather than resuming a mid-loop sequence.
    private function startHarvest(int uid, Vec3f mine, Vec3f home): void {
        Blackboard::detachTree(uid);
        bool ok = Blackboard::attachTree(uid, "assets/ai/HarvesterLoop.vfBehaviorTree");
        if (!ok) {
            Navmesh::moveTo(uid, mine);   // fallback: at least walk to the node
            return;
        }
        Blackboard::setVec3(uid, "minePos", mine.x, mine.y, mine.z);
        Blackboard::setVec3(uid, "homePos", home.x, home.y, home.z);
        Blackboard::setFloat(uid, "depositAmount", this.harvestDeposit);
        Blackboard::setEnabled(uid, true);
    }

    // Stop gathering and remove the tree so it can't keep commanding the agent.
    private function stopHarvest(int uid): void {
        Blackboard::setEnabled(uid, false);
        Blackboard::detachTree(uid);
    }

    // Nearest GoldNode within `radius` of a world point, or -1. Turns a
    // right-click on (or near) a gold mine into a "gather this node" order.
    private function goldNodeNear(Vec3f point, float radius): int {
        int[] nodes = Entity::findAll("GoldNode");
        int best = -1;
        float bestSq = radius * radius;
        for (int i = 0; i < nodes.length; i = i + 1) {
            Vec3f p = Entity::getPosition(nodes[i]);
            float dx = p.x - point.x;
            float dz = p.z - point.z;
            float d = dx * dx + dz * dz;
            if (d <= bestSq) {
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
        // Contextual like the command card / rally markers: the strip shows the
        // SELECTED building's own queue. Every other building keeps producing in
        // tickQueue() regardless of what's selected; this only drives display.
        int selectedId = -1;
        SelectionController? sel = this.selection();
        if (sel != null) {
            selectedId = sel.getSelectedId();
        }
        int headIdx = -1;
        if (selectedId >= 0) {
            headIdx = this.buildingHeadIndex(selectedId);
        }
        if (headIdx < 0) {
            this.hideQueueUI();
            return;
        }
        int nSel = this.buildingQueueCount(selectedId);

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
            UI::setLabelText(this.queueLabelId, "Producing: " + this.queue[headIdx].unitType);
        }

        if (this.queueListId >= 0) {
            // Position the slot strip; the layout group lays slots out left-to-right.
            UI::setRectPixels(this.queueListId, px + pad, py + 6.0, panelW - pad * 2.0, slotW);
            // Reconciles synchronously: getListItem(i) is valid this same frame.
            UI::setListItemCount(this.queueListId, nSel);
            int slot = 0;
            for (int i = 0; i < this.queueCount; i = i + 1) {
                if (this.queue[i].buildingId != selectedId) {
                    continue;
                }
                int item = UI::getListItem(this.queueListId, slot);
                slot = slot + 1;
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
            QueueItem head = this.queue[headIdx];
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
        return this.gameObject().getScript<SelectionController>("SelectionController");
    }

    private function placement(): BuildingPlacementController? {
        return this.gameObject().getScript<BuildingPlacementController>("BuildingPlacementController");
    }

    private function unitSelection(): UnitSelectionController? {
        return this.gameObject().getScript<UnitSelectionController>("UnitSelectionController");
    }
}
