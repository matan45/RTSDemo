// BuildingInfo - per-building presentation/data for the selection panel (VK-1348).
//
// The engine exposes no Health/Faction/production components to mType, so each
// selectable building's display data lives here instead. SelectionController keeps
// one BuildingInfo per registered building; RTSHUDController reads the selected
// one each frame to drive the portrait icon, name, health bar, and command card.
//
// Regular class (not `value class`) so getSelectedInfo() hands back a shared
// reference the HUD can read without copying.

class BuildingInfo {
    public string buildingType;   // "CommandCenter" | "Barracks" | "Refinery" | "Power" ...
    public string displayName;    // shown in RTS_HUD_SelectionName
    public string iconPath;       // .vfImage asset path for the portrait (RTS_HUD_SelectionIcon)

    public int faction;           // 0 = player, 1 = enemy, 2 = neutral
    public float maxHealth;
    public float currentHealth;

    // Gold cost + net power delta this building was placed with (copied from its
    // BuildingDef by BuildingPlacementController). Sell refunds 70% of cost and
    // reverses power; Upgrade scales off cost. level: 0 = base, 1 = upgraded.
    public int cost;
    public int power;
    public int level;

    // Command labels for the command card (empty for non-player buildings, which
    // render read-only). Per-building-type lists come from
    // BuildingPlacementController.commandsForType(); BuildingCommandController
    // executes the label clicked.
    public string[] commands;

    // Footprint half-extents (world units, rotation-adjusted) driving the
    // selection-highlight decal size. Set by BuildingPlacementController on
    // placement; the 4.0 default covers buildings registered without one.
    public float halfX;
    public float halfZ;

    constructor(string buildingType, string displayName, string iconPath,
                int faction, float maxHealth, string[] commands) {
        this.buildingType = buildingType;
        this.displayName = displayName;
        this.iconPath = iconPath;
        this.faction = faction;
        this.maxHealth = maxHealth;
        this.currentHealth = maxHealth;
        this.cost = 0;
        this.power = 0;
        this.level = 0;
        this.commands = commands;
        this.halfX = 4.0;
        this.halfZ = 4.0;
    }

    // Default constructor so `new BuildingInfo[n]` can default-init its elements.
    constructor() {
        this.buildingType = "";
        this.displayName = "";
        this.iconPath = "";
        this.faction = 0;
        this.maxHealth = 1.0;
        this.currentHealth = 1.0;
        this.cost = 0;
        this.power = 0;
        this.level = 0;
        this.commands = new string[0];
        this.halfX = 4.0;
        this.halfZ = 4.0;
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
