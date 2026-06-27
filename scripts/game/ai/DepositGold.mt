// DepositGold - BT ScriptTask: a harvester reached its refinery; bank the gold
// (VK-1447). Resolves the HUD controller once and adds the per-unit deposit amount
// carried on the blackboard. Instant -- returns "success" so the HarvesterLoop
// sequence advances back to the mining leg.
//
// Blackboard in: depositAmount (float)
// Returns: "success" always

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../controllers/RTSHUDController.mt";

@Script
public class DepositGold {
    private int selfId;
    private RTSHUDController? hud;

    public constructor() {
        this.selfId = -1;
        this.hud = null;
    }

    public function onStart(): void {
        this.selfId = Entity::self();
        int hudId = Entity::findByName("RTS_HUD_Controller");
        if (hudId >= 0) {
            this.hud = Entity::getScript<RTSHUDController>(hudId, "RTSHUDController");
        }
    }

    public function tick(float deltaTime): string {
        RTSHUDController? h = this.hud;
        if (h != null) {
            int amount = (int)Blackboard::getFloat(this.selfId, "depositAmount");
            if (amount > 0) {
                h.addGold(amount);
            }
        }
        return "success";
    }

    public function onDestroy(): void {
    }
}
