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

    // ============================================
    // Render layers / culling masks (VK-1415)
    // ============================================
    // Per-mesh render-layer index (0-31), set via Entity::setRenderLayer. A camera
    // renders a mesh only if its cullingMask (Camera::setCullingMask) has that bit.
    public static final int LAYER_DEFAULT = 0;     // units, buildings, terrain, normal meshes
    public static final int LAYER_NO_MINIMAP = 10; // decorative props you want hidden from the minimap

    // Culling mask for the top-down minimap camera ("camera minimap"): all layers
    // EXCEPT LAYER_NO_MINIMAP. Value is 0xFFFFFFFF with bit 10 cleared (0xFFFFFBFF).
    // Tag any mesh you want kept off the minimap with
    //   Entity::setRenderLayer(id, Config::LAYER_NO_MINIMAP);
    // (at spawn, or author renderLayer=10 on its prefab). Until something is tagged,
    // the minimap looks unchanged.
    public static final int MINIMAP_CULL_MASK = 4294966271;

    public constructor() {
    }
}
