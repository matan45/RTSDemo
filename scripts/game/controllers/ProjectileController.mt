// ProjectileController - cosmetic tracer/bullet flown from a soldier's muzzle to
// its target (VK-1427 Phase 6). Purely visual: the actual damage stays instant
// hit-scan in SoldierCombatController.applyShotDamage on the "Shoot" animation
// event. This script only flies the bullet mesh and parks it back for reuse.
//
// One instance lives on each pooled bullet prefab (see bullet_prefab.vfPrefab).
// The pool owner (SoldierCombatController) drives the lifecycle:
//
//   1. setActive(bulletId, true)
//   2. getScript<ProjectileController>(bulletId, "ProjectileController").activate(from, targetId)
//
// activate() snapshots the spawn point and the target id, then onUpdate flies the
// bullet toward the target (re-reading the target position each frame so it tracks
// a moving unit) until it hits, the target is lost, or the lifetime cap elapses.
// On any of those it parks itself (setActive(false)) — it is NEVER destroyed in
// the hot path, so the pool can reuse it on the next shot.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/math/Vec3f.mt";

@Script
class ProjectileController {
    private int selfId;

    // Target entity id the tracer flies toward (-1 = none / parked). When the
    // target despawns mid-flight we fall back to the last-known aim point so the
    // bullet still completes a visible arc instead of freezing.
    private int targetId;
    private Vec3f aimPoint;
    private bool active;

    // ---- tuning ----

    // World units per second the tracer travels.
    private float speed;
    // Distance (squared) at/under which the tracer is considered to have hit and
    // is parked.
    private float hitRadiusSq;
    // Hard cap (seconds) after which the tracer parks itself even if it never
    // reaches the target, so a lost/teleported target can't leak a live bullet.
    private float maxLifetime;
    private float age;

    constructor() {
        this.selfId = -1;
        this.targetId = -1;
        this.aimPoint = new Vec3f(0.0, 0.0, 0.0);
        this.active = false;

        this.speed = 120.0;
        this.hitRadiusSq = 1.5 * 1.5;
        this.maxLifetime = 2.0;
        this.age = 0.0;
    }

    public function onStart(): void {
        this.selfId = Entity::self();
        // Bullets are pre-spawned parked; stay parked until the pool activates us.
        this.active = false;
    }

    // Begin (or restart) a flight. Called by the pool owner right after it sets the
    // bullet active. `from` is the muzzle world position; `target` is the entity to
    // fly toward (its live position is tracked each frame).
    public function activate(Vec3f from, int target): void {
        if (this.selfId < 0) {
            this.selfId = Entity::self();
        }
        Entity::setPosition(this.selfId, from);
        this.targetId = target;
        this.age = 0.0;
        this.active = true;

        // Seed the aim point so we have a valid heading even on the first frame and
        // a fallback if the target vanishes before we read it again.
        if (target >= 0 && Entity::isValid(target)) {
            this.aimPoint = Entity::getPosition(target);
        } else {
            // No valid target: aim straight ahead of the muzzle a short way so the
            // tracer still flies out and parks on the lifetime cap.
            this.aimPoint = from;
        }
    }

    public function onUpdate(float deltaTime): void {
        if (!this.active || this.selfId < 0) {
            return;
        }

        this.age = this.age + deltaTime;
        if (this.age >= this.maxLifetime) {
            this.park();
            return;
        }

        // Track a live target; keep the last-known aim point once it despawns.
        if (this.targetId >= 0 && Entity::isValid(this.targetId)) {
            this.aimPoint = Entity::getPosition(this.targetId);
        }

        Vec3f pos = Entity::getPosition(this.selfId);
        Vec3f toAim = this.aimPoint.subtract(pos);
        float distSq = toAim.lengthSquared();

        // Reached the target (or its last-known spot) -> park.
        if (distSq <= this.hitRadiusSq) {
            this.park();
            return;
        }

        // Advance frame-independently, clamping the step so we don't overshoot past
        // the aim point in a single long frame.
        float step = this.speed * deltaTime;
        float stepSq = step * step;
        if (stepSq >= distSq) {
            Entity::setPosition(this.selfId, this.aimPoint);
            this.park();
            return;
        }
        Vec3f dir = toAim.normalize();
        Entity::setPosition(this.selfId, pos.add(dir.multiply(step)));
    }

    // Park the bullet back into the pool: clear state and deactivate. Never
    // destroys the entity, so the owner can reuse this slot on the next shot.
    private function park(): void {
        this.active = false;
        this.targetId = -1;
        this.age = 0.0;
        if (this.selfId >= 0) {
            Entity::setActive(this.selfId, false);
        }
    }

    public function onDestroy(): void {
        this.active = false;
    }
}
