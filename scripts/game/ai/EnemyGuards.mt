// EnemyGuards - VK-1447 showcase. Spawns a few fixed enemy guard soldiers at posts
// and gives each the Guard behavior tree: they acquire nearby player units, fight
// through the existing SoldierCombatController, and return to their post when the
// target is gone. Team = 1 and NO "Selectable" component keep them out of player
// selection/commands. Bootstrapped from BuildingCommandController.onStart.
//
// NOTE: the post coordinates below are placed near the origin; adjust them so each
// guard spawns on baked navmesh and within reach of where the player will fight.

import * from "../../lib/engine/oop/PrefabRef.mt";
import * from "../../lib/engine/oop/GameObject.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/math/Vec3f.mt";

class EnemyGuards {
    private string guardTree;
    private PrefabRef soldierPrefab;
    private int serial;

    public constructor() {
        this.guardTree = "assets/ai/Guard.vfBehaviorTree";
        this.soldierPrefab = new PrefabRef("assets/units/soldier_prefab.vfPrefab");
        this.serial = 0;
    }

    public function setup(): void {
        this.spawnGuard(new Vec3f(40.0, 0.0, 40.0));
        this.spawnGuard(new Vec3f(-40.0, 0.0, 40.0));
        Log::info("[EnemyGuards] spawned enemy guards.");
    }

    private function spawnGuard(Vec3f post): void {
        GameObject? guard = this.soldierPrefab.instantiateAt(post);
        if (guard == null) {
            return;
        }
        int id = guard.id;
        this.serial = this.serial + 1;
        guard.setName("EnemyGuard_" + parsePrimitive(this.serial));
        guard.setActive(true);

        // Enemy team + combat stats. No "Selectable" -> the player can't select or
        // command it; the selection/command code already filters to TEAM_PLAYER.
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
            Blackboard::setVec3(id, "guardPos", post.x, post.y, post.z);
            Blackboard::setFloat(id, "aggroRange", 22.0);
            Blackboard::setEnabled(id, true);
        }
    }
}
