// EngageTarget - BT ScriptTask: hand the acquired target to the unit's existing
// SoldierCombatController, which does the chase / stop-and-fire (so enemy guards
// reuse the exact player-soldier combat path). Keeps delegating while the target
// is valid; clears combat and fails when it's gone so the guard returns to its
// post. (VK-1447)
//
// This task NEVER drives the NavmeshAgent itself -- the combat controller owns
// movement while engaging. When the guard tree's BlackboardCondition aborts this
// branch (enemyVisible turned false), onAbort clears the target so the controller
// goes idle (inert) and the Return-To-Guard MoveTo can own the agent.
//
// Blackboard in:  targetId (int)
// Blackboard out: enemyVisible (bool, cleared on loss)
// Returns: "running" while engaging, "failure" when there is no valid target
// onAbort: clears the unit's attack target

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../util/Combat.mt";
import * from "../controllers/SoldierCombatController.mt";

@Script
public class EngageTarget extends Behaviour {
    private int selfId;
    private SoldierCombatController? combat;

    public constructor() : super() {
        this.selfId = -1;
        this.combat = null;
    }

    public function onStart(): void {
        this.selfId = this.entityId();
        this.combat = Entity::getScript<SoldierCombatController>(this.selfId, "SoldierCombatController");
    }

    public function tick(float deltaTime): string {
        int tid = Blackboard::getInt(this.selfId, "targetId");
        if (tid < 0 || !Entity::isValid(tid) || !Entity::isActive(tid) || !Combat::isAlive(tid)) {
            this.clearCombat();
            Blackboard::setBool(this.selfId, "enemyVisible", false);
            Blackboard::setInt(this.selfId, "targetId", -1);
            return "failure";
        }
        SoldierCombatController? c = this.combat;
        if (c != null) {
            c.setTarget(tid);
        }
        return "running";
    }

    public function onAbort(): void {
        this.clearCombat();
    }

    // Required by the @Script validator; the behavior tree drives this task via
    // tick(), so onUpdate is an intentional no-op.
    public function onUpdate(float deltaTime): void {
    }

    public function onDestroy(): void {
        this.clearCombat();
    }

    private function clearCombat(): void {
        SoldierCombatController? c = this.combat;
        if (c != null) {
            c.setTarget(-1);
        }
    }
}
