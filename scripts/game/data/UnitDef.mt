// UnitDef - per-trainable-unit definition (cost / build time / prefab / icon).
//
// Replaces the four parallel string-keyed if-chains (unitPrefab / unitCost /
// unitTime / iconForType) that BuildingCommandController used to look up unit
// data. One UnitDef[] table is built once and scanned by type, so all the
// per-unit tuning lives in a single place.
//
// value class (like BuildingDef): immutable config, default constructor so
// `new UnitDef[n]` can default-init its elements.

value class UnitDef {
    public string unitType;   // "Soldier" | "Engineer" | "Tank" | "Harvester"
    public int cost;          // gold
    public float buildTime;   // seconds in the production queue
    public string prefab;     // .vfPrefab to instantiate
    public string icon;       // .vfImage shown in the queue HUD + selection portrait
    public float maxHealth;   // full HP the spawned unit's Health component starts at (VK-1302)
    // Attack damage per shot for combat units (> 0); non-combat units (Engineer,
    // Track) are 0.0 and get no Attack component at spawn. Drives the runtime
    // RTSGameplay Attack component (damage field) set in BuildingCommandController.
    public float damage;

    constructor(string unitType, int cost, float buildTime, string prefab, string icon, float maxHealth, float damage) {
        this.unitType = unitType;
        this.cost = cost;
        this.buildTime = buildTime;
        this.prefab = prefab;
        this.icon = icon;
        this.maxHealth = maxHealth;
        this.damage = damage;
    }

    // Default constructor so `new UnitDef[n]` can default-init its elements.
    constructor() {
        this.unitType = "";
        this.cost = 0;
        this.buildTime = 0.0;
        this.prefab = "";
        this.icon = "";
        this.maxHealth = 1.0;
        this.damage = 0.0;
    }
}
