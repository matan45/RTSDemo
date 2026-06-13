// Config - cross-file tuning constants for the RTS demo scripts.
//
// Holds only values that were duplicated across controllers: the
// degrees->radians factor (was a private field in both RTSCameraController and
// MinimapController) and the playable map bounds (copy-pasted in
// RTSCameraController, MinimapController and BuildingPlacementController), plus
// the local-player team id. Single-file tuning knobs stay as named fields on
// their own controller -- this is for genuinely shared constants only.

public class Config {
    // Degrees -> radians (camera yaw, minimap frustum math).
    public static final float DEG_TO_RAD = 0.01745329252;

    // Playable map bounds (world XZ). Camera focal point, minimap view rect, and
    // building placement all clamp against these.
    public static final float MAP_MIN_X = -256.0;
    public static final float MAP_MAX_X = 256.0;
    public static final float MAP_MIN_Z = -256.0;
    public static final float MAP_MAX_Z = 256.0;

    // Team id treated as the local player (selection, vision, ownership).
    public static final int TEAM_PLAYER = 0;

    public constructor() {
    }
}
