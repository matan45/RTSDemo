// EnemyBases - VK-1589. Spawns the enemy command structures the skirmish was missing, and
// registers a persistent World-Sector streaming source on each one so the sectors holding
// them stay resident while the camera is parked at the player base. Without a source, an
// off-screen base's sector is Unloaded and its buildings pop in the moment the player pans
// or minimap-jumps over there.
//
// Bootstrapped from BuildingCommandController.onStart, exactly like EnemyGuards/PatrolDemo,
// so it needs no scene wiring. Team = 1 and no "Selectable" component keep the bases out of
// player selection and commands.
//
// TWO THINGS THAT LOOK LIKE MISTAKES AND ARE NOT:
//
//  * priority 0, not 1. The camera is registered by the engine as priority 0 and the default
//    budget is ONE sector load per frame; a priority > 0 source takes that slot off the
//    player's own view. Persistent sources belong at camera parity. (The minimap pre-warm in
//    MinimapController is the opposite case and deliberately outranks the camera.)
//
//  * update() polls for dead bases even though registerWorldSource was given an owner UUID.
//    The engine releases the source when the entity is DELETED, but Combat::applyDamage never
//    deletes - it drives Health to 0 and leaves the entity standing (see game/util/Combat.mt).
//    So the owner hook covers Entity::destroy and the poll covers death-by-damage. Both are
//    needed; neither is redundant.

import * from "../../lib/engine/oop/PrefabRef.mt";
import * from "../../lib/engine/oop/GameObject.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Streaming.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/Combat.mt";

class EnemyBases {
    private PrefabRef basePrefab;

    // Post centres. Chosen against the sector grid, not by eye: with the 32-unit sectors
    // Skirmish_01.vfworld is built on, (+-48, 48) lands in sectors (1,1) and (-2,1), whose
    // centres sit 67.9 units from a camera at the origin - outside the 48-unit load ring, so
    // they read Unloaded until a source pulls them in. That gap IS the acceptance test.
    private float[] postX;
    private float[] postZ;

    private int[] baseIds;      // entity id per base, -1 once gone
    private int[] sourceIds;    // streaming source id per base, 0 when none / released
    private int count;

    private float baseMaxHealth;
    private float sourceRadiusMultiplier;
    private bool warnedNoWorld;

    public constructor() {
        this.basePrefab = new PrefabRef("assets/buildings/command_center_prefab.vfPrefab");

        this.postX = new float[2];
        this.postZ = new float[2];
        this.postX[0] = 48.0;
        this.postZ[0] = 48.0;
        this.postX[1] = -48.0;
        this.postZ[1] = 48.0;

        this.baseIds = new int[2];
        this.sourceIds = new int[2];
        this.count = 0;

        // Matches the CommandCenter entry in BuildingPlacementController's build table.
        this.baseMaxHealth = 1500.0;

        // 0.5 keeps the ring tight: the base's own sector and nothing else. This scales the
        // UNLOAD radius too, which is what actually pins the sector against the camera's
        // eviction pass.
        this.sourceRadiusMultiplier = 0.5;

        this.warnedNoWorld = false;
    }

    // Max (and starting) HP each base spawns with. Exposed as a knob purely for
    // testing: dropping it to a few hundred turns "kill both enemy bases" from a
    // long grind into something a single squad -- or an automated harness run --
    // can finish, which is what makes the WIN path testable at all. Must be called
    // BEFORE setup(); the value is baked into each base's Health at spawn.
    public function setBaseMaxHealth(float hp): void {
        if (hp > 0.0) {
            this.baseMaxHealth = hp;
        }
    }

    public function getBaseMaxHealth(): float {
        return this.baseMaxHealth;
    }

    public function setup(): void {
        for (int i = 0; i < this.postX.length; i = i + 1) {
            this.spawnBase(this.postX[i], this.postZ[i]);
        }
        Log::info("[EnemyBases] spawned " + parsePrimitive(this.count) + " enemy base(s).");
    }

    // Entity ids of the bases that were actually spawned. Sized to `count`, not to
    // the backing array, so a failed instantiate never leaks a 0/garbage id to
    // callers. EnemyCommander picks a wave's source base out of this.
    public function getBaseIds(): int[] {
        int[] ids = new int[this.count];
        for (int i = 0; i < this.count; i = i + 1) {
            ids[i] = this.baseIds[i];
        }
        return ids;
    }

    // Bases still standing. "Alive" is deliberately BOTH checks: Combat::applyDamage
    // drives Health to 0 without deleting (see the header note), while
    // DeathController then destroys the entity -- so a base can be invalid, or valid
    // with 0 HP, depending on which pass got to it first.
    public function aliveBases(): int {
        int n = 0;
        for (int i = 0; i < this.count; i = i + 1) {
            int id = this.baseIds[i];
            if (Entity::isValid(id) && Combat::isAlive(id)) {
                n = n + 1;
            }
        }
        return n;
    }

    private function spawnBase(float x, float z): void {
        float y = 0.0;
        if (Terrain::hasHeightAt(x, z)) {
            y = Terrain::heightAt(x, z);
        }

        GameObject? baseObj = this.basePrefab.instantiateAt(new Vec3f(x, y, z));
        if (baseObj == null) {
            Log::warn("[EnemyBases] command_center_prefab failed to instantiate; skipping post.");
            return;
        }

        int id = baseObj.id;

        // "EnemyBuilding" is the name SelectionController::registerEnemyBuildings looks for.
        // It will not pick these up this session - that scan runs in SelectionController's
        // onStart, which is earlier in GameSystems' script list than the controller that
        // bootstraps us - but the name is the established contract and costs nothing.
        baseObj.setName("EnemyBuilding");
        baseObj.setActive(true);

        PluginComponent::add(id, "Team");
        PluginComponent::setInt(id, "Team", "teamId", 1);
        PluginComponent::add(id, "Health");
        PluginComponent::setFloat(id, "Health", "maxHP", this.baseMaxHealth);
        PluginComponent::setFloat(id, "Health", "currentHP", this.baseMaxHealth);

        int srcId = Streaming::registerWorldSource(x, y, z,
                                                   this.sourceRadiusMultiplier, 0,
                                                   Entity::getUUID(id));
        if (srcId == 0 && !this.warnedNoWorld) {
            // Expected in a plain scene: registerWorldSource returns 0 when no sector world
            // is active. Warn once so it reads as "nothing to stream", not as a silent failure.
            Log::warn("[EnemyBases] no sector world active; base streaming sources are inert.");
            this.warnedNoWorld = true;
        }

        this.baseIds[this.count] = id;
        this.sourceIds[this.count] = srcId;
        this.count = this.count + 1;
    }

    // Release the source of any base that has died or been destroyed. Cheap: `count` is 2.
    public function update(): void {
        for (int i = 0; i < this.count; i = i + 1) {
            int srcId = this.sourceIds[i];
            if (srcId == 0) {
                continue;
            }

            bool gone = false;
            int baseId = this.baseIds[i];
            if (!Entity::isValid(baseId)) {
                gone = true;
            } else if (!Combat::isAlive(baseId)) {
                gone = true;
            }

            if (gone) {
                Streaming::unregisterWorldSource(srcId);
                this.sourceIds[i] = 0;
                Log::info("[EnemyBases] released the streaming source of a destroyed base.");
            }
        }
    }

    // Called from the bootstrapping controller's onDestroy. onDestroy fires on play-stop and
    // on script reload, neither of which goes through entity deletion, so the owner-UUID hook
    // would not fire for them.
    public function teardown(): void {
        for (int i = 0; i < this.count; i = i + 1) {
            if (this.sourceIds[i] != 0) {
                Streaming::unregisterWorldSource(this.sourceIds[i]);
                this.sourceIds[i] = 0;
            }
        }
        this.count = 0;
    }
}
