// RTSFog - fog-of-war state queries answered by the RTSGameplay plugin.
//
// The plugin registers the _rts_fog_state native via
// PluginContext::registerScriptFunction and answers from its own visibility
// grid (the exact data behind the on-screen fog mask). Inert fog (disabled via
// F10, no vision sources yet, or off-map points) reports VISIBLE, so gameplay
// rules built on this vanish exactly when the on-screen fog does.
//
// Usage:
//   if (RTSFog::isVisible(x, z)) { /* currently in player vision */ }
//   int s = RTSFog::state(x, z);  // UNEXPLORED / EXPLORED / VISIBLE

public class RTSFog {
    public static final int UNEXPLORED = 0;
    public static final int EXPLORED = 1;
    public static final int VISIBLE = 2;

    public constructor() {
    }

    // Fog state at world (x, z): UNEXPLORED, EXPLORED (seen before, not now),
    // or VISIBLE (currently inside a player vision circle).
    public static function state(float worldX, float worldZ): int {
        return _rts_fog_state(worldX, worldZ);
    }

    // True when (x, z) is currently visible (or fog is inert/disabled).
    public static function isVisible(float worldX, float worldZ): bool {
        return _rts_fog_state(worldX, worldZ) == RTSFog::VISIBLE;
    }
}
