// RouteState - FollowRoute internal state-machine constants (VK-1446).
//
// Static-final int group (mType has no enum). The route follower is IDLE before
// it starts / while paused or stopped, MOVING toward the current waypoint, DWELL
// while pausing at a reached waypoint, BLOCKED when a waypoint cannot be reached
// (surfaced via the "blocked" blackboard bool), and COMPLETE when a ONCE route
// finishes its last waypoint.

public class RouteState {
    public static final int IDLE = 0;
    public static final int MOVING = 1;
    public static final int DWELL = 2;
    public static final int BLOCKED = 3;
    public static final int COMPLETE = 4;

    public constructor() {
    }
}
