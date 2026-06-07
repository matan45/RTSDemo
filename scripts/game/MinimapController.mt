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

import * from "../lib/engine/Entity.mt";
import * from "../lib/engine/Input.mt";
import * from "../lib/engine/Mouse.mt";
import * from "../lib/engine/UI.mt";
import * from "../lib/engine/Camera.mt";
import * from "../lib/engine/Terrain.mt";
import * from "../lib/engine/Window.mt";
import * from "../lib/engine/Navmesh.mt";
import * from "../lib/engine/PluginComponent.mt";
import * from "../lib/engine/Log.mt";
import * from "../lib/math/Vec3f.mt";
import * from "./RTSCameraController.mt";

@Script
class MinimapController {
    private int minimapViewId;
    private int viewRectId;
    private int cameraId;
    private RTSCameraController cameraCtrl;

    // World bounds covered by the minimap camera (orthoSize 256 around origin).
    private float mapMinX = -256.0;
    private float mapMaxX = 256.0;
    private float mapMinZ = -256.0;
    private float mapMaxZ = 256.0;

    // Texture-to-world axis orientation. The minimap camera looks straight down
    // (pitch -90, yaw 0): screen-right = +X, screen-down = +Z. Flip a sign here
    // if the rendered minimap turns out mirrored on an axis.
    private float mapUToX = 1.0;
    private float mapVToZ = 1.0;

    // Input edge tracking (Input exposes state, not edges).
    private bool prevLeftDown;
    private bool prevRightDown;

    // True while a left-button pan that STARTED on the minimap is live; keeps
    // panning (clamped) even if the cursor slips off the minimap rect.
    private bool draggingFromMinimap;

    // Clamp for view-rect corner rays that point near/above the horizon.
    private float maxRayDistance = 1000.0;

    private float DEG_TO_RAD = 0.01745329252;

    constructor() {
        this.minimapViewId = -1;
        this.viewRectId = -1;
        this.cameraId = -1;
        this.cameraCtrl = null;
        this.prevLeftDown = false;
        this.prevRightDown = false;
        this.draggingFromMinimap = false;
    }

    public function onStart(): void {
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
        this.updateViewRect(rect);
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
        bool leftPressed = nowLeft && !this.prevLeftDown;
        bool rightPressed = nowRight && !this.prevRightDown;
        this.prevLeftDown = nowLeft;
        this.prevRightDown = nowRight;

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
    // of missing: they clamp to maxRayDistance and then to the map border.
    private function updateViewRect(float[] rect): void {
        if (this.viewRectId < 0 || this.cameraId < 0) {
            return;
        }

        Vec3f camPos = Camera::getPosition(this.cameraId);
        Vec3f camRot = Camera::getRotation(this.cameraId);
        float pitchRad = camRot.x * this.DEG_TO_RAD;
        float yawRad = camRot.y * this.DEG_TO_RAD;

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
        float tanV = tan(Camera::getFOV(this.cameraId) * 0.5 * this.DEG_TO_RAD);
        float tanH = tanV * (vw / vh);

        // Ground plane: terrain height directly under the camera (the RTS camera
        // sits above its focal point, so this matches what the player looks at).
        float groundY = 0.0;
        if (Terrain::hasHeightAt(camPos.x, camPos.z)) {
            groundY = Terrain::heightAt(camPos.x, camPos.z);
        }

        float minWX = this.mapMaxX;
        float maxWX = this.mapMinX;
        float minWZ = this.mapMaxZ;
        float maxWZ = this.mapMinZ;

        // Frustum corners in NDC: (su, sv) with sv = +1 at the top of the screen.
        for (int corner = 0; corner < 4; corner = corner + 1) {
            float su = -1.0;
            if (corner == 1 || corner == 2) { su = 1.0; }
            float sv = 1.0;
            if (corner == 2 || corner == 3) { sv = -1.0; }

            float dirX = fwdX + su * tanH * rightX + sv * tanV * upX;
            float dirY = fwdY + sv * tanV * upY;
            float dirZ = fwdZ + su * tanH * rightZ + sv * tanV * upZ;

            float t = this.maxRayDistance;
            if (dirY < -0.001) {
                t = (groundY - camPos.y) / dirY;
                if (t > this.maxRayDistance) { t = this.maxRayDistance; }
            }

            float wx = camPos.x + dirX * t;
            float wz = camPos.z + dirZ * t;
            if (wx < this.mapMinX) { wx = this.mapMinX; }
            if (wx > this.mapMaxX) { wx = this.mapMaxX; }
            if (wz < this.mapMinZ) { wz = this.mapMinZ; }
            if (wz > this.mapMaxZ) { wz = this.mapMaxZ; }

            if (wx < minWX) { minWX = wx; }
            if (wx > maxWX) { maxWX = wx; }
            if (wz < minWZ) { minWZ = wz; }
            if (wz > maxWZ) { maxWZ = wz; }
        }

        float px0 = this.worldToMinimapX(rect, minWX);
        float px1 = this.worldToMinimapX(rect, maxWX);
        float py0 = this.worldToMinimapY(rect, minWZ);
        float py1 = this.worldToMinimapY(rect, maxWZ);
        float minPX = px0; if (px1 < minPX) { minPX = px1; }
        float maxPX = px0; if (px1 > maxPX) { maxPX = px1; }
        float minPY = py0; if (py1 < minPY) { minPY = py1; }
        float maxPY = py0; if (py1 > maxPY) { maxPY = py1; }

        Entity::setActive(this.viewRectId, true);
        UI::setRectPixels(this.viewRectId, minPX, minPY, maxPX - minPX, maxPY - minPY);
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
        return this.mapMinX + u * (this.mapMaxX - this.mapMinX);
    }

    private function minimapToWorldZ(float[] rect, float py): float {
        float v = (py - rect[2]) / rect[4];
        if (v < 0.0) { v = 0.0; }
        if (v > 1.0) { v = 1.0; }
        if (this.mapVToZ < 0.0) { v = 1.0 - v; }
        return this.mapMinZ + v * (this.mapMaxZ - this.mapMinZ);
    }

    private function worldToMinimapX(float[] rect, float wx): float {
        float u = (wx - this.mapMinX) / (this.mapMaxX - this.mapMinX);
        if (this.mapUToX < 0.0) { u = 1.0 - u; }
        return rect[1] + u * rect[3];
    }

    private function worldToMinimapY(float[] rect, float wz): float {
        float v = (wz - this.mapMinZ) / (this.mapMaxZ - this.mapMinZ);
        if (this.mapVToZ < 0.0) { v = 1.0 - v; }
        return rect[2] + v * rect[4];
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
