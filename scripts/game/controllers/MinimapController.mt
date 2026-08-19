// MinimapController - RTS minimap interaction + camera view rectangle (VK-1315).
//
// Left-click (or hold-and-drag) on the minimap snaps the RTS camera focal point
// to the clicked world position. Right-click with units selected issues a
// Navmesh move command at the minimap-projected world position. A scene-authored
// UIImage ("RTS_HUD_MinimapViewRect") is repositioned every frame to the
// axis-aligned bounds of the main camera's visible ground area.
//
// The minimap camera ("camera minimap") is a top-down orthographic camera over
// the world origin with orthoSize 64 (ortho half-extent), so its 512x512 render
// texture maps 1:1 onto the playable world bounds [-64, 64] on X/Z -- the same
// Config::MAP_MIN/MAX_X/Z the view-rect and click-jump math clamp to. The minimap
// image's on-screen rect comes from UI::getRectPixels (same viewport-pixel space
// as Input::getViewportMouseX/Y), so anchoring and canvas scaling stay engine-side.
//
// Attach this @Script to the GameSystems entity alongside the other controllers.
// World-click controllers are unaffected: the minimap view blocks raycasts and
// they early-out on UI::isPointerOverUI(); press edges that start on the
// minimap never reach their drag state machines.

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Mouse.mt";
import * from "../../lib/engine/UI.mt";
import * from "../../lib/engine/Camera.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Window.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Streaming.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "./BuildingCommandController.mt";
import * from "./RTSCameraController.mt";
import * from "../util/Config.mt";
import * from "../util/InputEdge.mt";
import * from "../util/RTSFog.mt";

@Script
class MinimapController extends Behaviour {
    private int minimapViewId;
    private int viewRectId;
    private int cameraId;
    private RTSCameraController cameraCtrl;
    private BuildingCommandController? commandCtrl;

    // World bounds covered by the minimap camera (orthoSize 256 around origin)
    // are shared via Config::MAP_* (same values as the camera + placement).

    // Texture-to-world axis orientation. The minimap camera looks straight down
    // (pitch -90, yaw 0): screen-right = +X, screen-down = +Z. Flip a sign here
    // if the rendered minimap turns out mirrored on an axis.
    private float mapUToX = 1.0;
    private float mapVToZ = 1.0;

    // Input edge tracking (Input exposes state, not edges).
    private InputEdge leftEdge;
    private InputEdge rightEdge;

    // True while a left-button pan that STARTED on the minimap is live; keeps
    // panning (clamped) even if the cursor slips off the minimap rect.
    private bool draggingFromMinimap;

    // Far cap for view-rect corner rays, as a multiple of the camera's height
    // above the ground. With a 90-degree vertical FOV at pitch -50 the top
    // frustum rays nearly graze the horizon (-5 degrees), so the TRUE ground
    // footprint reaches the map border; capping at a few camera-heights keeps
    // the rectangle matched to the readable foreground instead of the horizon.
    private float viewDistanceFactor = 4.0;

    // --- Minimap entity blips (units + buildings) ---------------------------
    // A script-managed pool of small colored UIImage dots, one per Team-tagged
    // entity. Player = green, enemy = red; enemy dots are hidden outside current
    // vision (fog of war). Rebuilt at a low rate (blips drift slowly at minimap
    // scale). Each dot is positioned individually in viewport pixels against the
    // canvas (this engine's screen-space UI is flat) via the SAME worldFraction
    // math as the view-rect and click-jump, so all three share one coordinate
    // convention. A UIListView is deliberately NOT used: its forced UILayoutGroup
    // overwrites every item's anchoredPosition each frame, which would clobber the
    // per-dot placement. Surplus dots are deactivated (pooled), never destroyed.
    private int blipContainerId;        // transparent grouping node under the canvas
    private int[] blipPool;             // dot entity ids; -1 = slot not yet spawned
    private int[] blipKind;             // per-slot shape: 0 = unset, 1 = unit (circle), 2 = building (square)
    private int blipPoolCount;          // dots actually instantiated so far (<= blipMax)
    private int blipMax = 256;          // hard cap on simultaneous dots
    private float blipTimer;
    private float blipInterval = 0.1;   // seconds between rebuilds (~10 Hz)
    private float blipSize = 5.0;       // dot size in canvas units (scales with HUD)

    // Units (entities with a NavmeshAgent) are drawn as circles via this texture;
    // buildings stay as solid square quads (empty texture). Import the bundled
    // assets/ui/hud/minimap_circle.png to this .vfImage path; until it resolves,
    // the engine falls back to a tinted square (AssetRef.resolve -> "" -> white).
    private string unitBlipTexture = "assets/ui/hud/minimap_circle.vfImage";

    // --- Minimap fog-of-war overlay (VK-1488) ---------------------------------
    // A single UIImage sized to the minimap, layered BELOW the blips, showing the
    // RTSGameplay plugin's smooth RGBA fog texture (rgb=0, alpha=darkness) via the
    // generic engine "bind a plugin/GPU texture to a UIImage" API. The plugin owns
    // the texture and its colors; here we only spawn the image, match its rect to
    // the minimap, and bind the plugin's overlay key (RTSFog::overlayKey) once it
    // exists. F10 is honored plugin-side (the overlay goes transparent when off).
    private int fogOverlayId;      // fog overlay UIImage entity id (-1 = not spawned)
    private bool fogOverlayBound;  // true once the plugin's overlay texture key is bound

    // --- Minimap-jump streaming pre-warm (VK-1589) ----------------------------
    // jumpTo is a synchronous teleport with no arrival event, and in a sector world the
    // camera's own ring then has to pull the destination in a sector at a time. Registering
    // a streaming source AT the destination gives the streamer a head start and, unlike the
    // camera, lets it outrank everything else for the per-frame load budget.
    //
    // Shape is "register on press -> follow while held -> release after a linger", NOT
    // "release on arrival": the drag-pan path re-issues a jump every held frame, so the
    // destination keeps moving and there is nothing to arrive at. The linger keeps the
    // destination pinned for a moment after release so the ring finishes filling.
    //
    // priority 2 is deliberate and is the OPPOSITE call from EnemyBases (priority 0). Here
    // out-bidding the camera is the entire point - the camera is already at the destination
    // and its own ring would otherwise compete with itself.
    private bool prewarmEnabled = true;         // flip to false for the A/B measurement below
    private int prewarmSourceId;                // 0 = nothing registered
    private float prewarmX;
    private float prewarmY;
    private float prewarmZ;
    private bool prewarmTargetLive;             // a jump destination is being held this frame
    private float prewarmLinger;                // seconds left to hold after release
    private float prewarmLingerTime = 1.5;
    private float prewarmRadiusMultiplier = 1.0;
    private int prewarmPriority = 2;

    // Frames-to-ready instrumentation. Counts frames from the press edge until the
    // destination sector reports Loaded; run once with prewarmEnabled false and once true
    // to get the comparison. In a non-sector scene isSectorLoadedAt is always true, so this
    // honestly reports 1 frame rather than pretending to measure something.
    private bool measuring;
    private int measureFrames;
    private float measureX;
    private float measureZ;
    private int measureFrameCap = 600;          // ~10s at 60fps; give up rather than count forever

    public constructor() : super() {
        this.minimapViewId = -1;
        this.viewRectId = -1;
        this.cameraId = -1;
        this.cameraCtrl = null;
        this.commandCtrl = null;
        this.draggingFromMinimap = false;
        this.blipContainerId = -1;
        this.blipPoolCount = 0;
        this.blipTimer = 0.0;
        this.fogOverlayId = -1;
        this.fogOverlayBound = false;
        this.prewarmSourceId = 0;
        this.prewarmX = 0.0;
        this.prewarmY = 0.0;
        this.prewarmZ = 0.0;
        this.prewarmTargetLive = false;
        this.prewarmLinger = 0.0;
        this.measuring = false;
        this.measureFrames = 0;
        this.measureX = 0.0;
        this.measureZ = 0.0;
    }

    public function onStart(): void {
        this.leftEdge = new InputEdge();
        this.rightEdge = new InputEdge();
        this.minimapViewId = Entity::findByName("RTS_HUD_MinimapView");
        if (this.minimapViewId < 0) {
            Log::warn("[Minimap] RTS_HUD_MinimapView not found; minimap input disabled.");
        }

        this.viewRectId = Entity::findByName("RTS_HUD_MinimapViewRect");
        if (this.viewRectId < 0) {
            Log::warn("[Minimap] RTS_HUD_MinimapViewRect not found; camera view rectangle disabled.");
        } else {
            Entity::setActive(this.viewRectId, false);
        }

        this.cameraId = Entity::findByName("camera");
        if (this.cameraId < 0) {
            Log::warn("[Minimap] camera entity not found; click-jump disabled.");
        }

        // VK-1415: filter the top-down minimap so meshes tagged LAYER_NO_MINIMAP
        // (decorative props) are not drawn into the minimap render texture. The
        // minimap camera ("camera minimap") is RTT-is-camera, so its cullingMask
        // flows straight into the RTT cull pass. Other views keep all layers.
        int minimapCamId = Entity::findByName("camera minimap");
        if (minimapCamId >= 0) {
            Camera::setCullingMask(minimapCamId, Config::MINIMAP_CULL_MASK);
        } else {
            Log::warn("[Minimap] 'camera minimap' not found; minimap layer filter not applied.");
        }

        // Spawn the fog overlay BEFORE the blip container so it renders below the blips.
        this.setupFogOverlay();
        this.setupBlips();

        Log::info("[Minimap] ready.");
    }

    // Find-or-create the transparent blip container under RTS_HUD_Canvas, then
    // adopt any dots left over from a previous play session as the pool (so a
    // replay reuses them instead of spawning duplicates). Mirrors the idempotent
    // setupQueueUI pattern in BuildingCommandController.
    private function setupBlips(): void {
        this.blipPool = new int[this.blipMax];
        this.blipKind = new int[this.blipMax];
        for (int i = 0; i < this.blipMax; i = i + 1) {
            this.blipPool[i] = -1;
            this.blipKind[i] = 0;
        }
        this.blipPoolCount = 0;

        this.blipContainerId = Entity::findByName("RTS_HUD_MinimapBlips");
        if (this.blipContainerId < 0) {
            int canvasId = Entity::findByName("RTS_HUD_Canvas");
            if (canvasId < 0) {
                Log::warn("[Minimap] RTS_HUD_Canvas missing; unit blips disabled.");
                return;
            }
            this.blipContainerId = Entity::instantiateChild("assets/ui/prefabs/minimap_blips_prefab.vfPrefab", canvasId);
        }
        if (this.blipContainerId < 0) {
            Log::warn("[Minimap] Failed to spawn minimap blips container.");
            return;
        }

        int[] existing = Entity::getChildren(this.blipContainerId);
        int adopt = existing.length;
        if (adopt > this.blipMax) {
            adopt = this.blipMax;
        }
        for (int i = 0; i < adopt; i = i + 1) {
            this.blipPool[i] = existing[i];
            Entity::setActive(existing[i], false);
        }
        this.blipPoolCount = adopt;
    }

    // Find-or-create the fog overlay UIImage under the canvas (idempotent across
    // replays, mirroring setupBlips). Spawned before the blip container so the
    // blips draw on top of the fog.
    private function setupFogOverlay(): void {
        this.fogOverlayId = Entity::findByName("RTS_HUD_MinimapFog");
        if (this.fogOverlayId < 0) {
            if (this.minimapViewId < 0) {
                Log::warn("[Minimap] RTS_HUD_MinimapView missing; fog overlay disabled.");
                return;
            }
            // Parent the fog UNDER the minimap image (not the canvas). UI render order is
            // a depth-first traversal, so the fog draws right after the minimap terrain but
            // BEFORE the later-authored view-rect and the runtime blip container -- keeping
            // the camera view-rectangle and the blips on top of the fog.
            this.fogOverlayId = Entity::instantiateChild("assets/ui/prefabs/minimap_fog_prefab.vfPrefab", this.minimapViewId);
        }
        if (this.fogOverlayId < 0) {
            Log::warn("[Minimap] Failed to spawn minimap fog overlay.");
        }
    }

    // Keep the fog overlay matched to the minimap image's rect (same canvas-unit
    // basis as the blips/view-rect, so the world-XZ fog mask aligns 1:1 with the
    // minimap) and bind the plugin's overlay texture key once it is available. The
    // plugin sizes/colors the fog and honors F10; this only positions + binds it.
    private function updateFogOverlay(): void {
        if (this.fogOverlayId < 0) {
            return;
        }

        float[] view = UI::getRectData(this.minimapViewId);
        if (view[0] >= 0.5) {
            UI::setRectData(this.fogOverlayId, view[1], view[2], view[3], view[4],
                view[5], view[6], view[7], view[8], view[9], view[10]);
        }

        if (this.fogOverlayBound) {
            return;
        }
        string key = RTSFog::overlayKey();
        if (key != "") {
            UI::setImageExternalTexture(this.fogOverlayId, key);
            UI::setImageColor(this.fogOverlayId, 1.0, 1.0, 1.0, 1.0);
            this.fogOverlayBound = true;
            Log::info("[Minimap] fog overlay bound (" + key + ")");
        }
    }

    // Return the dot entity for pool slot `index`, lazily spawning it on first
    // use (updateBlips always requests slots in order, so there are no gaps).
    // Returns -1 past the cap.
    private function ensureBlip(int index): int {
        if (index < 0 || index >= this.blipMax) {
            return -1;
        }
        if (this.blipPool[index] < 0) {
            this.blipPool[index] = Entity::instantiateChild("assets/ui/prefabs/minimap_blip_prefab.vfPrefab", this.blipContainerId);
            if (index + 1 > this.blipPoolCount) {
                this.blipPoolCount = index + 1;
            }
        }
        return this.blipPool[index];
    }

    public function onUpdate(float deltaTime): void {
        // VK-1589: cleared here, not in handleInput, so the early-outs below also count as
        // "no jump target this frame" - otherwise a minimap that stops resolving would
        // strand the pre-warm source registered forever.
        this.prewarmTargetLive = false;

        if (this.minimapViewId < 0) {
            return;
        }

        // Resolved on-screen rect of the minimap image; [valid, x, y, w, h].
        float[] rect = UI::getRectPixels(this.minimapViewId);
        if (rect[0] < 0.5 || rect[3] <= 0.0 || rect[4] <= 0.0) {
            return;
        }

        this.handleInput(rect);
        this.updateViewRect();
        this.updateFogOverlay();

        // Rebuild the entity blip layer at a low rate (cheap at minimap scale).
        this.blipTimer = this.blipTimer + deltaTime;
        if (this.blipTimer >= this.blipInterval) {
            this.blipTimer = 0.0;
            this.updateBlips();
        }
    }

    // VK-1589: the sector streamer runs on the main thread as part of the pre-Transforms
    // block, and onLateUpdate is ordered after it. Doing the Streaming:: work here rather
    // than in handleInput keeps a per-frame writer off the streamer's back.
    public function onLateUpdate(float deltaTime): void {
        this.updateJumpPrewarm(deltaTime);
        this.updateReadyMeasure();
    }

    public function onDestroy(): void {
        // Never leak the transient source across a play-stop or a script reload: it has no
        // owner entity, so the engine's auto-unregister hook cannot clean it up.
        if (this.prewarmSourceId != 0) {
            Streaming::unregisterWorldSource(this.prewarmSourceId);
            this.prewarmSourceId = 0;
        }
        this.prewarmTargetLive = false;
        this.measuring = false;
    }

    // ============================================
    // Jump pre-warm (VK-1589)
    // ============================================

    private function updateJumpPrewarm(float deltaTime): void {
        if (!this.prewarmEnabled) {
            return;
        }

        if (this.prewarmTargetLive) {
            // Refresh the linger every held frame so the countdown always starts full
            // once the button comes up, whatever ended the drag.
            this.prewarmLinger = this.prewarmLingerTime;

            if (this.prewarmSourceId == 0) {
                this.prewarmSourceId = Streaming::registerWorldSource(
                    this.prewarmX, this.prewarmY, this.prewarmZ,
                    this.prewarmRadiusMultiplier, this.prewarmPriority, 0);
            } else {
                Streaming::updateWorldSource(this.prewarmSourceId,
                                             this.prewarmX, this.prewarmY, this.prewarmZ);
            }
            return;
        }

        if (this.prewarmSourceId == 0) {
            return;
        }

        this.prewarmLinger = this.prewarmLinger - deltaTime;
        if (this.prewarmLinger <= 0.0) {
            Streaming::unregisterWorldSource(this.prewarmSourceId);
            this.prewarmSourceId = 0;
        }
    }

    // Frames from the jump press until the destination sector reports Loaded (AC of
    // VK-1589). Toggle prewarmEnabled between runs to get the before/after numbers.
    private function updateReadyMeasure(): void {
        if (!this.measuring) {
            return;
        }

        this.measureFrames = this.measureFrames + 1;

        if (Streaming::isSectorLoadedAt(this.measureX, this.measureZ)) {
            this.measuring = false;
            Log::info("[Minimap] jump destination ready after "
                      + parsePrimitive(this.measureFrames) + " frame(s), pre-warm "
                      + this.prewarmLabel() + ".");
            return;
        }

        if (this.measureFrames >= this.measureFrameCap) {
            this.measuring = false;
            Log::warn("[Minimap] jump destination still not loaded after "
                      + parsePrimitive(this.measureFrames) + " frame(s), pre-warm "
                      + this.prewarmLabel() + "; giving up on the measurement.");
        }
    }

    private function prewarmLabel(): string {
        if (this.prewarmEnabled) {
            return "on";
        }
        return "off";
    }

    // ============================================
    // Input: click-jump, drag-pan, move command
    // ============================================

    private function handleInput(float[] rect): void {
        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();
        bool nowLeft = Input::isMouseButtonDown(Mouse::LEFT);
        bool nowRight = Input::isMouseButtonDown(Mouse::RIGHT);
        this.leftEdge.step(nowLeft);
        this.rightEdge.step(nowRight);
        bool leftPressed = this.leftEdge.wasPressed;
        bool rightPressed = this.rightEdge.wasPressed;

        bool inside = this.containsPoint(rect, mx, my);

        // Left button: jump on press inside the minimap, then keep panning while
        // held (single click and click-drag share the same path).
        if (leftPressed && inside) {
            this.draggingFromMinimap = true;
        }
        if (!nowLeft) {
            this.draggingFromMinimap = false;
        }

        // VK-1589: only record the destination here (prewarmTargetLive was cleared at the
        // top of onUpdate). The Streaming:: calls themselves happen in onLateUpdate, which
        // is ordered after the engine's sector-streaming task; onUpdate runs on a worker
        // thread alongside it.
        if (this.draggingFromMinimap) {
            float wx = this.minimapToWorldX(rect, mx);
            float wz = this.minimapToWorldZ(rect, my);
            RTSCameraController cam = this.camera();
            if (cam != null) {
                cam.jumpTo(wx, wz);
            }

            float wy = 0.0;
            if (Terrain::hasHeightAt(wx, wz)) {
                wy = Terrain::heightAt(wx, wz);
            }
            this.prewarmX = wx;
            this.prewarmY = wy;
            this.prewarmZ = wz;
            this.prewarmTargetLive = true;

            // Measure from the press edge only: a drag re-targets every frame, so
            // restarting the clock mid-drag would never converge.
            if (leftPressed) {
                this.measuring = true;
                this.measureFrames = 0;
                this.measureX = wx;
                this.measureZ = wz;
            }
        }

        // Right button: issue a move command for the current unit selection at
        // the minimap-projected world position (press edge only; no-op when
        // nothing is selected).
        if (rightPressed && inside && !this.draggingFromMinimap) {
            float wx = this.minimapToWorldX(rect, mx);
            float wz = this.minimapToWorldZ(rect, my);
            float wy = 0.0;
            if (Terrain::hasHeightAt(wx, wz)) {
                wy = Terrain::heightAt(wx, wz);
            }
            Vec3f dest = new Vec3f(wx, wy, wz);
            BuildingCommandController? command = this.command();
            if (command != null) {
                command.issueSelectedMinimapMove(dest);
            } else {
                int[] fallbackSelected = PluginComponent::findAll("Selected");
                Navmesh::setGroupDestination(fallbackSelected, dest, 2.0, Navmesh::FORMATION_GRID);
            }
            int[] selectedForLog = PluginComponent::findAll("Selected");
            if (selectedForLog.length > 0) {
                Log::info("[Minimap] move command -> (" + wx + ", " + wz + ") for " + selectedForLog.length + " unit(s)");
            }
        }
    }

    // ============================================
    // Camera view rectangle
    // ============================================

    // Intersect the main camera's four frustum corner rays with the ground plane
    // under the camera, clamp to the map bounds, and fit the scene-authored
    // view-rect UIImage to their bounding box on the minimap. Analytic ray-plane
    // math (no terrain raycasts) so near-horizon rays degrade gracefully instead
    // of missing: they clamp to the zoom-adaptive far cap (viewDistanceFactor
    // camera-heights) and then to the map border.
    private function updateViewRect(): void {
        if (this.viewRectId < 0 || this.cameraId < 0) {
            return;
        }

        Vec3f camPos = Camera::getPosition(this.cameraId);
        Vec3f camRot = Camera::getRotation(this.cameraId);
        float pitchRad = camRot.x * Config::DEG_TO_RAD;
        float yawRad = camRot.y * Config::DEG_TO_RAD;

        // Camera basis from the engine's yaw convention (see RTSCameraController):
        // horizontal forward = (-sin, -cos), right = (cos, -sin) in world XZ.
        float sp = sin(pitchRad);
        float cp = cos(pitchRad);
        float sy = sin(yawRad);
        float cy = cos(yawRad);
        float fwdX = -cp * sy;
        float fwdY = sp;
        float fwdZ = -cp * cy;
        float rightX = cy;
        float rightZ = -sy;
        // up = right x forward (right-handed; tilts over the horizon when pitched down)
        float upX = sp * sy;
        float upY = cp;
        float upZ = sp * cy;

        // Vertical FOV (engine convention, see Matrix4f::perspective) + viewport aspect.
        float vw = (float)Window::getViewportWidth();
        float vh = (float)Window::getViewportHeight();
        if (vw <= 0.0 || vh <= 0.0) {
            return;
        }
        float tanV = tan(Camera::getFOV(this.cameraId) * 0.5 * Config::DEG_TO_RAD);
        float tanH = tanV * (vw / vh);

        // Ground plane: terrain height directly under the camera (the RTS camera
        // sits above its focal point, so this matches what the player looks at).
        float groundY = 0.0;
        if (Terrain::hasHeightAt(camPos.x, camPos.z)) {
            groundY = Terrain::heightAt(camPos.x, camPos.z);
        }

        // Zoom-adaptive far cap (see viewDistanceFactor).
        float heightAbove = camPos.y - groundY;
        if (heightAbove < 1.0) { heightAbove = 1.0; }
        float tCap = this.viewDistanceFactor * heightAbove;

        float minWX = Config::MAP_MAX_X;
        float maxWX = Config::MAP_MIN_X;
        float minWZ = Config::MAP_MAX_Z;
        float maxWZ = Config::MAP_MIN_Z;

        // Frustum corners in NDC: (su, sv) with sv = +1 at the top of the screen.
        for (int corner = 0; corner < 4; corner = corner + 1) {
            float su = -1.0;
            if (corner == 1 || corner == 2) { su = 1.0; }
            float sv = 1.0;
            if (corner == 2 || corner == 3) { sv = -1.0; }

            float dirX = fwdX + su * tanH * rightX + sv * tanV * upX;
            float dirY = fwdY + sv * tanV * upY;
            float dirZ = fwdZ + su * tanH * rightZ + sv * tanV * upZ;

            float t = tCap;
            if (dirY < -0.001) {
                t = (groundY - camPos.y) / dirY;
                if (t > tCap) { t = tCap; }
            }

            float wx = camPos.x + dirX * t;
            float wz = camPos.z + dirZ * t;
            if (wx < Config::MAP_MIN_X) { wx = Config::MAP_MIN_X; }
            if (wx > Config::MAP_MAX_X) { wx = Config::MAP_MAX_X; }
            if (wz < Config::MAP_MIN_Z) { wz = Config::MAP_MIN_Z; }
            if (wz > Config::MAP_MAX_Z) { wz = Config::MAP_MAX_Z; }

            if (wx < minWX) { minWX = wx; }
            if (wx > maxWX) { maxWX = wx; }
            if (wz < minWZ) { minWZ = wz; }
            if (wz > maxWZ) { maxWZ = wz; }
        }

        // World bounds -> [0,1] fractions of the minimap image (u=X, v=Z).
        float fxA = this.worldFractionX(minWX);
        float fxB = this.worldFractionX(maxWX);
        float u0 = fxA; if (fxB < u0) { u0 = fxB; }
        float u1 = fxA; if (fxB > u1) { u1 = fxB; }
        float fzA = this.worldFractionZ(minWZ);
        float fzB = this.worldFractionZ(maxWZ);
        float v0 = fzA; if (fzB < v0) { v0 = fzB; }
        float v1 = fzA; if (fzB > v1) { v1 = fzB; }

        // Place the view-rect in the minimap image's OWN canvas-unit basis instead
        // of via pixel round-trip. getRectPixels resolves against the editor play
        // panel while the image renders against the framebuffer; when those differ
        // in aspect (normal in editor play mode) a pixel-based view-rect drifts off
        // the map. Sharing the image's anchor + canvas-unit sizeDelta/anchoredPos
        // makes both resolve identically under ANY extent (VK minimap drift fix).
        // getRectData -> [valid, anchorMinX, anchorMinY, anchorMaxX, anchorMaxY,
        //   pivotX, pivotY, sizeDeltaX, sizeDeltaY, anchoredX, anchoredY].
        float[] view = UI::getRectData(this.minimapViewId);
        if (view[0] < 0.5) {
            return;
        }
        float anchorX = view[1];
        float anchorY = view[2];
        float viewPivotX = view[5];
        float viewPivotY = view[6];
        float viewSizeX = view[7];
        float viewSizeY = view[8];
        float viewAnchoredX = view[9];
        float viewAnchoredY = view[10];

        // Sub-rectangle of the image with a top-left pivot, anchored to the image's
        // own anchor so the canvas-scale/extent factors cancel between the two.
        // (Assumes anchorMin == anchorMax on the image, as the minimap view is
        // authored; the anchor-span term is zero in that case.)
        float rectSizeX = (u1 - u0) * viewSizeX;
        float rectSizeY = (v1 - v0) * viewSizeY;
        float rectAnchoredX = viewAnchoredX - viewPivotX * viewSizeX + u0 * viewSizeX;
        float rectAnchoredY = viewAnchoredY + viewPivotY * viewSizeY - v0 * viewSizeY;

        Entity::setActive(this.viewRectId, true);
        UI::setRectData(this.viewRectId, anchorX, anchorY, anchorX, anchorY,
            0.0, 0.0, rectSizeX, rectSizeY, rectAnchoredX, rectAnchoredY);
    }

    // ============================================
    // Entity blips (units + buildings)
    // ============================================

    // One blip per Team-tagged entity: units (navmesh agents) draw as colored
    // circles, buildings as colored squares; player vs enemy is hue-coded within
    // each. Enemy blips are hidden outside current player vision (RTSFog); off-map
    // entities are dropped. Each surviving blip is placed in the minimap image's
    // OWN canvas-unit basis (UI::getRectData/setRectData) via the shared
    // worldFraction math -- the SAME extent-invariant approach as the view-rect
    // (updateViewRect). The old getRectPixels/setRectPixels path drifted in editor
    // play mode (play-panel extent vs framebuffer extent); see the VK minimap drift
    // fix. `k` active blips are positioned from the pool; the rest are deactivated.
    // Entities past the `blipMax` cap are silently dropped (256 is generous here).
    private function updateBlips(): void {
        if (this.blipContainerId < 0) {
            return;
        }

        // Minimap image authored fields in canvas units (extent-independent):
        // [valid, anchorMinX,Y, anchorMaxX,Y, pivotX,Y, sizeDeltaX,Y, anchoredX,Y].
        float[] img = UI::getRectData(this.minimapViewId);
        if (img[0] < 0.5) {
            return;
        }
        float amx = img[1];
        float amy = img[2];
        float pvx = img[5];
        float pvy = img[6];
        float sx = img[7];
        float sy = img[8];
        float apx = img[9];
        float apy = img[10];

        int[] ids = PluginComponent::findAll("Team");
        int n = ids.length;
        int k = 0;

        for (int i = 0; i < n; i = i + 1) {
            if (k >= this.blipMax) {
                continue;   // hit the dot cap; ignore the remaining entities
            }
            int id = ids[i];
            int team = PluginComponent::getInt(id, "Team", "teamId");
            bool player = (team == Config::TEAM_PLAYER);

            Vec3f pos = Entity::getPosition(id);
            if (!player && !RTSFog::isVisible(pos.x, pos.z)) {
                continue;   // enemy outside current vision
            }

            float fx = this.worldFractionX(pos.x);
            float fz = this.worldFractionZ(pos.z);
            if (fx < 0.0 || fx > 1.0 || fz < 0.0 || fz > 1.0) {
                continue;   // off the minimap footprint
            }

            int blip = this.ensureBlip(k);
            if (blip < 0) {
                continue;
            }
            // Center the dot at image fraction (fx, fz) in the image's own
            // canvas-unit anchor basis -- same math as the view-rect, but with a
            // centered pivot instead of top-left. scale cancels => extent-invariant.
            float bax = apx - pvx * sx + fx * sx;
            float bay = apy + pvy * sy - fz * sy;
            Entity::setActive(blip, true);
            UI::setRectData(blip, amx, amy, amx, amy, 0.5, 0.5,
                this.blipSize, this.blipSize, bax, bay);

            // Shape: units (navmesh agents) draw as circles, buildings as squares.
            // Swap the texture only when this pooled slot changes kind (avoids
            // churning the texture ref every frame).
            bool isUnit = Entity::hasComponent(id, "NavmeshAgent");
            int kind = 2;
            if (isUnit) {
                kind = 1;
            }
            if (this.blipKind[k] != kind) {
                if (isUnit) {
                    UI::setImageTexture(blip, this.unitBlipTexture);
                } else {
                    UI::setImageTexture(blip, "");
                }
                this.blipKind[k] = kind;
            }

            // Color: units a distinct hue from buildings, each still friend/foe coded.
            if (isUnit) {
                if (player) {
                    UI::setImageColor(blip, 0.2, 0.9, 1.0, 1.0);    // player unit: cyan
                } else {
                    UI::setImageColor(blip, 1.0, 0.55, 0.1, 1.0);   // enemy unit: orange
                }
            } else {
                if (player) {
                    UI::setImageColor(blip, 0.25, 1.0, 0.4, 1.0);   // player building: green
                } else {
                    UI::setImageColor(blip, 1.0, 0.3, 0.25, 1.0);   // enemy building: red
                }
            }
            k = k + 1;
        }

        // Deactivate dots left over from a previously busier frame.
        for (int j = k; j < this.blipPoolCount; j = j + 1) {
            int extra = this.blipPool[j];
            if (extra >= 0) {
                Entity::setActive(extra, false);
            }
        }
    }

    // ============================================
    // Minimap <-> world mapping
    // ============================================

    private function containsPoint(float[] rect, float x, float y): bool {
        if (x < rect[1] || x > rect[1] + rect[3]) { return false; }
        if (y < rect[2] || y > rect[2] + rect[4]) { return false; }
        return true;
    }

    private function minimapToWorldX(float[] rect, float px): float {
        float u = (px - rect[1]) / rect[3];
        if (u < 0.0) { u = 0.0; }
        if (u > 1.0) { u = 1.0; }
        if (this.mapUToX < 0.0) { u = 1.0 - u; }
        return Config::MAP_MIN_X + u * (Config::MAP_MAX_X - Config::MAP_MIN_X);
    }

    private function minimapToWorldZ(float[] rect, float py): float {
        float v = (py - rect[2]) / rect[4];
        if (v < 0.0) { v = 0.0; }
        if (v > 1.0) { v = 1.0; }
        if (this.mapVToZ < 0.0) { v = 1.0 - v; }
        return Config::MAP_MIN_Z + v * (Config::MAP_MAX_Z - Config::MAP_MIN_Z);
    }

    // [0,1] fraction of the minimap image for a world X (honoring the axis sign).
    // 0 = image left edge, 1 = image right edge.
    private function worldFractionX(float wx): float {
        float u = (wx - Config::MAP_MIN_X) / (Config::MAP_MAX_X - Config::MAP_MIN_X);
        if (this.mapUToX < 0.0) { u = 1.0 - u; }
        return u;
    }

    // [0,1] fraction of the minimap image for a world Z (honoring the axis sign).
    // 0 = image top edge, 1 = image bottom edge (screen-down = +Z).
    private function worldFractionZ(float wz): float {
        float v = (wz - Config::MAP_MIN_Z) / (Config::MAP_MAX_Z - Config::MAP_MIN_Z);
        if (this.mapVToZ < 0.0) { v = 1.0 - v; }
        return v;
    }

    // Resolve (and cache) the RTSCameraController attached to the camera entity.
    // May be null until that script has loaded.
    private function camera(): RTSCameraController? {
        if (this.cameraCtrl != null) {
            return this.cameraCtrl;
        }
        if (this.cameraId < 0) {
            return null;
        }
        this.cameraCtrl = Entity::getScript<RTSCameraController>(this.cameraId, "RTSCameraController");
        if (this.cameraCtrl != null) {
            Log::info("[Minimap] RTSCameraController resolved.");
        }
        return this.cameraCtrl;
    }

    private function command(): BuildingCommandController? {
        if (this.commandCtrl != null) {
            return this.commandCtrl;
        }
        this.commandCtrl = this.gameObject().getScript<BuildingCommandController>("BuildingCommandController");
        return this.commandCtrl;
    }
}
