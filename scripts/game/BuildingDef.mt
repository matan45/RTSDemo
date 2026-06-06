// BuildingDef - per-build-slot definition for the placement widget (VK-1311).
//
// Encapsulates everything that differs between buildable types: the prefab
// asset (mesh + material + collider authored together), the real (untinted)
// material used to restore the ghost on confirm, the footprint half-extents
// (X/Z, pre-rotation), the gold cost, the power delta (+ produces /
// - consumes), and (VK-1348) the selection-panel display data
// (type/name/icon/health).
// BuildingPlacementController holds one per RTS_HUD_BuildSlot and reads the
// display fields to mint a BuildingInfo for each placed building.

value class BuildingDef {
    // prefabPath / materialPath accept project-relative, forward-slash asset
    // paths (VK-1346), e.g. "assets/buildings/barracks_prefab.vfPrefab".
    // Absolute paths still work but are not portable across machines.
    // materialPath is the prefab's own material instance: the ghost wears a
    // tint material while placing, and this is swapped back on confirm.
    public string prefabPath;
    public string materialPath;
    public float halfX;
    public float halfZ;
    public int cost;

    // Net power contribution once placed: power plants positive, everything
    // else negative (consumption). Summed into GameState.power on placement.
    public int power;

    // Selection-panel display (VK-1348). iconPath is an imported .vfImage.
    public string displayType;
    public string displayName;
    public string iconPath;
    public float maxHealth;

    constructor(string prefabPath, string materialPath, float halfX, float halfZ, int cost, int power,
                string displayType, string displayName, string iconPath, float maxHealth) {
        this.prefabPath = prefabPath;
        this.materialPath = materialPath;
        this.halfX = halfX;
        this.halfZ = halfZ;
        this.cost = cost;
        this.power = power;
        this.displayType = displayType;
        this.displayName = displayName;
        this.iconPath = iconPath;
        this.maxHealth = maxHealth;
    }

    // Default constructor so `new BuildingDef[n]` can default-init its elements.
    constructor() {
        this.prefabPath = "";
        this.materialPath = "";
        this.halfX = 0.0;
        this.halfZ = 0.0;
        this.cost = 0;
        this.power = 0;
        this.displayType = "";
        this.displayName = "";
        this.iconPath = "";
        this.maxHealth = 1.0;
    }
}
