// PatrolDemo - VK-1446 showcase. Builds a waypoint route in the scene and sends two
// patrollers around it on the Patrol behavior tree, plus keys to exercise the
// pause/resume/stop/reset control surface at runtime. Bootstrapped from
// BuildingCommandController.onStart so it needs no extra scene wiring -- delete the
// two BuildingCommandController calls (setup/update) to drop the demo.
//
// A "route" is a container entity at an identity transform whose ordered child
// markers are the waypoints; FollowRoute snaps each onto the baked navmesh. Two
// patrollers share the one route and follow it independently.
//
// Runtime keys (top number row; benign if they clash -- they only nudge the patrol):
//   7 = pause   8 = resume   9 = stop   0 = reset
//
// NOTE: the waypoint / spawn coordinates below are placed near the origin. If your
// playable navmesh sits elsewhere, adjust them so the markers land on baked navmesh
// (off-mesh markers are snapped, or dropped if too far).

import * from "../../lib/engine/oop/PrefabRef.mt";
import * from "../../lib/engine/oop/GameObject.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/Blackboard.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Key.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/RouteMode.mt";
import * from "../util/RouteCommand.mt";
import * from "../util/InputEdge.mt";

class PatrolDemo {
    private int[] patrollers;
    private int patrolCount;
    private string routeName;
    private string patrolTree;
    private PrefabRef soldierPrefab;
    private InputEdge pauseKey;
    private InputEdge resumeKey;
    private InputEdge stopKey;
    private InputEdge resetKey;

    public constructor() {
        this.patrollers = new int[0];
        this.patrolCount = 0;
        this.routeName = "PatrolRoute_01";
        this.patrolTree = "assets/ai/Patrol.vfBehaviorTree";
        this.soldierPrefab = new PrefabRef("assets/units/soldier_prefab.vfPrefab");
        this.pauseKey = new InputEdge();
        this.resumeKey = new InputEdge();
        this.stopKey = new InputEdge();
        this.resetKey = new InputEdge();
    }

    public function setup(): void {
        GameObject route = GameObject::create(this.routeName);
        route.transform().setLocalPosition(new Vec3f(0.0, 0.0, 0.0));
        this.addMarker(route, "WP00", -18.0, 18.0);
        this.addMarker(route, "WP01", 18.0, 18.0);
        this.addMarker(route, "WP02", 18.0, -18.0);
        this.addMarker(route, "WP03", -18.0, -18.0);

        this.patrollers = new int[2];
        this.patrolCount = 0;
        this.spawnPatroller(new Vec3f(-18.0, 0.0, 18.0), RouteMode::LOOP);
        this.spawnPatroller(new Vec3f(18.0, 0.0, -18.0), RouteMode::LOOP);
        Log::info("[PatrolDemo] ready (keys 7=pause 8=resume 9=stop 0=reset).");
    }

    public function update(float deltaTime): void {
        this.pauseKey.step(Input::isKeyDown(Key::NUM_7));
        this.resumeKey.step(Input::isKeyDown(Key::NUM_8));
        this.stopKey.step(Input::isKeyDown(Key::NUM_9));
        this.resetKey.step(Input::isKeyDown(Key::NUM_0));
        if (this.pauseKey.wasReleased) {
            this.command(RouteCommand::PAUSE);
        }
        if (this.resumeKey.wasReleased) {
            this.command(RouteCommand::RESUME);
        }
        if (this.stopKey.wasReleased) {
            this.command(RouteCommand::STOP);
        }
        if (this.resetKey.wasReleased) {
            this.command(RouteCommand::RESET);
        }
    }

    private function command(int cmd): void {
        for (int i = 0; i < this.patrolCount; i = i + 1) {
            int id = this.patrollers[i];
            if (Entity::isValid(id)) {
                Blackboard::setInt(id, "routeCommand", cmd);
            }
        }
    }

    private function addMarker(GameObject route, string name, float x, float z): void {
        GameObject marker = GameObject::create(name);
        marker.setParent(route);
        marker.transform().setLocalPosition(new Vec3f(x, 0.0, z));
    }

    private function spawnPatroller(Vec3f pos, int mode): void {
        GameObject? patroller = this.soldierPrefab.instantiateAt(pos);
        if (patroller == null) {
            return;
        }
        int id = patroller.id;
        patroller.setName("Patroller");
        patroller.setActive(true);
        Navmesh::setSpeed(id, 5.0);

        bool ok = Blackboard::attachTree(id, this.patrolTree);
        if (ok) {
            Blackboard::setString(id, "routeName", this.routeName);
            Blackboard::setInt(id, "routeMode", mode);
            Blackboard::setEnabled(id, true);
        }
        this.patrollers[this.patrolCount] = id;
        this.patrolCount = this.patrolCount + 1;
    }
}
