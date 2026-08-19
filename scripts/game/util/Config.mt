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
    //
    // These MUST match the authored terrain or the clamps let the camera fly over void
    // and let buildings be placed off the heightfield. Skirmish_01's terrain is
    // worldTileSize 32 over the tile grid X/Z [-2..1] (see the terrain component in
    // scenes/Skirmish_01.vfScene), i.e. 4 tiles * 32 = 128 units spanning [-64, +64] on
    // both axes. They were +/-256, a leftover from a larger prototype terrain.
    public static final float MAP_MIN_X = -64.0;
    public static final float MAP_MAX_X = 64.0;
    public static final float MAP_MIN_Z = -64.0;
    public static final float MAP_MAX_Z = 64.0;

    // Team id treated as the local player (selection, vision, ownership).
    public static final int TEAM_PLAYER = 0;

    // ============================================
    // Render layers / culling masks (VK-1415)
    // ============================================
    // Per-mesh render-layer index (0-31), set via Entity::setRenderLayer. A camera
    // renders a mesh only if its cullingMask (Camera::setCullingMask) has that bit.
    public static final int LAYER_DEFAULT = 0;     // units, buildings, terrain, normal meshes
    public static final int LAYER_NO_MINIMAP = 10; // decorative props you want hidden from the minimap

    // Culling mask for the top-down minimap camera ("camera minimap"). A camera renders a
    // mesh only if (1<<mesh.renderLayer) & this mask != 0; terrain/water honor it via
    // renderSettings.terrain/water.renderLayer (VK-1415).
    //
    // LAYER_DEFAULT only: the terrain, buildings and units now DO render into the minimap
    // render texture, underneath the mType MinimapBlip dots, while decorative props tagged
    // LAYER_NO_MINIMAP stay out. Set this back to 0 to revert to blips-only (clearColor
    // background + dots) -- that is the fallback if the RTT cull pass misbehaves.
    public static final int MINIMAP_CULL_MASK = 1 << LAYER_DEFAULT;

    public constructor() {
    }
}
