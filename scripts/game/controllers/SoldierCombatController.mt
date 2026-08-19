// SoldierCombatController - per-unit animation + combat state machine for the
// soldier (VK-1402/1403/1404 demo wiring).
//
// One instance of this @Script lives on each soldier prefab root. It drives the
// soldier.vfAnimator parameters (Speed / IsFiring) and spawns a muzzle-flash
// VFX at the rifle barrel on every "Shoot" animation event, based on the order
// it is given:
//
//   idle   - no order, agent at rest        -> Speed=0,     IsFiring=false
//   move   - moving under a move order       -> Speed=|vel|, IsFiring=false
//   chase  - has an attack target out of range-> Speed=|vel|, IsFiring=false
//   fire   - has an attack target in range    -> Speed=0,     IsFiring=true
//            (stop-and-shoot, auto-repeats while the target stays in range)
//
// The order is set externally by BuildingCommandController.handleMoveCommand on
// a right-click: an enemy hit calls setTarget(enemyId); a ground click calls
// setTarget(-1). The right-click router reaches this script via
// Entity::getScript<SoldierCombatController>(unitId, "SoldierCombatController").
//
// STANCE (VK-1298 slice 1). Two flags turn the same state machine into the three
// stances an RTS player expects, and both are set from the unit command card:
//
//   autoAcquire  - scan for a hostile every scanInterval while idle and engage it
//                  unprompted. ON by default (attack-move, and standing units that
//                  defend themselves); a plain Move order clears it so the squad
//                  actually walks to the destination instead of stopping to fight,
//                  and BuildingCommandController restores it on arrival.
//   holdPosition - never leave this spot. The soldier keeps its target and keeps
//                  firing whenever that target is in range, but never chases. This
//                  is what makes a defensive line hold instead of dissolving into
//                  a pursuit.
//
// Locomotion is nav-paced: the NavmeshAgent (not root motion) moves the unit at its
// configured maxSpeed, and the animator's "Speed" float drives a 1D Idle<->Run blend
// tree from the agent's velocity (set fresh each frame in onLateUpdate). Plain move
// orders (issued by the router via Navmesh::moveTo) animate as Run with no extra
// bookkeeping. Attach this @Script to the soldier prefab root alongside
// MeshComponent(animatorRef=soldier.vfAnimator) + NavmeshAgent.
//
// RATE SPLIT (VK-1536). The work is deliberately divided by the rate it NEEDS, because the
// engine's script tick governor throttles onUpdate and never touches onLateUpdate:
//
//   onUpdate      - decisions: target validity, chase/fire state, nav orders. Reads no
//                   deltaTime and no input, so it is safe at a reduced rate. This is the
//                   half that scales: set Tick Governor -> Update Interval (e.g. 0.1 for
//                   10Hz) on this script's row in soldier_prefab to cut the per-unit
//                   main-thread cost of a large army.
//   onLateUpdate  - cosmetics that must run every frame: the Speed blend, the animation
//                   event drain (muzzle flash + hit-scan), and the support-hand IK.
//
// Put new per-frame work in onLateUpdate. Anything added to onUpdate must tolerate being
// called at the authored interval with an ACCUMULATED deltaTime.

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Animator.mt";
import * from "../../lib/engine/Socket.mt";
import * from "../../lib/engine/IK.mt";
import * from "../../lib/engine/VFX.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/Config.mt";
import * from "../util/Combat.mt";
import * from "./ProjectilePool.mt";
import * from "./DeathController.mt";

@Script
class SoldierCombatController extends Behaviour {
    private int selfId;

    // Current attack target entity id (-1 = none). Set by the right-click router.
    private int targetId;

    // Cached capability flags (resolved once in onStart).
    private bool hasAnim;

    // Last-pushed animator parameter values, so we only call the native on change.
    private float curSpeed;   // smoothed locomotion speed pushed to the "Speed" blend param
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
    // Per-frame damping for the locomotion "Speed" blend param (0..1); lower = smoother
    // ease into/out of the Idle<->Run blend. Fed a FRESH same-frame navmesh velocity in
    // onLateUpdate (updateLocomotionSpeed), so the blend tracks the body's real speed.
    private float speedDamp;
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

    // ---- support-hand IK (keep the left hand on the rifle in every state) ----
    // The rifle is rigidly parented to the right hand ("Weapon_R"), so the LEFT
    // (support) hand drifts off the foregrip whenever a locomotion clip swings the
    // arms. The fix (the same one UE5/Unity use): each frame, pull the left hand to
    // a grip point authored ON the rifle via the FABRIK IK solver. Because the grip
    // socket's world transform already follows the right hand, the support hand
    // tracks the gun in idle / run / fire with no per-state data.
    //
    // Requires (authored in the editor, graceful no-op until then):
    //   - a "LeftHandGrip" socket on the AK-47 mesh, at the handguard, and
    //   - an IKTargetComponent on the soldier with a "LeftArm" chain (left
    //     upper-arm -> lower-arm, tip = left hand; Hinge elbow constraint).
    private bool enableHandIK;     // master toggle
    private string ikChain;        // IK chain name authored on the soldier
    private string gripSocket;     // socket name authored on the rifle
    private float handIkWeight;    // blend (1.0 = full IK; drop to A/B vs drift)
    private bool hasLeftHandIK;    // cached IK::hasComponent(self), resolved in onStart

    // ---- stance (VK-1298 slice 1) ----
    // See the header. autoAcquire drives the idle scan; holdPosition suppresses the
    // chase leg of tickCombat.
    private bool autoAcquire;
    private bool holdPosition;
    // Radius of the idle hostile scan. Wider than fireRange so a soldier starts
    // closing on a target it can see before that target is already shooting back.
    private float acquireRange;
    // The scan walks every entity carrying a Team component, so it is rate-limited
    // rather than run on every decision tick. It accumulates the SAME deltaTime
    // onUpdate is handed, so the cadence stays correct when the tick governor
    // throttles this script (VK-1536).
    private float scanInterval;
    private float scanAccum;

    // ---- death reporting ----
    // Resolved once from GameSystems, exactly like projectilePool below. The plugin
    // damage native never destroys anything, so this hand-off is what turns a 0-HP
    // entity into an actual despawn (see controllers/DeathController.mt).
    private DeathController? deaths;

    // ---- cosmetic tracer (VK-1427 Phase 6) ----
    // Tracers are drawn from ONE shared ProjectilePool on the GameSystems entity, not
    // a per-soldier pool, so the scene holds at most `cap` bullets total regardless of
    // army size. Resolved once in onStart. Cosmetic only -- damage stays instant
    // hit-scan in applyShotDamage.
    private ProjectilePool? projectilePool;

    public constructor() : super() {
        this.selfId = -1;
        this.targetId = -1;
        this.hasAnim = false;
        this.curSpeed = 0.0;
        this.curFiring = false;
        this.lastCmd = new Vec3f(0.0, 0.0, 0.0);
        this.hasMoveOrder = false;

        this.fireRange = 14.0;
        this.fireRangeSq = 14.0 * 14.0;
        this.fireExitRangeSq = 16.0 * 16.0;
        this.giveUpRange = 80.0;
        this.giveUpRangeSq = 80.0 * 80.0;
        this.speedDamp = 0.25;           // ease the Idle<->Run blend (0..1)
        this.reissueDistSq = 4.0;        // re-path if target moved > 2 units
        this.damage = 10.0;              // HP per Shoot event
        this.faceTarget = true;
        this.faceYawOffsetDeg = 0.0;
        this.muzzleVfx = "assets/units/soldier/fire.vfVFX";

        this.autoAcquire = true;
        this.holdPosition = false;
        this.acquireRange = 22.0;
        this.scanInterval = 0.3;
        this.scanAccum = 0.0;

        this.ak47Id = -1;
        this.projectilePool = null;
        this.deaths = null;

        this.enableHandIK = true;
        this.ikChain = "LeftHandGrip";
        this.gripSocket = "LeftHandGrip";
        this.handIkWeight = 1.0;
        this.hasLeftHandIK = false;
    }

    public function onStart(): void {
        this.selfId = this.entityId();
        this.hasAnim = Animator::hasAnimator(this.selfId);
        this.hasLeftHandIK = IK::hasComponent(this.selfId);

        // Drive per-shot damage from the unit's runtime Attack component when it
        // has one (added at spawn by BuildingCommandController from the UnitDef),
        // so combat tuning lives with the unit data. Falls back to the authored
        // default above when no Attack component is present.
        if (PluginComponent::has(this.selfId, "Attack")) {
            this.damage = PluginComponent::getFloat(this.selfId, "Attack", "damage");
        }

        // Force the initial animator parameters to a known idle state.
        this.curSpeed = 0.0;
        this.curFiring = false;
        if (this.hasAnim) {
            Animator::setFloat(this.selfId, "Speed", 0.0);
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

        // Resolve the shared tracer pool (one for the whole match) off GameSystems.
        // No bullets are owned per-soldier; spawnProjectile just calls pool.fire().
        int gsId = Entity::findByName("GameSystems");
        if (gsId >= 0) {
            this.projectilePool = Entity::getScript<ProjectilePool>(gsId, "ProjectilePool");
            this.deaths = Entity::getScript<DeathController>(gsId, "DeathController");
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

    // Hold Position: keep firing at whatever comes into range, never chase. An
    // out-of-range target is deliberately KEPT rather than dropped, so toggling
    // hold back off resumes the pursuit without a fresh order.
    public function setHold(bool hold): void {
        this.holdPosition = hold;
        if (hold && this.hasMoveOrder) {
            Navmesh::stopAgent(this.selfId);
            this.hasMoveOrder = false;
        }
    }

    public function isHolding(): bool {
        return this.holdPosition;
    }

    // Turn the idle hostile scan on/off. A plain Move order clears it so the squad
    // walks past enemies instead of peeling off to fight; attack-move leaves it on.
    public function setAutoAcquire(bool on): void {
        this.autoAcquire = on;
    }

    public function isAutoAcquire(): bool {
        return this.autoAcquire;
    }

    // Stop command: drop the attack order, halt the agent, lower the rifle. Stance
    // is deliberately unchanged -- a stopped soldier with autoAcquire on will
    // re-engage anything that walks up to it, which is the standard RTS behaviour.
    public function stop(): void {
        this.targetId = -1;
        this.hasMoveOrder = false;
        Navmesh::stopAgent(this.selfId);
        this.setFiring(false);
    }

    // DECISION work only -- this is the throttleable half (VK-1536). Nothing here reads
    // deltaTime or per-frame input: it is a state machine over positions that issues nav
    // orders, so running it at a reduced rate (Tick Governor -> Update Interval on the
    // prefab's script row) costs latency and nothing else. The per-frame cosmetic work
    // deliberately lives in onLateUpdate below, which the governor never throttles.
    public function onUpdate(float deltaTime): void {
        if (this.selfId < 0) {
            return;
        }

        // Accumulate here rather than inside the idle branch so the scan cadence is
        // wall-clock: a soldier that flickers between chase and idle would otherwise
        // never build up enough idle ticks to ever scan.
        this.scanAccum = this.scanAccum + deltaTime;

        // Drop a dead/despawned target.
        if (this.targetId >= 0 && !Entity::isValid(this.targetId)) {
            this.targetId = -1;
        }

        if (this.targetId >= 0) {
            this.tickCombat();
        } else {
            this.tickIdleOrMove();
        }
    }

    // Per-FRAME work. Two reasons it all belongs here rather than in onUpdate:
    //
    //  1. Freshness: onLateUpdate runs AFTER the engine's Navmesh and Transforms tasks
    //     (Scripts -> Navmesh -> Transforms -> LateScripts), so Navmesh::getVelocity and the
    //     rifle's socket world transform are both current for THIS frame. Animation/IK still
    //     evaluate later (inside Render), so an IK target set here is applied the same frame.
    //  2. VK-1536: the tick governor throttles onUpdate ONLY. Anything that must run every
    //     frame has to live here, or it degrades the moment a unit opts into an interval --
    //     the support hand would snap at the throttled rate and muzzle flashes would batch.
    //
    // Speed blend: driven from the planar nav speed as a CONTINUOUS 1D Idle<->Run blend, so
    // the legs wind down with the body -- no extra Run step on stop, no idle-slide. The
    // navmesh (not root motion) owns movement, so this is purely cosmetic -- no feedback
    // loop with the agent's pacing.
    public function onLateUpdate(float deltaTime): void {
        if (this.selfId < 0) {
            return;
        }

        if (this.hasAnim) {
            this.updateLocomotionSpeed();

            // Muzzle flash: always drain the event FIFO when we have an animator (so it
            // never backs up to its cap), but only spawn when the Muzzle socket exists.
            // Animation events only fire during the Fire state.
            this.drainShootEvents();
        }

        // Keep the support hand glued to the rifle's grip across every anim state.
        // Guarded internally; needs no animator, only the IK chain + grip socket.
        this.updateHandIK();
    }

    private function updateLocomotionSpeed(): void {
        Vec3f v = Navmesh::getVelocity(this.selfId);
        float speed = sqrt(v.x * v.x + v.z * v.z);
        // Light damping so per-frame velocity noise doesn't jitter the blend weight.
        this.curSpeed = this.curSpeed + (speed - this.curSpeed) * this.speedDamp;
        Animator::setFloat(this.selfId, "Speed", this.curSpeed);
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
            // Chase: move toward the target. Locomotion (Run) is driven by the resulting
            // nav velocity via the Speed blend param in onLateUpdate.
            this.setFiring(false);
            if (this.holdPosition) {
                // Holding: out of range simply means "not shooting yet". The target
                // is kept, so fire resumes the instant it walks back into range.
                if (this.hasMoveOrder) {
                    Navmesh::stopAgent(this.selfId);
                    this.hasMoveOrder = false;
                }
                return;
            }
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
            this.setFiring(true);
            if (this.faceTarget) {
                this.faceToward(dx, dz);
            }
        }
    }

    private function tickIdleOrMove(): void {
        // Locomotion (Idle<->Run) is driven by the navmesh speed via the Speed blend
        // param in onLateUpdate; nothing to set here beyond clearing combat state.
        this.setFiring(false);
        this.hasMoveOrder = false;
        this.tryAutoAcquire();
    }

    // Look for something to shoot when there is no order. The scan is team-relative
    // (see util/Combat.mt), so this one method serves player soldiers and enemy wave
    // soldiers alike. Rate-limited because it is a full pass over every
    // Team-carrying entity.
    private function tryAutoAcquire(): void {
        if (!this.autoAcquire) {
            return;
        }
        if (this.scanAccum < this.scanInterval) {
            return;
        }
        this.scanAccum = 0.0;

        Vec3f sp = Entity::getPosition(this.selfId);
        int foe = Combat::findNearestHostile(this.selfId, sp.x, sp.z, this.acquireRange);
        if (foe >= 0) {
            this.setTarget(foe);
        }
    }

    // ---- helpers ----

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

    // Pull the soldier's left (support) hand onto the rifle's grip socket via the
    // FABRIK IK solver, every frame, on top of whatever locomotion pose is playing.
    // The grip socket lives on the AK-47 mesh and its world transform already tracks
    // the right hand (rifle is parented to "Weapon_R"), so feeding that world point
    // to the "LeftArm" chain keeps the hand planted in idle / run / fire alike.
    //
    // Position-only by default: pinning the tip rotation too can over-twist the
    // wrist. If the hand sits on the grip but rolls oddly, switch to
    // IK::setTargetWithRotation(self, chain, grip, Socket::getRotation(ak, grip)).
    //
    // Fully guarded so it is a no-op until both the IK chain (on the soldier) and
    // the grip socket (on the rifle) are authored in the editor.
    private function updateHandIK(): void {
        if (!this.enableHandIK || !this.hasLeftHandIK) {
            return;
        }
        if (this.ak47Id < 0 || !Entity::isValid(this.ak47Id)) {
            return;
        }
        if (!Socket::hasSocket(this.ak47Id, this.gripSocket)) {
            return;
        }
        Vec3f grip = Socket::getPosition(this.ak47Id, this.gripSocket);
        IK::setTarget(this.selfId, this.ikChain, grip);
        IK::setChainWeight(this.selfId, this.ikChain, this.handIkWeight);
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

        // Hand off to the shared pool: it lazily allocates and reuses bullets across
        // all soldiers, so firing never creates/destroys in the hot path. Narrow a
        // local (mType field-narrowing across a call is unreliable).
        ProjectilePool? pool = this.projectilePool;
        if (pool != null) {
            Vec3f muzzleVec = Socket::getPosition(this.ak47Id, "Muzzle");
            pool.fire(muzzleVec, this.targetId);
        }
    }

    // Deal one shot's damage to the current target via the RTSGameplay plugin.
    // No-op when there is no valid target or the target has no Health component
    // (Combat::applyDamage returns NO_HEALTH).
    //
    // On a kill the victim is handed to DeathController and the target dropped so
    // the soldier returns to idle. That hand-off is what makes anything ever die:
    // the plugin native only clamps HP to 0 and publishes "rts.unit_killed" on the
    // PLUGIN event bus, which mType cannot subscribe to -- so without this call the
    // corpse would stand there forever. Null-safe: a scene with no DeathController
    // behaves exactly as it did before.
    private function applyShotDamage(): void {
        if (this.targetId < 0 || !Entity::isValid(this.targetId)) {
            return;
        }
        int result = Combat::applyDamage(this.targetId, this.damage);
        if (result == Combat::KILLED) {
            // Capture the victim BEFORE clearing, and clear BEFORE reporting: the
            // despawn is synchronous, so this soldier must already be target-free
            // by the time the entity goes away.
            int victim = this.targetId;
            this.targetId = -1;
            DeathController? d = this.deaths;
            if (d != null) {
                d.reportKill(victim, this.selfId);
            }
        }
    }

    public function onDestroy(): void {
        // Stop the agent if it was moving, so it doesn't keep pathing after death.
        if (this.hasMoveOrder) {
            Navmesh::stopAgent(this.selfId);
            this.hasMoveOrder = false;
        }

        // Tracers belong to the shared ProjectilePool (on GameSystems), not to this
        // soldier, so there is nothing to tear down here — the pool reuses them for
        // other soldiers and frees them on match end.
    }
}
