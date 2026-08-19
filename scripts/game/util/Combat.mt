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
// Also the single home of the "who should I shoot" scan (VK-1298 slice 1):
// findNearestHostile is shared by the enemy guards' AcquireTarget BT task and the
// player soldiers' auto-acquire, so both sides use identical, TEAM-RELATIVE rules.
//
// Usage:
//   int r = Combat::applyDamage(target, 25.0);  // KILLED / SURVIVED / NO_HEALTH
//   if (Combat::isAlive(target)) { /* still standing */ }
//   float hp = Combat::getHP(target);
//   int foe = Combat::findNearestHostile(selfId, x, z, 22.0);

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/math/Vec3f.mt";

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

    // Nearest LIVING entity hostile to `selfId` within `range` of the world XZ point
    // (ox, oz). Returns -1 when nothing qualifies.
    //
    // "Hostile" is TEAM-RELATIVE, not hard-coded to the player: it compares each
    // candidate against selfId's own Team.teamId. That is what lets one scan serve
    // both sides -- an enemy guard hunting player units and a player soldier
    // auto-acquiring the wave that just walked into it. An entity with no Team
    // component (terrain props, gold nodes) is never hostile, and neither is one
    // without Health, because isAlive() requires the component.
    //
    // The scan CENTRE is a parameter rather than selfId's own position because a
    // leashed guard scans around its POST, not its feet -- a target that wanders out
    // of the post's bubble must be dropped so the guard walks home (see
    // ai/AcquireTarget.mt). Callers that want a self-centred scan pass their own x/z.
    public static function findNearestHostile(int selfId, float ox, float oz, float range): int {
        if (!PluginComponent::has(selfId, "Team")) {
            return -1;
        }
        int myTeam = PluginComponent::getInt(selfId, "Team", "teamId");

        int best = -1;
        float bestSq = range * range;
        int[] ids = PluginComponent::findAll("Team");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (id == selfId) {
                continue;
            }
            if (!Entity::isValid(id) || !Entity::isActive(id)) {
                continue;
            }
            if (PluginComponent::getInt(id, "Team", "teamId") == myTeam) {
                continue;
            }
            if (!Combat::isAlive(id)) {
                continue;
            }
            Vec3f p = Entity::getPosition(id);
            float dx = p.x - ox;
            float dz = p.z - oz;
            float d = dx * dx + dz * dz;
            if (d < bestSq) {
                best = id;
                bestSq = d;
            }
        }
        return best;
    }
}
