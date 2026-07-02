// AcquireTarget - BT ScriptTask: an enemy guard's perception. Finds the nearest
// LIVING player-team unit within aggroRange of the guard's post (guardPos) and
// publishes it for the engage branch. Scanning around the POST (not the guard's
// current position) is what leashes the guard: a target that wanders out of the
// post's bubble is dropped, so the guard returns home. (VK-1447)
//
// Blackboard in:  guardPos (vec3), aggroRange (float, default 22)
// Blackboard out: enemyVisible (bool), targetId (int)
// Returns: "success" when a target is found, "failure" otherwise

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/Config.mt";
import * from "../util/Combat.mt";

@Script
public class AcquireTarget extends Behaviour {
    private int selfId;

    public constructor() : super() {
        this.selfId = -1;
    }

    public function onStart(): void {
        this.selfId = this.entityId();
    }

    public function tick(float deltaTime): string {
        float[] gp = Blackboard::getVec3(this.selfId, "guardPos");
        float aggro = Blackboard::getFloat(this.selfId, "aggroRange");
        if (aggro <= 0.0) {
            aggro = 22.0;
        }

        int best = -1;
        float bestSq = aggro * aggro;
        int[] ids = PluginComponent::findAll("Team");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id) || !Entity::isActive(id)) {
                continue;
            }
            if (PluginComponent::getInt(id, "Team", "teamId") != Config::TEAM_PLAYER) {
                continue;
            }
            if (!Combat::isAlive(id)) {
                continue;
            }
            Vec3f p = Entity::getPosition(id);
            float dx = p.x - gp[0];
            float dz = p.z - gp[2];
            float d = dx * dx + dz * dz;
            if (d < bestSq) {
                best = id;
                bestSq = d;
            }
        }

        if (best < 0) {
            Blackboard::setBool(this.selfId, "enemyVisible", false);
            Blackboard::setInt(this.selfId, "targetId", -1);
            return "failure";
        }

        Blackboard::setInt(this.selfId, "targetId", best);
        Blackboard::setBool(this.selfId, "enemyVisible", true);
        return "success";
    }

    // Required by the @Script validator; the behavior tree drives this task via
    // tick(), so onUpdate is an intentional no-op.
    public function onUpdate(float deltaTime): void {
    }

    public function onDestroy(): void {
    }
}
