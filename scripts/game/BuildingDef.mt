// BuildingDef - per-build-slot definition for the placement widget (VK-1311).
//
// Encapsulates everything that differs between buildable types: the mesh and
// material assets, the footprint half-extents (X/Z, pre-rotation), the gold
// cost, and (VK-1348) the selection-panel display data (type/name/icon/health).
// BuildingPlacementController holds one per RTS_HUD_BuildSlot and reads the
// display fields to mint a BuildingInfo for each placed building.

value class BuildingDef {
    // meshPath / materialPath accept project-relative, forward-slash asset
    // paths (VK-1346), e.g. "assets/buildings/Barracks.vfMesh". Absolute paths
    // still work but are not portable across machines.
    public string meshPath;
    public string materialPath;
    public float halfX;
    public float halfZ;
    public int cost;

    // Selection-panel display (VK-1348). iconPath is an imported .vfImage.
    public string displayType;
    public string displayName;
    public string iconPath;
    public float maxHealth;

    constructor(string meshPath, string materialPath, float halfX, float halfZ, int cost,
                string displayType, string displayName, string iconPath, float maxHealth) {
        this.meshPath = meshPath;
        this.materialPath = materialPath;
        this.halfX = halfX;
        this.halfZ = halfZ;
        this.cost = cost;
        this.displayType = displayType;
        this.displayName = displayName;
        this.iconPath = iconPath;
        this.maxHealth = maxHealth;
    }

    // Default constructor so `new BuildingDef[n]` can default-init its elements.
    constructor() {
        this.meshPath = "";
        this.materialPath = "";
        this.halfX = 0.0;
        this.halfZ = 0.0;
        this.cost = 0;
        this.displayType = "";
        this.displayName = "";
        this.iconPath = "";
        this.maxHealth = 1.0;
    }
}
