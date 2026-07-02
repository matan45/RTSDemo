// ProjectilePool - one shared cosmetic-tracer pool for the whole match.
//
// Lives as a script component on the GameSystems entity. Every soldier finds it
// once (Entity::findByName("GameSystems") + getScript) and calls fire(); no soldier
// owns bullets anymore. Bullets are allocated LAZILY up to `cap` and reused
// round-robin, so the scene holds at most `cap` bullet entities regardless of how
// many soldiers are firing -- instead of bulletPoolSize * soldiers.
//
// Damage stays instant hit-scan in SoldierCombatController.applyShotDamage; these
// bullets are purely visual (see ProjectileController).

import * from "../../lib/engine/oop/PrefabRef.mt";
import * from "../../lib/engine/oop/GameObject.mt";
import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "./ProjectileController.mt";

@Script
class ProjectilePool extends Behaviour {
    private PrefabRef bulletPrefab;
    private int cap;
    private int[] pool;   // entity ids, -1 = not yet spawned
    private int next;     // round-robin cursor into pool

    public constructor() : super() {
        this.bulletPrefab = new PrefabRef("assets/units/soldier/bullet_prefab.vfPrefab");
        // Shared across all soldiers. A tracer's flight is short (<= ProjectileController
        // maxLifetime), so a few dozen in flight at once is ample even for a large army.
        this.cap = 32;
        this.pool = new int[32];
        this.next = 0;
    }

    public function onStart(): void {
        for (int i = 0; i < this.cap; i = i + 1) {
            this.pool[i] = -1;
        }
    }

    public function onUpdate(float deltaTime): void {
    }

    // Fire one cosmetic tracer from `from` toward `targetId`. Lazily allocates the
    // next pool slot on first use (and re-allocates if a bullet was destroyed), then
    // reuses it. No-op on instantiate failure.
    public function fire(Vec3f fromFire, int targetId): void {
        int slot = this.next;
        this.next = (this.next + 1) % this.cap;

        int b = this.pool[slot];
        if (b < 0 || !GameObject::fromId(b).exists()) {
            GameObject? bullet = this.bulletPrefab.instantiate();
            if (bullet == null) {
                return;
            }
            b = bullet.id;
            this.pool[slot] = b;
        }

        GameObject bulletGo = GameObject::fromId(b);
        bulletGo.setActive(true);
        ProjectileController? pc =
            bulletGo.getScript<ProjectileController>("ProjectileController");
        if (pc != null) {
            pc.activate(fromFire, targetId);
        } else {
            // No controller resolved (shouldn't happen): seat it and park so it doesn't
            // sit visible at the origin.
            bulletGo.transform().setLocalPosition(fromFire);
            bulletGo.setActive(false);
        }
    }

    public function onDestroy(): void {
        // Tear down all pooled bullets on match end so they don't linger.
        for (int i = 0; i < this.cap; i = i + 1) {
            int b = this.pool[i];
            if (b >= 0 && GameObject::fromId(b).exists()) {
                GameObject::fromId(b).destroy();
            }
            this.pool[i] = -1;
        }
    }
    

}
