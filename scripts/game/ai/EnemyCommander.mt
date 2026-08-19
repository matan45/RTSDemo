// EnemyCommander - the enemy's offensive AI: timed attack waves (VK-1298 slice 1).
//
// The skirmish had enemy bases (ai/EnemyBases.mt) and two static guards
// (ai/EnemyGuards.mt), but nothing that ever came at the player -- so a match had
// no pressure and no way to LOSE. This sends waves of soldiers at the player's
// base until every enemy base is dead.
//
// ZERO NEW AI ASSETS, on purpose. A wave soldier is exactly an EnemyGuards guard
// (same soldier prefab, same team/health/attack components, same
// assets/ai/Guard.vfBehaviorTree) with its guardPos set to the PLAYER'S base
// instead of a fixed post, and a wider aggroRange. The Guard tree already walks to
// its post, senses hostiles around it, and engages -- which, with the post moved
// onto the player, is exactly "march over there and attack what you find". This
// only works because AcquireTarget's scan is team-relative: hard-coded to
// TEAM_PLAYER it would have made these soldiers hunt their own side.
//
// Plain class, not a @Script: bootstrapped from BuildingCommandController.onStart
// and ticked from its onUpdate, the same shape as PatrolDemo / EnemyGuards /
// EnemyBases, so it needs no scene wiring of its own.
//
// STOP CONDITIONS. Waves stop when every enemy base is dead (the player has won
// the map even if MatchController has not evaluated yet) or when the match is over
// either way -- there is no point spawning attackers into a finished match, and a
// wave spawned at a destroyed base has nowhere to come from.

import * from "../../lib/engine/oop/PrefabRef.mt";
import * from "../../lib/engine/oop/GameObject.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../controllers/SelectionController.mt";
import * from "../controllers/MatchController.mt";
import * from "../data/BuildingInfo.mt";
import * from "../util/Combat.mt";
import * from "../util/Config.mt";
import * from "./EnemyBases.mt";

class EnemyCommander {
    private string guardTree;
    private PrefabRef soldierPrefab;

    // The bases the waves come from, owned by BuildingCommandController and handed
    // in at construction (this class never spawns or destroys them).
    private EnemyBases bases;

    // Resolved lazily from the GameSystems entity: both are @Scripts and script
    // init order within one entity's script list is not guaranteed, so resolving in
    // the constructor can miss them.
    private int systemsId;
    private MatchController? matchCtl;
    private SelectionController? selection;

    // Wave schedule. The first wave is late (firstWaveDelay) so the player has time
    // to place a Command Center and a Barracks before anything walks in; after that
    // one wave per waveInterval, growing by one soldier each time up to maxWaveSize.
    private float firstWaveDelay;
    private float waveInterval;
    private int firstWaveSize;
    private int maxWaveSize;

    private float timer;
    private int waveNumber;

    // How far a wave soldier senses hostiles around its objective. Wider than a
    // static guard's 22 because a wave is meant to engage the base's defenders, not
    // to hold a tight post.
    private float waveAggroRange;

    // Spawn scatter around the source base, so a wave does not stack every soldier
    // on one navmesh point.
    private float spawnSpread;

    // Where waves head when the player has built nothing yet. Roughly the player's
    // starting corner; kept inside the +/-64 playable bounds (util/Config.mt).
    private float fallbackX;
    private float fallbackZ;

    public constructor(EnemyBases bases) {
        this.guardTree = "assets/ai/Guard.vfBehaviorTree";
        this.soldierPrefab = new PrefabRef("assets/units/soldier_prefab.vfPrefab");
        this.bases = bases;

        this.systemsId = -1;
        this.matchCtl = null;
        this.selection = null;

        this.firstWaveDelay = 60.0;
        this.waveInterval = 45.0;
        this.firstWaveSize = 3;
        this.maxWaveSize = 8;

        this.timer = 0.0;
        this.waveNumber = 0;

        this.waveAggroRange = 30.0;
        this.spawnSpread = 4.0;

        this.fallbackX = 0.0;
        this.fallbackZ = -30.0;
    }

    public function setup(): void {
        this.systemsId = Entity::findByName("GameSystems");
        this.timer = 0.0;
        this.waveNumber = 0;
        Log::info("[EnemyCommander] armed; first wave in "
            + parsePrimitive(this.firstWaveDelay) + "s.");
    }

    public function update(float deltaTime): void {
        if (this.bases.aliveBases() <= 0) {
            return;   // no base left to send anyone; the player has cleared the map
        }
        MatchController? m = this.matchController();
        if (m != null && m.isOver()) {
            return;
        }

        this.timer = this.timer + deltaTime;
        float due = this.waveInterval;
        if (this.waveNumber == 0) {
            due = this.firstWaveDelay;
        }
        if (this.timer < due) {
            return;
        }
        this.timer = 0.0;
        this.sendWave();
    }

    public function teardown(): void {
        // The soldiers themselves are ordinary scene entities; the scene teardown
        // (or DeathController) owns them. Only the schedule is reset here so a
        // script reload does not immediately fire a wave.
        this.timer = 0.0;
        this.waveNumber = 0;
        this.matchCtl = null;
        this.selection = null;
    }

    public function getWaveNumber(): int {
        return this.waveNumber;
    }

    // ---- waves ----

    private function sendWave(): void {
        int sourceBase = this.firstAliveBase();
        if (sourceBase < 0) {
            return;
        }

        this.waveNumber = this.waveNumber + 1;
        int size = this.firstWaveSize + (this.waveNumber - 1);
        if (size > this.maxWaveSize) {
            size = this.maxWaveSize;
        }

        Vec3f origin = Entity::getPosition(sourceBase);
        Vec3f objective = this.objectiveNear(origin.x, origin.z);

        int spawned = 0;
        for (int i = 0; i < size; i = i + 1) {
            if (this.spawnWaveSoldier(origin, i, objective)) {
                spawned = spawned + 1;
            }
        }

        Log::info("WAVE," + parsePrimitive(this.waveNumber) + "," + parsePrimitive(spawned));
    }

    // One wave soldier. Deliberately a copy of EnemyGuards.spawnGuard's component
    // setup (team/health/attack/speed/tree) rather than a shared helper: the two
    // spawners differ only in the post they are given, and keeping them separate
    // lets guard and wave stats be tuned independently.
    private function spawnWaveSoldier(Vec3f origin, int index, Vec3f objective): bool {
        Vec3f post = this.spawnPoint(origin, index);

        GameObject? unit = this.soldierPrefab.instantiateAt(post);
        if (unit == null) {
            return false;
        }
        int id = unit.id;
        unit.setName("EnemyWave_" + parsePrimitive(this.waveNumber) + "_" + parsePrimitive(index));
        unit.setActive(true);

        // Enemy team + combat stats. No "Selectable" -> the player cannot select or
        // command it; selection/command code already filters to TEAM_PLAYER.
        PluginComponent::add(id, "Team");
        PluginComponent::setInt(id, "Team", "teamId", 1);
        PluginComponent::add(id, "Health");
        PluginComponent::setFloat(id, "Health", "maxHP", 60.0);
        PluginComponent::setFloat(id, "Health", "currentHP", 60.0);
        PluginComponent::add(id, "Attack");
        PluginComponent::setFloat(id, "Attack", "damage", 10.0);
        PluginComponent::setFloat(id, "Attack", "range", 14.0);
        PluginComponent::setFloat(id, "Attack", "cooldown", 1.0);

        Navmesh::setSpeed(id, 6.0);

        bool ok = Blackboard::attachTree(id, this.guardTree);
        if (ok) {
            // guardPos is the PLAYER's base, not this soldier's spawn: the Guard
            // tree walks to its post and fights whatever it senses there, which is
            // the whole attack behaviour.
            Blackboard::setVec3(id, "guardPos", objective.x, objective.y, objective.z);
            Blackboard::setFloat(id, "aggroRange", this.waveAggroRange);
            Blackboard::setEnabled(id, true);
        } else {
            // No tree (missing asset): at least march them at the objective so the
            // wave is still visible and the player's units can engage it.
            Navmesh::moveTo(id, objective);
        }
        return true;
    }

    // Scatter spawns on a small ring around the base so the crowd solver is not
    // handed a stack of agents on one point.
    private function spawnPoint(Vec3f origin, int index): Vec3f {
        float ox = this.spawnSpread;
        float oz = this.spawnSpread;
        int k = index % 4;
        if (k == 1) { ox = -this.spawnSpread; oz = this.spawnSpread; }
        if (k == 2) { ox = this.spawnSpread; oz = -this.spawnSpread; }
        if (k == 3) { ox = -this.spawnSpread; oz = -this.spawnSpread; }

        // Rings widen every 4 soldiers so a big late wave does not overlap itself.
        float ring = (float)(index / 4) * this.spawnSpread;
        float x = origin.x + ox + ring;
        float z = origin.z + oz + ring;

        float y = 0.0;
        if (Terrain::hasHeightAt(x, z)) {
            y = Terrain::heightAt(x, z);
        }
        return new Vec3f(x, y, z);
    }

    private function firstAliveBase(): int {
        int[] ids = this.bases.getBaseIds();
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (Entity::isValid(id) && Combat::isAlive(id)) {
                return id;
            }
        }
        return -1;
    }

    // ---- objective selection ----

    // Where the wave is sent: the player's Command Center if there is one, else the
    // player building nearest to (ox, oz) -- the base the wave is leaving -- else a
    // fixed point in the player's starting corner so a wave still marches somewhere
    // sensible before the player has built anything.
    private function objectiveNear(float ox, float oz): Vec3f {
        SelectionController? sel = this.selectionController();
        if (sel != null) {
            int best = -1;
            float bestSq = 0.0;
            bool haveCC = false;

            int[] ids = PluginComponent::findAll("Team");
            for (int i = 0; i < ids.length; i = i + 1) {
                int id = ids[i];
                if (!Entity::isValid(id)) {
                    continue;
                }
                if (PluginComponent::getInt(id, "Team", "teamId") != Config::TEAM_PLAYER) {
                    continue;
                }
                if (!Combat::isAlive(id)) {
                    continue;
                }
                // Positive narrowing rather than an `if (info == null) continue;`
                // guard: guard-clause narrowing only started working in mType
                // eaa2328c (MYT-381), and this form compiles either way. A null
                // info means the entity is a unit, not a registered building.
                BuildingInfo? info = sel.findInfo(id);
                if (info != null) {
                    bool isCC = info.buildingType == "CommandCenter";
                    // Once a Command Center has been found, nothing else can win.
                    if (!haveCC || isCC) {
                        Vec3f p = Entity::getPosition(id);
                        float dx = p.x - ox;
                        float dz = p.z - oz;
                        float d = dx * dx + dz * dz;

                        // A Command Center always outranks a plain building;
                        // among equals, take the nearest.
                        if (best < 0 || (isCC && !haveCC) || d < bestSq) {
                            best = id;
                            bestSq = d;
                            if (isCC) {
                                haveCC = true;
                            }
                        }
                    }
                }
            }

            if (best >= 0) {
                return Entity::getPosition(best);
            }
        }

        float y = 0.0;
        if (Terrain::hasHeightAt(this.fallbackX, this.fallbackZ)) {
            y = Terrain::heightAt(this.fallbackX, this.fallbackZ);
        }
        return new Vec3f(this.fallbackX, y, this.fallbackZ);
    }

    // ---- peer resolution ----

    private function matchController(): MatchController? {
        if (this.matchCtl == null && this.systemsId >= 0) {
            this.matchCtl = Entity::getScript<MatchController>(this.systemsId, "MatchController");
        }
        return this.matchCtl;
    }

    private function selectionController(): SelectionController? {
        if (this.selection == null && this.systemsId >= 0) {
            this.selection = Entity::getScript<SelectionController>(this.systemsId, "SelectionController");
        }
        return this.selection;
    }
}
