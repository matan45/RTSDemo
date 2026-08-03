// Crater - terrain deformation for artillery / shell impacts (VK-1624).
//
// Pure terrain edits, no entity work. Deliberately does NOT batch or flush: a
// salvo lands several shells in the same frame and they must share ONE seam weld
// and ONE collider rebuild, so the caller owns the begin/flush pair:
//
//   Terrain::beginBatch();
//   Crater::impact(x1, z1, 6.0, 1.8);
//   Crater::impact(x2, z2, 6.0, 1.8);
//   Terrain::flush();
//
// Craters are transient - see the note in Terrain.mt. They survive for the
// session but are never written back to the .vfTerrain asset, and a tile that
// streams out and back in reloads the authored heights.

import * from "../../lib/engine/Terrain.mt";

public class Crater {
    // Palette layer index of the scorched-earth layer in the terrain material.
    // If the demo terrain has no such layer the paint is a documented no-op and
    // the crater geometry still works, which is the right failure mode here.
    public static final int SCORCH_LAYER = 3;

    // Ejecta lip is this fraction of the bowl depth, spread over this multiple
    // of the bowl radius. Scorch reaches a little past the lip.
    public static final float LIP_HEIGHT_RATIO   = 0.22;
    public static final float LIP_RADIUS_RATIO   = 1.6;
    public static final float SCORCH_RADIUS_RATIO = 1.25;

    public constructor() {
    }

    // Deform + scorch at a world XZ impact point. `depth` is POSITIVE - metres of
    // soil removed at the centre. Returns false when the impact was off the
    // loaded terrain, so the caller can skip its VFX and audio too.
    public static function impact(float worldX, float worldZ, float radius, float depth): bool {
        if (!Terrain::hasHeightAt(worldX, worldZ)) {
            return false;
        }

        // Lip FIRST, bowl SECOND. A wide gentle raise followed by a narrow deep
        // cut leaves a raised rim; the other order just fills the hole back in.
        Terrain::deform(worldX, worldZ, radius * Crater::LIP_RADIUS_RATIO,
                        depth * Crater::LIP_HEIGHT_RATIO,
                        Terrain::MODE_ADD, Terrain::FALLOFF_LINEAR, Terrain::SHAPE_CIRCLE);

        Terrain::deform(worldX, worldZ, radius, 0.0 - depth,
                        Terrain::MODE_ADD, Terrain::FALLOFF_SMOOTH, Terrain::SHAPE_CIRCLE);

        Terrain::paint(worldX, worldZ, radius * Crater::SCORCH_RADIUS_RATIO,
                       Crater::SCORCH_LAYER, 1.0);
        return true;
    }

    // Flatten a building pad to an absolute world Y - the MODE_SET counterpart.
    // Sharp square falloff so the pad has crisp edges and a flat interior.
    public static function levelPad(float worldX, float worldZ, float halfSize, float padY): bool {
        if (!Terrain::hasHeightAt(worldX, worldZ)) {
            return false;
        }
        Terrain::deform(worldX, worldZ, halfSize, padY,
                        Terrain::MODE_SET, Terrain::FALLOFF_SHARP, Terrain::SHAPE_SQUARE);
        return true;
    }
}
