// Combat - damage + health queries answered by the RTSGameplay plugin (VK-1404).
//
// applyDamage routes through the plugin's _rts_apply_damage native, which mutates
// the target's Health component and publishes "rts.unit_killed" {entity:id} on a
// kill — it never destroys the entity, so combat scripts own death/cleanup by
// reacting to that event. Health getters read the plugin Health component fields
// through the generic PluginComponent accessors (no extra native needed).
//
// Lives in game/util/ alongside RTSFog.mt because it wraps an RTSGameplay *plugin*
// native, not an engine API (those live in lib/engine/).
//
// Usage:
//   int r = Combat::applyDamage(target, 25.0);  // KILLED / SURVIVED / NO_HEALTH
//   if (Combat::isAlive(target)) { /* still standing */ }
//   float hp = Combat::getHP(target);

import * from "../../lib/engine/PluginComponent.mt";

public class Combat {
    // Mirrors DamageResult in the plugin's CombatRules.hpp.
    public static final int NO_HEALTH = -1;
    public static final int SURVIVED = 0;
    public static final int KILLED = 1;

    public constructor() {
    }

    // Apply `amount` damage to `targetId`'s Health. Returns KILLED if this hit
    // dropped it to 0, SURVIVED if it lived (or amount <= 0), NO_HEALTH if the
    // target is invalid or has no Health component.
    public static function applyDamage(int targetId, float amount): int {
        return _rts_apply_damage(targetId, amount);
    }

    // Current hit points (0.0 if the target has no Health component).
    public static function getHP(int targetId): float {
        return PluginComponent::getFloat(targetId, "Health", "currentHP");
    }

    // Maximum hit points (0.0 if the target has no Health component).
    public static function getMaxHP(int targetId): float {
        return PluginComponent::getFloat(targetId, "Health", "maxHP");
    }

    // True while the target has a Health component with currentHP above 0.
    public static function isAlive(int targetId): bool {
        if (!PluginComponent::has(targetId, "Health")) {
            return false;
        }
        return PluginComponent::getFloat(targetId, "Health", "currentHP") > 0.0;
    }
}
