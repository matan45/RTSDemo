// DepositGold - BT ScriptTask: the "deposit" leaf of the Track harvester loop.
//
// Reached once per refinery <-> node cycle, after the harvester has returned to
// its homePos. Credits the player's gold (the amount comes from the harvester's
// `depositAmount` blackboard key, seeded by BuildingCommandController so the value
// stays a single tuning point) and returns "success" so the parent Sequence
// completes and the Repeater starts the next cycle.
//
// Blackboard in: depositAmount (int, deposit per cycle)
// Returns: always "success" (one deposit, then the loop advances)
//
// This is the lesson of the BT exercise: a ScriptTask is where the generic tree
// (MoveTo/Wait) meets game-specific state (the gold economy on RTSHUDController).

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../controllers/RTSHUDController.mt";

@Script
public class DepositGold {
    private int selfId;
    private int hudId;
    private RTSHUDController? hudRef;

    public constructor() {
        this.selfId = -1;
        this.hudId = -1;
        this.hudRef = null;
    }

    public function onStart(): void {
        this.selfId = Entity::self();
        this.hudId = Entity::findByName("RTS_HUD_Controller");
    }

    // Required by the @Script contract (every @Script class must declare onUpdate),
    // but NEVER called for a BT ScriptTask -- the behavior-tree runtime drives this
    // class through tick() below, not the ECS per-frame onUpdate. Kept empty.
    public function onUpdate(float deltaTime): void {
    }

    // BT ScriptTask contract: the runtime calls `tick` and reads the returned status.
    // Return "success" so the parent Sequence advances and the Repeater starts the
    // next mine -> return -> deposit cycle.
    public function tick(float deltaTime): string {
        RTSHUDController? hud = this.hud();
        if (hud != null) {
            int amount = Blackboard::getInt(this.selfId, "depositAmount");
            if (amount <= 0) {
                amount = 10;
            }
            hud.addGold(amount);
        }
        return "success";
    }

    public function onDestroy(): void {
    }

    // Resolve the HUD controller once and cache it (it owns the gold counter).
    private function hud(): RTSHUDController? {
        if (this.hudRef == null && this.hudId >= 0) {
            this.hudRef = Entity::getScript<RTSHUDController>(this.hudId, "RTSHUDController");
        }
        return this.hudRef;
    }
}
