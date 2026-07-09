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

    // Culling mask for the top-down minimap camera ("camera minimap"). 0 = render NOTHING
    // from the scene into the minimap RT (no units, buildings, terrain, or water) — the
    // minimap shows only the clearColor background plus the mType MinimapBlip dots.
    // A camera renders a mesh only if (1<<mesh.renderLayer) & this mask != 0; terrain/water
    // honor it via renderSettings.terrain/water.renderLayer (VK-1415, needs the engine build).
    // To SHOW some layers instead, OR in their bits, e.g. (1<<0) to draw default-layer meshes.
    public static final int MINIMAP_CULL_MASK = 0;

    public constructor() {
    }
}
