// BuildingDef - per-build-slot definition for the placement widget (VK-1311).
//
// Encapsulates everything that differs between buildable types: the mesh and
// material assets, the footprint half-extents (X/Z, pre-rotation), and the gold
// cost. BuildingPlacementController holds one per RTS_HUD_BuildSlot.

value class BuildingDef {
    // meshPath / materialPath accept project-relative, forward-slash asset
    // paths (VK-1346), e.g. "assets/buildings/Barracks.vfMesh". Absolute paths
    // still work but are not portable across machines.
    public string meshPath;
    public string materialPath;
    public float halfX;
    public float halfZ;
    public int cost;

    constructor(string meshPath, string materialPath, float halfX, float halfZ, int cost) {
        this.meshPath = meshPath;
        this.materialPath = materialPath;
        this.halfX = halfX;
        this.halfZ = halfZ;
        this.cost = cost;
    }

    // Default constructor so `new BuildingDef[n]` can default-init its elements.
    constructor() {
        this.meshPath = "";
        this.materialPath = "";
        this.halfX = 0.0;
        this.halfZ = 0.0;
        this.cost = 0;
    }
}
