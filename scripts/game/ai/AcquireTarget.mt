// AcquireTarget - BT ScriptTask: a guard's perception. Finds the nearest LIVING
// HOSTILE unit within aggroRange of the guard's post (guardPos) and publishes it
// for the engage branch. Scanning around the POST (not the guard's current
// position) is what leashes the guard: a target that wanders out of the post's
// bubble is dropped, so the guard returns home. (VK-1447)
//
// The scan is TEAM-RELATIVE (Combat::findNearestHostile compares against the
// ticking entity's own Team.teamId) rather than hard-coded to TEAM_PLAYER. That
// matters now that the same Guard tree is attached to enemy wave soldiers
// (ai/EnemyCommander.mt): a hard-coded "player is the enemy" rule was correct only
// while every tree-driven unit happened to be on team 1, and it silently broke the
// moment a player-team unit ran the same tree.
//
// Blackboard in:  guardPos (vec3), aggroRange (float, default 22)
// Blackboard out: enemyVisible (bool), targetId (int)
// Returns: "success" when a target is found, "failure" otherwise

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Blackboard.mt";
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

        int best = Combat::findNearestHostile(this.selfId, gp[0], gp[2], aggro);

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
