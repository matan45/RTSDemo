// MinimapController - RTS minimap interaction + camera view rectangle (VK-1315).
//
// Left-click (or hold-and-drag) on the minimap snaps the RTS camera focal point
// to the clicked world position. Right-click with units selected issues a
// Navmesh move command at the minimap-projected world position. A scene-authored
// UIImage ("RTS_HUD_MinimapViewRect") is repositioned every frame to the
// axis-aligned bounds of the main camera's visible ground area.
//
// The minimap camera ("camera minimap") is a top-down orthographic camera over
// the world origin with orthoSize 256, so its 512x512 render texture maps 1:1
// onto the world bounds [-256, 256] on X/Z. The minimap image's on-screen rect
// comes from UI::getRectPixels (same viewport-pixel space as
// Input::getViewportMouseX/Y), so anchoring and canvas scaling stay engine-side.
//
// Attach this @Script to the GameSystems entity alongside the other controllers.
// World-click controllers are unaffected: the minimap view blocks raycasts and
// they early-out on UI::isPointerOverUI(); press edges that start on the
// minimap never reach their drag state machines.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Mouse.mt";
import * from "../../lib/engine/UI.mt";
import * from "../../lib/engine/Camera.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Window.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "./RTSCameraController.mt";
import * from "../util/Config.mt";
import * from "../util/InputEdge.mt";

@Script
class MinimapController {
    private int minimapViewId;
    private int viewRectId;
    private int cameraId;
    private RTSCameraController cameraCtrl;

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

    constructor() {
        this.minimapViewId = -1;
        this.viewRectId = -1;
        this.cameraId = -1;
        this.cameraCtrl = null;
        this.draggingFromMinimap = false;
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

        Log::info("[Minimap] ready.");
    }

    public function onUpdate(float deltaTime): void {
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
    }

    public function onDestroy(): void {
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
        if (this.draggingFromMinimap) {
            float wx = this.minimapToWorldX(rect, mx);
            float wz = this.minimapToWorldZ(rect, my);
            RTSCameraController cam = this.camera();
            if (cam != null) {
                cam.jumpTo(wx, wz);
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
            int[] selected = PluginComponent::findAll("Selected");
            for (int i = 0; i < selected.length; i = i + 1) {
                Navmesh::moveTo(selected[i], new Vec3f(wx, wy, wz));
            }
            if (selected.length > 0) {
                Log::info("[Minimap] move command -> (" + wx + ", " + wz + ") for " + selected.length + " unit(s)");
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
}
