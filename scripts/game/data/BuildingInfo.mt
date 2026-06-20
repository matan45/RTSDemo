// BuildingInfo - per-building presentation/data for the selection panel (VK-1348).
//
// The engine exposes no Faction/production component to mType, so each selectable
// building's display data lives here instead. SelectionController keeps one
// BuildingInfo per registered building; RTSHUDController reads the selected one
// each frame to drive the portrait icon, name, health bar, and command card.
//
// Health is now backed by the RTSGameplay plugin's Health component for player
// buildings: placement sets entityId, and healthFraction() reads currentHP/maxHP
// live so the HUD bar reflects real damage. The currentHealth/maxHealth fields
// remain as a fallback for buildings registered without a Health component
// (entityId < 0 or no component, e.g. enemy stubs), keeping nothing broken.
//
// Regular class (not `value class`) so getSelectedInfo() hands back a shared
// reference the HUD can read without copying.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/PluginComponent.mt";

class BuildingInfo {
    public string buildingType;   // "CommandCenter" | "Barracks" | "Refinery" | "Power" ...
    public string displayName;    // shown in RTS_HUD_SelectionName
    public string iconPath;       // .vfImage asset path for the portrait (RTS_HUD_SelectionIcon)

    public int faction;           // 0 = player, 1 = enemy, 2 = neutral
    public float maxHealth;        // fallback max when no Health component (see healthFraction)
    public float currentHealth;    // fallback current when no Health component
    public int entityId;           // the building's entity id (-1 = unset); drives live Health reads

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
        this.entityId = -1;
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
        this.entityId = -1;
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

    // Live health fraction backed by the plugin Health component when this
    // building has one (single source of truth, so Combat::applyDamage shows up
    // on the bar). Falls back to the currentHealth/maxHealth fields when the
    // entity is gone or carries no Health component (e.g. enemy stubs).
    public function healthFraction(): float {
        if (this.entityId >= 0 && Entity::isValid(this.entityId) && PluginComponent::has(this.entityId, "Health")) {
            float maxHP = PluginComponent::getFloat(this.entityId, "Health", "maxHP");
            if (maxHP <= 0.0) {
                return 0.0;
            }
            float curHP = PluginComponent::getFloat(this.entityId, "Health", "currentHP");
            return curHP / maxHP;
        }
        if (this.maxHealth <= 0.0) {
            return 0.0;
        }
        return this.currentHealth / this.maxHealth;
    }
}
