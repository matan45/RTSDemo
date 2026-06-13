// PlacedBuilding - one placed building's footprint (for overlap testing).
//
// Replaces the four parallel arrays (placedCenters / placedHalfX / placedHalfZ
// / placedEntityIds) BuildingPlacementController used to track placed
// footprints. A regular (reference) class so swap-remove (when a building is
// sold) moves a single reference instead of four fields in lockstep.

import * from "../../lib/math/Vec3f.mt";

class PlacedBuilding {
    public Vec3f center;
    public float halfX;   // rotation-adjusted footprint half-extents
    public float halfZ;
    public int entityId;

    constructor(Vec3f center, float halfX, float halfZ, int entityId) {
        this.center = center;
        this.halfX = halfX;
        this.halfZ = halfZ;
        this.entityId = entityId;
    }

    constructor() {
        this.center = new Vec3f(0.0, 0.0, 0.0);
        this.halfX = 0.0;
        this.halfZ = 0.0;
        this.entityId = -1;
    }
}
