// FollowRoute - BT ScriptTask: walk a NavmeshAgent along an ordered set of
// authored waypoints, one waypoint at a time, using the existing navmesh
// pathfinding + crowd avoidance between checkpoints (VK-1446).
//
// The route is authored in the scene as a CONTAINER entity (placed at an identity
// transform so child local XZ == world XZ) whose ordered CHILD entities are the
// waypoint markers. This task reads that container's children ONCE in onStart,
// snaps/validates each against the baked navmesh, and then advances through them
// per the route mode. Many agents can reference the SAME container and follow it
// independently: each carries its own index/state, the marker list is read once,
// and a destination is issued ONLY when a waypoint is reached -- never per frame.
//
// Blackboard in:  routeName (string)   - name of the route container entity
//                 routeMode (int)      - RouteMode::ONCE / LOOP / PINGPONG
//                 arrivalDist (float)  - reach radius (default 1.5)
//                 dwell (float)        - seconds paused at each waypoint (0 = none)
//                 routeCommand (int)   - RouteCommand::PAUSE/RESUME/STOP/RESET (consumed)
// Blackboard out: blocked (bool)       - set true when a waypoint can't be reached
// Returns: "running" while travelling, "success" when a ONCE route finishes,
//          "failure" when blocked (so a parent Selector/decorator can react).
// onAbort: stops the nav agent (a higher-priority branch -- e.g. combat -- preempts).

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/RouteMode.mt";
import * from "../util/RouteCommand.mt";
import * from "../util/RouteState.mt";

@Script
public class FollowRoute {
    private int selfId;

    // Snapped, on-navmesh waypoints in authored order (read once in onStart).
    private Vec3f[] points;
    private int count;

    private int idx;          // current target waypoint
    private int dir;          // +1 / -1 traversal direction (PINGPONG); +1 otherwise
    private int state;        // RouteState::*
    private int pausedState;  // state to restore on RESUME (IDLE = nothing paused)
    private bool needIssue;   // a setDestination is owed for the current leg

    private float dwellTimer;
    private float stuckTimer;
    private float legClock;

    // ---- tuning ----
    private float arriveEps2;     // squared reach radius (from arrivalDist)
    private float maxSnapDist;    // drop a marker if it can't snap within this
    private float stuckSpeedEps;  // planar speed under which the agent is "stalled"
    private float stuckTimeout;   // seconds stalled-and-not-arrived -> BLOCKED
    private float maxTravelTime;  // hard per-leg cap -> BLOCKED (catches partial paths)

    public constructor() {
        this.selfId = -1;
        this.points = new Vec3f[0];
        this.count = 0;
        this.idx = 0;
        this.dir = 1;
        this.state = RouteState::IDLE;
        this.pausedState = RouteState::IDLE;
        this.needIssue = false;
        this.dwellTimer = 0.0;
        this.stuckTimer = 0.0;
        this.legClock = 0.0;
        this.arriveEps2 = 2.25;     // (1.5)^2 default
        this.maxSnapDist = 4.0;
        this.stuckSpeedEps = 0.15;
        this.stuckTimeout = 1.5;
        this.maxTravelTime = 30.0;
    }

    public function onStart(): void {
        this.selfId = Entity::self();
        this.loadRoute();

        float ad = Blackboard::getFloat(this.selfId, "arrivalDist");
        if (ad <= 0.0) {
            ad = 1.5;
        }
        this.arriveEps2 = ad * ad;

        if (this.count > 0) {
            this.state = RouteState::MOVING;
            this.needIssue = true;
        } else {
            this.state = RouteState::IDLE;
        }
    }

    public function tick(float deltaTime): string {
        if (this.selfId < 0) {
            return "failure";
        }

        // Consume a pending control command (pause/resume/stop/reset).
        int cmd = Blackboard::getInt(this.selfId, "routeCommand");
        if (cmd != RouteCommand::NONE) {
            this.applyCommand(cmd);
            Blackboard::setInt(this.selfId, "routeCommand", RouteCommand::NONE);
        }

        if (this.count == 0) {
            return "running";   // no valid waypoints: idle, never issue a destination
        }
        if (this.state == RouteState::IDLE) {
            return "running";   // paused or stopped
        }
        if (this.state == RouteState::BLOCKED) {
            return "failure";
        }
        if (this.state == RouteState::COMPLETE) {
            return "success";
        }

        if (this.state == RouteState::DWELL) {
            this.dwellTimer = this.dwellTimer - deltaTime;
            if (this.dwellTimer <= 0.0) {
                this.advance();
            }
            return this.statusForCurrent();
        }

        // MOVING: issue the destination once per leg, then poll arrival + watchdog.
        if (this.needIssue) {
            Navmesh::setDestination(this.selfId, this.points[this.idx]);
            this.needIssue = false;
            this.legClock = 0.0;
            this.stuckTimer = 0.0;
        }

        if (this.arrivedAt(this.idx)) {
            float dw = Blackboard::getFloat(this.selfId, "dwell");
            if (dw > 0.0) {
                this.dwellTimer = dw;
                this.state = RouteState::DWELL;
                Navmesh::stopAgent(this.selfId);
            } else {
                this.advance();
            }
            return this.statusForCurrent();
        }

        // Watchdog: a stalled agent or an over-long leg means the waypoint is
        // unreachable (e.g. a partial path) -- halt and surface it, so the agent
        // never circles indefinitely.
        this.legClock = this.legClock + deltaTime;
        Vec3f v = Navmesh::getVelocity(this.selfId);
        float sp = sqrt(v.x * v.x + v.z * v.z);
        if (sp < this.stuckSpeedEps) {
            this.stuckTimer = this.stuckTimer + deltaTime;
        } else {
            this.stuckTimer = 0.0;
        }
        if (this.stuckTimer >= this.stuckTimeout || this.legClock >= this.maxTravelTime) {
            Navmesh::stopAgent(this.selfId);
            Blackboard::setBool(this.selfId, "blocked", true);
            Log::info("[FollowRoute] blocked at waypoint " + parsePrimitive(this.idx));
            this.state = RouteState::BLOCKED;
            return "failure";
        }

        return "running";
    }

    public function onAbort(): void {
        Navmesh::stopAgent(this.selfId);
        this.needIssue = true;   // re-issue the current leg if this branch resumes
    }

    // Required by the @Script validator; the behavior tree drives this task via
    // tick(), so onUpdate is an intentional no-op.
    public function onUpdate(float deltaTime): void {
    }

    public function onDestroy(): void {
    }

    // ---- internals ----

    // Read the route container's children once, snapping/validating each marker to
    // the navmesh. Markers that can't snap within maxSnapDist are dropped (logged)
    // so the agent is never sent toward an off-mesh point.
    private function loadRoute(): void {
        string rn = Blackboard::getString(this.selfId, "routeName");
        int container = -1;
        if (rn != "") {
            container = Entity::findByName(rn);
        }
        if (container < 0) {
            this.count = 0;
            this.points = new Vec3f[0];
            Log::info("[FollowRoute] route container not found for '" + rn + "'");
            return;
        }

        int[] kids = Entity::getChildren(container);
        Vec3f[] tmp = new Vec3f[kids.length];
        int n = 0;
        for (int i = 0; i < kids.length; i = i + 1) {
            Vec3f p = Entity::getPosition(kids[i]);
            Vec3f snapped = p;
            if (!Navmesh::isPointOnNavmesh(p)) {
                Vec3f c = Navmesh::getClosestPoint(p);
                float ddx = c.x - p.x;
                float ddz = c.z - p.z;
                if ((ddx * ddx + ddz * ddz) > (this.maxSnapDist * this.maxSnapDist)) {
                    Log::info("[FollowRoute] dropping off-navmesh waypoint " + parsePrimitive(i));
                    continue;
                }
                snapped = c;
            }
            tmp[n] = snapped;
            n = n + 1;
        }
        this.points = tmp;
        this.count = n;
        this.idx = 0;
        this.dir = 1;
    }

    // Advance idx to the next waypoint per the route mode, or terminate a ONCE route.
    private function advance(): void {
        int mode = Blackboard::getInt(this.selfId, "routeMode");
        if (mode == RouteMode::ONCE) {
            if (this.idx >= this.count - 1) {
                this.state = RouteState::COMPLETE;
                Navmesh::stopAgent(this.selfId);
                return;
            }
            this.idx = this.idx + 1;
        } else if (mode == RouteMode::PINGPONG) {
            if (this.count == 1) {
                this.state = RouteState::COMPLETE;
                Navmesh::stopAgent(this.selfId);
                return;
            }
            int next = this.idx + this.dir;
            if (next > this.count - 1 || next < 0) {
                this.dir = -this.dir;          // bounce off the endpoint
                next = this.idx + this.dir;
            }
            this.idx = next;
        } else {
            // LOOP (default): wrap last -> first
            this.idx = (this.idx + 1) % this.count;
        }
        this.state = RouteState::MOVING;
        this.needIssue = true;
    }

    private function arrivedAt(int i): bool {
        Vec3f p = Entity::getPosition(this.selfId);
        Vec3f t = this.points[i];
        float dx = t.x - p.x;
        float dz = t.z - p.z;
        return (dx * dx + dz * dz) <= this.arriveEps2;
    }

    private function applyCommand(int cmd): void {
        if (cmd == RouteCommand::PAUSE) {
            if (this.state == RouteState::MOVING || this.state == RouteState::DWELL) {
                this.pausedState = this.state;
                this.state = RouteState::IDLE;
                Navmesh::stopAgent(this.selfId);
            }
        } else if (cmd == RouteCommand::RESUME) {
            if (this.state == RouteState::IDLE && this.pausedState != RouteState::IDLE) {
                this.state = this.pausedState;
                this.pausedState = RouteState::IDLE;
                if (this.state == RouteState::MOVING) {
                    this.needIssue = true;   // re-path to the same waypoint
                }
            }
        } else if (cmd == RouteCommand::STOP) {
            // Full stop: halt where it is, KEEP the current index (a later RESET or
            // RESUME-from-a-fresh-pause continues from here).
            this.state = RouteState::IDLE;
            this.pausedState = RouteState::IDLE;
            Navmesh::stopAgent(this.selfId);
        } else if (cmd == RouteCommand::RESET) {
            if (this.count > 0) {
                this.idx = 0;
                this.dir = 1;
                this.pausedState = RouteState::IDLE;
                this.state = RouteState::MOVING;
                this.needIssue = true;
                Blackboard::setBool(this.selfId, "blocked", false);
            }
        }
    }

    private function statusForCurrent(): string {
        if (this.state == RouteState::COMPLETE) {
            return "success";
        }
        if (this.state == RouteState::BLOCKED) {
            return "failure";
        }
        return "running";
    }
}
