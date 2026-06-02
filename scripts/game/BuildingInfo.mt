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

    // Stub command labels for the command card (empty for non-player buildings,
    // which render read-only). Hooked up to real production in VK-1312.
    public string[] commands;

    constructor(string buildingType, string displayName, string iconPath,
                int faction, float maxHealth, string[] commands) {
        this.buildingType = buildingType;
        this.displayName = displayName;
        this.iconPath = iconPath;
        this.faction = faction;
        this.maxHealth = maxHealth;
        this.currentHealth = maxHealth;
        this.commands = commands;
    }

    // Default constructor so `new BuildingInfo[n]` can default-init its elements.
    constructor() {
        this.buildingType = "";
        this.displayName = "";
        this.iconPath = "";
        this.faction = 0;
        this.maxHealth = 1.0;
        this.currentHealth = 1.0;
        this.commands = new string[0];
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
