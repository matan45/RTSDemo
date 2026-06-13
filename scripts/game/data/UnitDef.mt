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
    public string icon;       // .vfImage shown in the queue HUD

    constructor(string unitType, int cost, float buildTime, string prefab, string icon) {
        this.unitType = unitType;
        this.cost = cost;
        this.buildTime = buildTime;
        this.prefab = prefab;
        this.icon = icon;
    }

    // Default constructor so `new UnitDef[n]` can default-init its elements.
    constructor() {
        this.unitType = "";
        this.cost = 0;
        this.buildTime = 0.0;
        this.prefab = "";
        this.icon = "";
    }
}
