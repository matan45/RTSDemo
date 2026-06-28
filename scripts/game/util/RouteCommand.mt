// RouteCommand - one-shot control commands for a waypoint route (VK-1446).
//
// The pause / resume / stop / reset surface required by the story is driven
// through a single blackboard int ("routeCommand") rather than a direct method
// call, so it works from anywhere (a controller, another BT task) while the route
// logic lives inside the FollowRoute ScriptTask. FollowRoute reads the key at the
// top of each tick and resets it to NONE once consumed.

public class RouteCommand {
    public static final int NONE = 0;   // no pending command
    public static final int PAUSE = 1;  // halt the agent, remember where it was
    public static final int RESUME = 2; // continue from the paused waypoint
    public static final int STOP = 3;   // halt the agent, keep the current index
    public static final int RESET = 4;  // rewind to the first waypoint and run

    public constructor() {
    }
}
