// SoldierCombatController - per-unit animation + combat state machine for the
// soldier (VK-1402/1403/1404 demo wiring).
//
// One instance of this @Script lives on each soldier prefab root. It drives the
// soldier.vfAnimator parameters (IsMoving / IsFiring) and spawns a muzzle-flash
// VFX at the rifle barrel on every "Shoot" animation event, based on the order
// it is given:
//
//   idle   - no order, agent at rest        -> IsMoving=false, IsFiring=false
//   move   - moving under a move order       -> IsMoving=true,  IsFiring=false
//   chase  - has an attack target out of range-> IsMoving=true,  IsFiring=false
//   fire   - has an attack target in range    -> IsMoving=false, IsFiring=true
//            (stop-and-shoot, auto-repeats while the target stays in range)
//
// The order is set externally by BuildingCommandController.handleMoveCommand on
// a right-click: an enemy hit calls setTarget(enemyId); a ground click calls
// setTarget(-1). The right-click router reaches this script via
// Entity::getScript<SoldierCombatController>(unitId, "SoldierCombatController").
//
// Movement state is read back from the NavmeshAgent velocity, so plain move
// orders (issued by the router via Navmesh::moveTo) still animate as Run with no
// extra bookkeeping. Attach this @Script to the soldier prefab root alongside
// MeshComponent(animatorRef=soldier.vfAnimator) + NavmeshAgent.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Animator.mt";
import * from "../../lib/engine/Socket.mt";
import * from "../../lib/engine/VFX.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/Config.mt";
import * from "../util/Combat.mt";
import * from "./ProjectileController.mt";

@Script
class SoldierCombatController {
    private int selfId;

    // Current attack target entity id (-1 = none). Set by the right-click router.
    private int targetId;

    // Cached capability flags (resolved once in onStart).
    private bool hasAnim;

    // Last-pushed animator parameter values, so we only call the native on change.
    private bool curMoving;
    private bool curFiring;

    // Chase bookkeeping: the last destination we commanded, so we re-path only
    // when the target has moved far enough (avoids per-frame setDestination churn).
    private Vec3f lastCmd;
    private bool hasMoveOrder;

    // ---- tuning (single-file knobs; shared constants live in Config) ----

    // Horizontal distance at/under which the soldier stops and fires.
    private float fireRange;
    private float fireRangeSq;
    // Hysteresis: once firing, keep firing until the target passes this larger
    // range, so a target hovering near fireRange does not thrash Fire<->Run.
    private float fireExitRangeSq;
    // Beyond this horizontal distance from the soldier the target is abandoned.
    private float giveUpRange;
    private float giveUpRangeSq;
    // Agent speed (squared) above which the soldier is considered "moving".
    private float velEpsSq;
    // While chasing, re-issue the path once the target drifts this far (squared).
    private float reissueDistSq;
    // Damage dealt to the target per "Shoot" animation event (VK-1404). Seeded
    // from the unit's runtime Attack component (damage field) in onStart when
    // present; the value below is the fallback default.
    private float damage;

    // Whether the soldier yaws to face its target while firing. The yaw is driven
    // into the Y euler slot using the engine forward=(-sin,-cos) convention
    // (RTSCameraController); faceYawOffsetDeg corrects for the soldier mesh's
    // local forward axis (try 0 / 90 / 180 / 270 if it aims the wrong way).
    private bool faceTarget;
    private float faceYawOffsetDeg;

    // Muzzle-flash effect spawned at the "Muzzle" socket on each Shoot event.
    // Project-relative path; the .vfVFX must exist in the RTSDemo asset tree.
    private string muzzleVfx;

    // Cached id of this soldier's AK-47 child entity (the static weapon mesh that
    // carries the "Muzzle" socket), resolved once in onStart. -1 until found / if
    // the prefab has no "AK47" child.
    private int ak47Id;

    // ---- cosmetic tracer pool (VK-1427 Phase 6) ----
    // A small per-soldier free-list of pooled bullet entities flown from the muzzle
    // to the target on each Shoot event. Cosmetic only -- damage stays instant
    // hit-scan in applyShotDamage. A soldier only has a couple of tracers in flight
    // at once (short flight time, one shot per Shoot event), so a tiny ring is
    // plenty and never creates/destroys in the hot path.
    private string bulletPrefab;
    private int bulletPoolSize;
    private int[] bulletPool;   // entity ids, -1 = not yet spawned
    private int bulletNext;     // round-robin cursor into bulletPool

    constructor() {
        this.selfId = -1;
        this.targetId = -1;
        this.hasAnim = false;
        this.curMoving = false;
        this.curFiring = false;
        this.lastCmd = new Vec3f(0.0, 0.0, 0.0);
        this.hasMoveOrder = false;

        this.fireRange = 14.0;
        this.fireRangeSq = 14.0 * 14.0;
        this.fireExitRangeSq = 16.0 * 16.0;
        this.giveUpRange = 80.0;
        this.giveUpRangeSq = 80.0 * 80.0;
        this.velEpsSq = 0.04;            // ~0.2 units/s
        this.reissueDistSq = 4.0;        // re-path if target moved > 2 units
        this.damage = 10.0;              // HP per Shoot event
        this.faceTarget = true;
        this.faceYawOffsetDeg = 0.0;
        this.muzzleVfx = "assets/units/soldier/fire.vfVFX";

        this.ak47Id = -1;
        this.bulletPrefab = "assets/units/soldier/bullet_prefab.vfPrefab";
        this.bulletPoolSize = 6;
        this.bulletPool = new int[6];
        this.bulletNext = 0;
    }

    public function onStart(): void {
        this.selfId = Entity::self();
        this.hasAnim = Animator::hasAnimator(this.selfId);

        // Drive per-shot damage from the unit's runtime Attack component when it
        // has one (added at spawn by BuildingCommandController from the UnitDef),
        // so combat tuning lives with the unit data. Falls back to the authored
        // default above when no Attack component is present.
        if (PluginComponent::has(this.selfId, "Attack")) {
            this.damage = PluginComponent::getFloat(this.selfId, "Attack", "damage");
        }

        // Force the initial animator parameters to a known idle state.
        this.curMoving = false;
        this.curFiring = false;
        if (this.hasAnim) {
            Animator::setBool(this.selfId, "IsMoving", false);
            Animator::setBool(this.selfId, "IsFiring", false);
        }

        // Attach the weapon child to the hand socket by entity id. This is done
        // here (not via a baked SocketAttachmentComponent) because socket parent
        // resolution matches by name and the unit root is renamed to "Unit_N" at
        // spawn -- a name-based attachment would never resolve. No-op (returns
        // false) until the "Weapon_R" socket is authored on the soldier mesh.
        int[] kids = Entity::getChildren(this.selfId);
        for (int i = 0; i < kids.length; i = i + 1) {
            if (Entity::getName(kids[i]) == "AK47") {
                this.ak47Id = kids[i];
                Socket::attach(kids[i], this.selfId, "Weapon_R");
            }
        }

        // Mark the cosmetic tracer pool empty. Bullets are allocated LAZILY on the
        // first Shoot event that uses each slot (see spawnProjectile), so spawning a
        // soldier creates zero bullet entities up front -- they only appear once the
        // soldier actually fires, then are reused for the rest of its life.
        for (int i = 0; i < this.bulletPoolSize; i = i + 1) {
            this.bulletPool[i] = -1;
        }

        // The engine's animation-event queue is keyed by entity id for the whole
        // process; discard anything buffered under this id before we started, so a
        // reused id can't surface a stale "Shoot" from a previous play session.
        if (this.hasAnim) {
            string stale = Animator::pollEvent(this.selfId);
            while (stale != "") {
                stale = Animator::pollEvent(this.selfId);
            }
        }
    }

    // Set (or clear, with t < 0) this soldier's attack target. Called by the
    // right-click order router on every selected soldier.
    public function setTarget(int t): void {
        this.targetId = t;
        this.hasMoveOrder = false;   // force a fresh path decision next tick
    }

    public function onUpdate(float deltaTime): void {
        if (this.selfId < 0) {
            return;
        }

        // Drop a dead/despawned target.
        if (this.targetId >= 0 && !Entity::isValid(this.targetId)) {
            this.targetId = -1;
        }

        if (this.targetId >= 0) {
            this.tickCombat();
        } else {
            this.tickIdleOrMove();
        }

        // Muzzle flash: always drain the event FIFO when we have an animator (so
        // it never backs up to its cap), but only spawn when the Muzzle socket
        // exists. Animation events only fire during the Fire state.
        if (this.hasAnim) {
            this.drainShootEvents();
        }
    }

    // ---- states ----

    private function tickCombat(): void {
        Vec3f sp = Entity::getPosition(this.selfId);
        Vec3f tp = Entity::getPosition(this.targetId);
        float dx = tp.x - sp.x;
        float dz = tp.z - sp.z;
        float d2 = dx * dx + dz * dz;

        if (d2 > this.giveUpRangeSq) {
            // Too far to bother; abandon and fall back to idle/move next tick.
            this.targetId = -1;
            this.tickIdleOrMove();
            return;
        }

        // Hysteresis: enter Fire within fireRange, but once firing stay until the
        // target passes the larger fireExitRange (prevents Fire<->Run thrash at the
        // boundary).
        float enterOrStaySq = (this.curFiring) ? this.fireExitRangeSq : this.fireRangeSq;

        if (d2 > enterOrStaySq) {
            // Chase: move toward the target, animate as Run.
            this.setFiring(false);
            this.setMoving(true);
            if (!this.hasMoveOrder || this.lastCmd.distanceSquared(tp) > this.reissueDistSq) {
                Vec3f dest = tp;
                if (!Navmesh::isPointOnNavmesh(dest)) {
                    dest = Navmesh::getClosestPoint(dest);
                }
                Navmesh::moveTo(this.selfId, dest);
                this.lastCmd = tp;
                this.hasMoveOrder = true;
            }
        } else {
            // In range: stop and fire (auto-repeats while in range).
            if (this.hasMoveOrder) {
                Navmesh::stopAgent(this.selfId);
                this.hasMoveOrder = false;
            }
            this.setMoving(false);
            this.setFiring(true);
            if (this.faceTarget) {
                this.faceToward(dx, dz);
            }
        }
    }

    private function tickIdleOrMove(): void {
        this.setFiring(false);
        Vec3f v = Navmesh::getVelocity(this.selfId);
        float speed2 = v.x * v.x + v.z * v.z;
        this.setMoving(speed2 > this.velEpsSq);
        this.hasMoveOrder = false;
    }

    // ---- helpers ----

    private function setMoving(bool m): void {
        if (m != this.curMoving) {
            this.curMoving = m;
            if (this.hasAnim) {
                Animator::setBool(this.selfId, "IsMoving", m);
            }
        }
    }

    private function setFiring(bool f): void {
        if (f != this.curFiring) {
            this.curFiring = f;
            if (this.hasAnim) {
                Animator::setBool(this.selfId, "IsFiring", f);
            }
        }
    }

    // Yaw the soldier to face the (dx,dz) world direction, preserving its
    // authored X/Z rotation. Engine forward = (-sin(yaw), -cos(yaw)).
    private function faceToward(float dx, float dz): void {
        if (dx == 0.0 && dz == 0.0) {
            return;
        }
        float yawRad = atan2(-dx, -dz);
        float yawDeg = yawRad / Config::DEG_TO_RAD + this.faceYawOffsetDeg;
        Vec3f r = Entity::getRotation(this.selfId);
        Entity::setRotation(this.selfId, new Vec3f(r.x, yawDeg, r.z));
    }

    private function drainShootEvents(): void {
        string ev = Animator::pollEvent(this.selfId);
        while (ev != "") {
            if (ev == "Shoot") {
                this.applyShotDamage();      // instant hit-scan (gameplay)
                this.spawnMuzzleFlash();     // cosmetic flash at the barrel
                this.spawnProjectile();      // cosmetic tracer toward the target
            }
            ev = Animator::pollEvent(this.selfId);
        }
    }

    // Spawn a one-shot muzzle-flash VFX at the AK-47's "Muzzle" socket and pin it
    // to that socket so it stays at the barrel even as the weapon animates. No-op
    // until the AK-47 child and its "Muzzle" socket are authored (graceful until
    // the user adds the socket in the editor).
    private function spawnMuzzleFlash(): void {
        if (this.ak47Id < 0 || !Entity::isValid(this.ak47Id)) {
            return;
        }
        if (!Socket::hasSocket(this.ak47Id, "Muzzle")) {
            return;
        }
        Vec3f m = Socket::getPosition(this.ak47Id, "Muzzle");
        int fx = VFX::spawnAt(this.muzzleVfx, m.x, m.y, m.z);
        if (fx != 0) {
            VFX::attachToSocket(fx, this.ak47Id, "Muzzle");
        }
    }

    // Fly a pooled cosmetic tracer from the muzzle toward the current target.
    // Damage is NOT carried by the bullet (it stays instant hit-scan in
    // applyShotDamage); this is purely a visual tracer. No-op until the AK-47 and
    // its "Muzzle" socket are authored, or when there is no valid target.
    private function spawnProjectile(): void {
        if (this.ak47Id < 0 || !Entity::isValid(this.ak47Id)) {
            return;
        }
        if (!Socket::hasSocket(this.ak47Id, "Muzzle")) {
            return;
        }
        if (this.targetId < 0 || !Entity::isValid(this.targetId)) {
            return;
        }

        int slot = this.bulletNext;
        this.bulletNext = (this.bulletNext + 1) % this.bulletPoolSize;

        // Lazily allocate this slot on first use (and re-allocate if its bullet was
        // destroyed). No bullets exist until the soldier actually fires; the pool
        // grows to at most bulletPoolSize and is reused from then on.
        int b = this.bulletPool[slot];
        if (b < 0 || !Entity::isValid(b)) {
            b = Entity::instantiate(this.bulletPrefab);
            if (b < 0) {
                return;   // instantiate failed
            }
            this.bulletPool[slot] = b;
        }

        Vec3f muzzleVec = Socket::getPosition(this.ak47Id, "Muzzle");
        Entity::setActive(b, true);
        ProjectileController? pc =
            Entity::getScript<ProjectileController>(b, "ProjectileController");
        if (pc != null) {
            pc.activate(muzzleVec, this.targetId);
        } else {
            // No controller resolved (shouldn't happen): position it and park so it
            // doesn't sit visible at the origin.
            Entity::setPosition(b, muzzleVec);
            Entity::setActive(b, false);
        }
    }

    // Deal one shot's damage to the current target via the RTSGameplay plugin.
    // No-op when there is no valid target or the target has no Health component
    // (Combat::applyDamage returns NO_HEALTH). On a kill we drop the target so the
    // soldier returns to idle; a scene handler reacting to "rts.unit_killed" owns
    // the actual despawn/cleanup (the native never destroys the entity).
    private function applyShotDamage(): void {
        if (this.targetId < 0 || !Entity::isValid(this.targetId)) {
            return;
        }
        int result = Combat::applyDamage(this.targetId, this.damage);
        if (result == Combat::KILLED) {
            this.targetId = -1;
        }
    }

    public function onDestroy(): void {
        // Stop the agent if it was moving, so it doesn't keep pathing after death.
        if (this.hasMoveOrder) {
            Navmesh::stopAgent(this.selfId);
            this.hasMoveOrder = false;
        }

        // Tear down this soldier's tracer pool so its bullets don't linger after
        // death. Pooled bullets are root-level entities (not children of the
        // soldier), so they aren't reaped automatically with the unit.
        for (int i = 0; i < this.bulletPoolSize; i = i + 1) {
            int b = this.bulletPool[i];
            if (b >= 0 && Entity::isValid(b)) {
                Entity::destroy(b);
            }
            this.bulletPool[i] = -1;
        }
    }
}
