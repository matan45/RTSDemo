// ArtilleryController - VK-1624 runtime terrain-edit demo.
//
// Press K to call a salvo down on the terrain point under the cursor. Shells
// land over the next second or so and each one craters the ground; units then
// walk through the new terrain because the physics collider is rebuilt with it.
//
// Batching is the point of this script. Every shell that lands in a given frame
// deforms and paints immediately, and ONE Terrain::flush() at the end of
// onUpdate pays the seam weld + collider rebuild once for the whole salvo.
// Without the flush the craters still appear - the engine drains anything left
// pending a couple of frames later - but units would walk on last frame's ground
// for a tick or two.
//
// Attach one instance to a persistent scene entity (the GameSystems object).
//
// Verifying VK-1624 by hand:
//   1. Play, aim at flat ground, press K -> a cluster of craters appears
//   2. Walk a unit into one -> it follows the new surface (collider rebuilt)
//   3. Press K on a tile boundary -> no visible seam and no collision cliff
//   4. Stop -> the terrain reverts (play-mode edits are never saved)

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Key.mt";
import * from "../../lib/engine/Picker.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/engine/RaycastHit.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/Crater.mt";
import * from "../util/InputEdge.mt";

@Script
class ArtilleryController extends Behaviour {
    // ---- tuning ----
    private int   shellsPerSalvo;
    private float salvoSpread;      // world units the impacts scatter over
    private float shellInterval;    // seconds between impacts
    private float craterRadius;
    private float craterDepth;

    // ---- salvo state (a fixed pool, no per-shot allocation) ----
    private float[] shellX;
    private float[] shellZ;
    private float[] shellDelay;     // seconds until this shell lands
    private bool[]  shellLive;

    private InputEdge fireKey;

    public constructor() : super() {
        this.shellsPerSalvo = 6;
        this.salvoSpread = 9.0;
        this.shellInterval = 0.12;
        this.craterRadius = 5.0;
        this.craterDepth = 1.6;

        this.shellX = new float[this.shellsPerSalvo];
        this.shellZ = new float[this.shellsPerSalvo];
        this.shellDelay = new float[this.shellsPerSalvo];
        this.shellLive = new bool[this.shellsPerSalvo];

        this.fireKey = new InputEdge();
    }

    public function onStart(): void {
        for (int i = 0; i < this.shellsPerSalvo; i = i + 1) {
            this.shellLive[i] = false;
        }
        Log::info("[Artillery] Press K to shell the terrain under the cursor");
    }

    public function onUpdate(float deltaTime): void {
        this.fireKey.step(Input::isKeyDown(Key::K));
        if (this.fireKey.wasPressed) {
            this.callSalvo();
        }

        // Land everything whose fuse ran out this frame, inside ONE batch.
        int impacts = 0;
        bool batchOpen = false;

        for (int i = 0; i < this.shellsPerSalvo; i = i + 1) {
            if (!this.shellLive[i]) {
                continue;
            }

            this.shellDelay[i] = this.shellDelay[i] - deltaTime;
            if (this.shellDelay[i] > 0.0) {
                continue;
            }

            // Open the batch lazily: on a quiet frame nothing is opened at all,
            // so there is no flush to pay and no pending state to drain.
            if (!batchOpen) {
                Terrain::beginBatch();
                batchOpen = true;
            }

            this.shellLive[i] = false;
            if (Crater::impact(this.shellX[i], this.shellZ[i],
                               this.craterRadius, this.craterDepth)) {
                impacts = impacts + 1;
            }
        }

        if (batchOpen) {
            int pending = Terrain::flush();
            if (impacts > 0) {
                Log::info("[Artillery] " + impacts + " impact(s), " + pending + " tile(s) queued");
            }
        }
    }

    // Scatter a salvo around the terrain point under the cursor. Shells are
    // spaced in time so the craters visibly stack rather than appearing at once.
    private function callSalvo(): void {
        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();

        RaycastHit hit = Picker::pickTerrain(mx, my);
        if (!hit.hit) {
            Log::warn("[Artillery] No terrain under the cursor");
            return;
        }

        float cx = hit.point.x;
        float cz = hit.point.z;

        for (int i = 0; i < this.shellsPerSalvo; i = i + 1) {
            // Deterministic ring scatter - no RNG needed and it reads clearly
            // as a pattern of fire rather than noise.
            float angle = 6.2831853 * (float)i / (float)this.shellsPerSalvo;
            float ring = this.salvoSpread * (0.35 + 0.65 * (float)(i % 3) / 2.0);

            this.shellX[i] = cx + cos(angle) * ring;
            this.shellZ[i] = cz + sin(angle) * ring;
            this.shellDelay[i] = this.shellInterval * (float)i;
            this.shellLive[i] = true;
        }
    }
}
