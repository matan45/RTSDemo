// UnitInfo - per-unit presentation/data for the selection panel (VK-1302).
//
// The engine exposes no Health/Faction components to mType, so a selected
// unit's display data (portrait icon, name, health) lives here, mirroring
// BuildingInfo for buildings. BuildingCommandController creates one per unit it
// spawns and registers it with UnitSelectionController; that controller pushes
// the primary-selected unit's UnitInfo into SelectionController, which the HUD
// already reads to drive the RTS_HUD_Selection* panel.
//
// Regular class (not `value class`) so the registry hands back a shared
// reference the HUD can read without copying, and so currentHealth can be
// mutated in place once a damage system (future) lands. Until then health is
// full (stub-then-replace: the public API is stable, only the internals fill in).

class UnitInfo {
    public string displayName;   // shown in RTS_HUD_SelectionName (e.g. "Soldier")
    public string iconPath;      // .vfImage portrait (RTS_HUD_SelectionIcon)
    public int faction;          // 0 = player, 1 = enemy
    public float maxHealth;
    public float currentHealth;  // starts full; no damage system yet (VK-1302 stub)

    constructor(string displayName, string iconPath, int faction, float maxHealth) {
        this.displayName = displayName;
        this.iconPath = iconPath;
        this.faction = faction;
        this.maxHealth = maxHealth;
        this.currentHealth = maxHealth;
    }

    // Default constructor so `new UnitInfo[n]` can default-init its elements.
    constructor() {
        this.displayName = "";
        this.iconPath = "";
        this.faction = 0;
        this.maxHealth = 1.0;
        this.currentHealth = 1.0;
    }

    public function isPlayer(): bool {
        return this.faction == 0;
    }

    public function healthFraction(): float {
        if (this.maxHealth <= 0.0) {
            return 0.0;
        }
        return this.currentHealth / this.maxHealth;
    }
}
