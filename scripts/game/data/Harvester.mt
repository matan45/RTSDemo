// Harvester - one active resource harvester (refinery <-> nearest GoldNode).
//
// Replaces the six parallel arrays (harvId / harvRefinery / harvMine /
// harvHome / harvState / harvDwell) BuildingCommandController used to track
// harvesters. A regular (reference) class so an array element can be mutated in
// place each tick. `state` uses the HState constants.

import * from "../../lib/math/Vec3f.mt";

class Harvester {
    public int unitId;
    public int refineryId;
    public Vec3f minePos;
    public Vec3f homePos;
    public int state;    // HState::TO_MINE / MINING / TO_HOME / DEPOSIT
    public float dwell;  // seconds remaining while MINING

    constructor(int unitId, int refineryId, Vec3f minePos, Vec3f homePos) {
        this.unitId = unitId;
        this.refineryId = refineryId;
        this.minePos = minePos;
        this.homePos = homePos;
        this.state = 0;   // == HState::TO_MINE
        this.dwell = 0.0;
    }

    constructor() {
        this.unitId = -1;
        this.refineryId = -1;
        this.minePos = new Vec3f(0.0, 0.0, 0.0);
        this.homePos = new Vec3f(0.0, 0.0, 0.0);
        this.state = 0;
        this.dwell = 0.0;
    }
}
