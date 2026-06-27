// RouteMode - waypoint-route traversal modes (VK-1446).
//
// mType has no enum keyword, so this is a static-final int group (the same idiom
// as HState / RTSFog). Consumed by the FollowRoute BT ScriptTask and seeded onto
// an agent's behavior-tree blackboard under the "routeMode" key.

public class RouteMode {
    public static final int ONCE = 0;     // stop at the last waypoint (route COMPLETE)
    public static final int LOOP = 1;     // wrap last -> first forever
    public static final int PINGPONG = 2; // reverse direction at each endpoint

    public constructor() {
    }
}
