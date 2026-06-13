// Util - small math helpers shared across the RTS demo controllers.
//
// clampF and the grid snap were open-coded in several controllers (focal-point
// clamping in RTSCameraController / MinimapController, the sign-aware floor in
// BuildingPlacementController). Vector math is intentionally NOT here: Vec3f
// already provides length() / normalize().

public class Util {
    public constructor() {
    }

    // Clamp v to [lo, hi].
    public static function clampF(float v, float lo, float hi): float {
        if (v < lo) { return lo; }
        if (v > hi) { return hi; }
        return v;
    }

    public static function minF(float a, float b): float {
        if (a < b) { return a; }
        return b;
    }

    public static function maxF(float a, float b): float {
        if (a > b) { return a; }
        return b;
    }

    // Round v to the nearest multiple of grid. mType has no floor(), so use the
    // sign-aware add-half-then-truncate idiom ((int) truncates toward zero).
    public static function snapToGrid1D(float v, float grid): float {
        float k = v / grid;
        int n = (int)(k + 0.5);
        if (k < 0.0) {
            n = (int)(k - 0.5);
        }
        return (float)n * grid;
    }
}
