// UnitInfo - per-unit presentation/data for the selection panel (VK-1302).
//
// The engine exposes no Faction component to mType, so a selected unit's display
// data (portrait icon, name) lives here, mirroring BuildingInfo for buildings.
// BuildingCommandController creates one per unit it spawns and registers it with
// UnitSelectionController; that controller pushes the primary-selected unit's
// UnitInfo into SelectionController, which the HUD already reads to drive the
// RTS_HUD_Selection* panel.
//
// Health is now backed by the RTSGameplay plugin's Health component: spawn sets
// entityId, and healthFraction() reads currentHP/maxHP live so the HUD bar
// reflects real damage (Combat::applyDamage). The currentHealth/maxHealth fields
// remain as a fallback for units registered without a Health component (entityId
// < 0 or no component), keeping nothing broken before every spawn path is wired.
//
// Regular class (not `value class`) so the registry hands back a shared
// reference the HUD can read without copying.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/PluginComponent.mt";

class UnitInfo {
    public string displayName;   // shown in RTS_HUD_SelectionName (e.g. "Soldier")
    public string iconPath;      // .vfImage portrait (RTS_HUD_SelectionIcon)
    public int faction;          // 0 = player, 1 = enemy
    public float maxHealth;      // fallback max when no Health component (see healthFraction)
    public float currentHealth;  // fallback current when no Health component
    public int entityId;         // the spawned unit's entity id (-1 = unset); drives live Health reads

    constructor(string displayName, string iconPath, int faction, float maxHealth) {
        this.displayName = displayName;
        this.iconPath = iconPath;
        this.faction = faction;
        this.maxHealth = maxHealth;
        this.currentHealth = maxHealth;
        this.entityId = -1;
    }

    // Default constructor so `new UnitInfo[n]` can default-init its elements.
    constructor() {
        this.displayName = "";
        this.iconPath = "";
        this.faction = 0;
        this.maxHealth = 1.0;
        this.currentHealth = 1.0;
        this.entityId = -1;
    }

    public function isPlayer(): bool {
        return this.faction == 0;
    }

    // Live health fraction backed by the plugin Health component when this unit
    // has one (single source of truth, so Combat::applyDamage shows up on the
    // bar). Falls back to the currentHealth/maxHealth fields when the entity is
    // gone or carries no Health component.
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
