// DeathController - the one place a unit or building actually dies (VK-1298 slice 1).
//
// Until now NOTHING in the skirmish died. The RTSGameplay plugin's damage native
// clamps Health.currentHP at 0 and deliberately never destroys the entity
// (plugins/RTSGameplay CombatRules); it publishes "rts.unit_killed" onto the
// PLUGIN event bus, which has no bridge into mType. So a "dead" soldier kept its
// selection ring, kept its behavior tree ticking, kept blocking the navmesh, and
// no win/lose condition could ever fire. This controller closes that loop from the
// script side, with no engine change required.
//
// TWO PATHS INTO IT, on purpose:
//
//   1. reportKill(victim, killer) - the FAST path. SoldierCombatController calls it
//      the instant Combat::applyDamage returns KILLED, so the corpse disappears on
//      the same frame as the killing shot. This is the path that must work.
//   2. sweep() - the SLOW safety net, every sweepInterval seconds over every entity
//      carrying a Health component with currentHP <= 0. It exists because damage
//      sources that are NOT the soldier hit-scan (artillery craters, a future
//      plugin-side event bridge, anything scripted later) have no reason to know
//      this controller exists. Without it, a unit killed by a new damage source
//      would silently become an immortal corpse again.
//
// IDEMPOTENCE. Several soldiers can land a killing shot on the same target in one
// frame, and the sweep can race the fast path, so despawn() must run exactly once
// per victim. The `dead` map is that guard. It is keyed by entity id, and entity
// ids are RECYCLED by the ECS -- an id marked dead today can be a healthy new unit
// tomorrow -- so pruneRecycled() drops any marked id that is valid again AND alive.
// Without that prune a recycled id would be treated as a corpse and despawned on
// sight.
//
// WHY BuildingCommandController IS NOT IMPORTED HERE. It owns per-building state
// (production queues, rally markers, harvester homes) that must be cleaned up on a
// death, so the obvious shape is to call it from despawn(). But it already imports
// SoldierCombatController, which imports THIS file, and mType rejects circular
// imports outright (direct, indirect and mixed cycles are all compile errors). So
// the dependency is inverted: deaths are appended to a small pending list and
// BuildingCommandController drains it with drainDeaths() on its own tick. Nothing
// in that cleanup needs the entity to still exist, so draining a frame later is
// equivalent.
//
// Attach this @Script to the GameSystems entity alongside the other controllers.

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/VFX.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/core/collections/HashMap.mt";
import * from "../../lib/core/primitives/Int.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "./SelectionController.mt";
import * from "./UnitSelectionController.mt";
import * from "./BuildingPlacementController.mt";
import * from "../util/Combat.mt";

@Script
class DeathController extends Behaviour {
    // Entity ids already despawned (the value is the killer id, kept only for
    // debugging). See the recycling note in the header for why entries are pruned.
    private HashMap<Int, Int> dead;

    // Peer controllers on this same GameSystems entity, resolved once in onStart.
    // Resolving per-death would cost a getScript lookup on the hot kill path, and
    // resolving in the constructor is too early (script init order across one
    // entity's script list is not guaranteed).
    private SelectionController? selection;
    private UnitSelectionController? unitSelection;
    private BuildingPlacementController? placement;

    // Deaths not yet drained by BuildingCommandController (see the header note on
    // the inverted dependency). A plain array + count, drained whole; it only ever
    // holds one tick's worth of deaths.
    private int[] pending;
    private int pendingCount;

    // Safety-net cadence. 0.5 s is well under the time it takes a corpse to look
    // wrong on screen, and the scan is a single findAll over Health entities.
    private float sweepInterval;
    private float sweepAccum;

    // One-shot death effect. Reuses the soldier muzzle-flash asset because the demo
    // has no dedicated death VFX yet; set to "" to disable.
    private string deathVfx;

    // Running total, logged so a smoke run can assert "things actually died".
    private int deathCount;

    public constructor() : super() {
        this.selection = null;
        this.unitSelection = null;
        this.placement = null;
        this.pendingCount = 0;
        this.sweepInterval = 0.5;
        this.sweepAccum = 0.0;
        this.deathVfx = "assets/units/soldier/fire.vfVFX";
        this.deathCount = 0;
    }

    public function onStart(): void {
        this.dead = new HashMap<Int, Int>();
        this.pending = new int[128];

        // All three live on GameSystems, same as this script -- the established
        // same-entity lookup the other controllers use (see
        // BuildingCommandController.selection()/placement()/unitSelection()).
        this.selection = this.gameObject().getScript<SelectionController>("SelectionController");
        this.unitSelection = this.gameObject().getScript<UnitSelectionController>("UnitSelectionController");
        this.placement = this.gameObject().getScript<BuildingPlacementController>("BuildingPlacementController");

        Log::info("[Death] ready.");
    }

    public function onUpdate(float deltaTime): void {
        this.sweepAccum = this.sweepAccum + deltaTime;
        if (this.sweepAccum < this.sweepInterval) {
            return;
        }
        this.sweepAccum = 0.0;
        this.sweep();
    }

    public function onDestroy(): void {
    }

    // ---- public API ----

    // Report that `victimId` was just killed by `killerId` (-1 = unattributed).
    // Safe to call repeatedly for the same victim and from any controller.
    public function reportKill(int victimId, int killerId): void {
        if (victimId < 0 || this.isDead(victimId)) {
            return;
        }
        this.despawn(victimId, killerId);
    }

    // True once this controller has despawned `id`. Callers use it to skip work on
    // an entity that is already gone.
    public function isDead(int id): bool {
        if (id < 0) {
            return false;
        }
        return this.dead.containsKey(new Int(id));
    }

    // Hand over (and clear) the ids that died since the last call. Consumed by
    // BuildingCommandController so it can drop queue items / rally points / track
    // homes belonging to the dead, without this file importing it (see header).
    public function drainDeaths(): int[] {
        int[] out = new int[this.pendingCount];
        for (int i = 0; i < this.pendingCount; i = i + 1) {
            out[i] = this.pending[i];
        }
        this.pendingCount = 0;
        return out;
    }

    public function getDeathCount(): int {
        return this.deathCount;
    }

    // ---- safety net ----

    // Despawn anything holding a Health component at or below 0 HP that the fast
    // path missed, and drop stale marks for recycled ids while we are already
    // walking the world.
    private function sweep(): void {
        this.pruneRecycled();

        int[] ids = PluginComponent::findAll("Health");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id) || this.isDead(id)) {
                continue;
            }
            if (PluginComponent::getFloat(id, "Health", "currentHP") <= 0.0) {
                this.despawn(id, -1);
            }
        }
    }

    // Entity ids are recycled by the ECS, so a marked id that is valid again AND
    // has live health is a DIFFERENT entity that happens to reuse the number. Drop
    // the mark, or the new unit is treated as an already-handled corpse and the
    // fast path silently refuses to kill it later.
    private function pruneRecycled(): void {
        Int[] keys = this.dead.getKeys();
        for (int i = 0; i < keys.length; i = i + 1) {
            int id = keys[i].getValue();
            if (Entity::isValid(id) && Combat::isAlive(id)) {
                this.dead.remove(keys[i]);
            }
        }
    }

    // ---- the actual despawn ----

    // Order matters here, and every step is an EXISTING API:
    //
    //   1. mark dead first, so a re-entrant report (a peer teardown that triggers
    //      another kill) cannot recurse back into this same victim;
    //   2. log before anything is torn down, while the name and team can still be
    //      read off the entity;
    //   3. silence the AI (behavior tree) and the navmesh agent BEFORE unregistering
    //      from the gameplay controllers, so nothing re-issues an order to a corpse;
    //   4. unregister from every registry that keys on the entity id (selection
    //      rings, building registry, placement footprint, and -- via the pending
    //      list -- the production queue), because those are plain mType HashMaps:
    //      the engine's EntityDeletedNotification does not reach them;
    //   5. destroy last. Entity::destroy is synchronous (HierarchyService detaches
    //      each script -> onDestroy, publishes EntityDeletedNotification for the
    //      whole subtree, then removes it), so isValid() is false immediately after
    //      and every engine-side consumer (fog Vision, animator, IK, plugin
    //      components) releases on that notification.
    //
    // Destroying an entity that appears later in this frame's script update list is
    // safe: the engine skips stale entries.
    private function despawn(int id, int killerId): void {
        this.dead.put(new Int(id), new Int(killerId));

        if (!Entity::isValid(id)) {
            return;   // already gone; the mark above is all that was needed
        }

        int team = -1;
        if (PluginComponent::has(id, "Team")) {
            team = PluginComponent::getInt(id, "Team", "teamId");
        }
        Vec3f pos = Entity::getPosition(id);
        Log::info("DEATH," + parsePrimitive(id) + "," + Entity::getName(id) + "," + parsePrimitive(team));
        this.deathCount = this.deathCount + 1;

        // AI first: a tree left enabled would keep ticking tasks against a corpse
        // (and EngageTarget would keep issuing nav orders) for the rest of the frame.
        Blackboard::setEnabled(id, false);
        Blackboard::detachTree(id);
        Navmesh::stopAgent(id);

        // Script-side registries keyed by entity id. Narrow to locals first --
        // field narrowing across a call is unreliable in mType.
        UnitSelectionController? usel = this.unitSelection;
        if (usel != null) {
            usel.unregisterUnit(id);
        }
        SelectionController? sel = this.selection;
        if (sel != null) {
            sel.unregister(id);
        }
        BuildingPlacementController? place = this.placement;
        if (place != null) {
            place.removePlaced(id);
        }
        this.queuePending(id);

        if (this.deathVfx != "") {
            VFX::spawnAt(this.deathVfx, pos.x, pos.y, pos.z);
        }

        Entity::destroy(id);
    }

    // Append to the drain list. If the consumer is missing (or somehow stops
    // draining) the list saturates rather than growing without bound -- dropping a
    // queue-cleanup notification is far cheaper than an unbounded array, and
    // BuildingCommandController's tickQueue already drops items whose building has
    // become invalid on its own.
    private function queuePending(int id): void {
        if (this.pendingCount >= this.pending.length) {
            return;
        }
        this.pending[this.pendingCount] = id;
        this.pendingCount = this.pendingCount + 1;
    }
}
