// RTS top-down camera controller.
//
// Bindings are defined in the editor's Settings -> Input Mapping window and
// persisted to a .vfInputMapping file. This script consumes action and axis
// names only -- it does not register them.
//
// Required action names:    PanForward, PanBackward, PanLeft, PanRight, RotateCamera
// Required 2D axis name:    CameraPan  (up=PanForward, down=PanBackward, left=PanLeft, right=PanRight)
//
// Suggested default bindings (to set up via the editor UI):
//   PanForward    -> W, Up Arrow
//   PanBackward   -> S, Down Arrow
//   PanLeft       -> A, Left Arrow
//   PanRight      -> D, Right Arrow
//   RotateCamera  -> Mouse Middle

import * from "../../lib/engine/Camera.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/InputAction.mt";
import * from "../../lib/engine/InputAxis.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/engine/Terrain.mt";
import * from "../../lib/engine/Window.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "../util/Config.mt";
import * from "../util/Util.mt";

@Script
class RTSCameraController {
    private int selfId = -1;
    private int terrainId = -1;

    private float yaw = 0.0;
    private float pitch = -50.0;

    private float zoomLevel = 0.5;
    private float zoomSensitivity = 0.1;
    private float minHeight = 8.0;
    private float maxHeight = 80.0;

    private float panSpeed = 30.0;
    private float edgeThresholdPx = 8.0;
    private float rotateSensitivity = 0.25;

    private float focalX = 0.0;
    private float focalZ = 0.0;
    private float lastTerrainY = 0.0;

    constructor() {
    }

    public function onStart(): void {
        this.selfId = Entity::self();

        this.terrainId = Entity::findByName("Terrain");
        if (this.terrainId < 0) {
            Log::warn("[RTSCameraController] Terrain entity not found; height-follow will use fallback Y.");
        }


        this.applyTransform();
    }

    public function onUpdate(float deltaTime): void {
        //DISABLE panning and zooming for now, to focus on testing the UI and game state display.
        float ax = InputAxis::getValue2DX("CameraPan");
        float ay = InputAxis::getValue2DY("CameraPan");

        // Edge-of-screen panning disabled; keyboard CameraPan axis only.
        float dx = ax;
        float dy = ay;
        float mag = sqrt(dx * dx + dy * dy);
        if (mag > 1.0) {
            dx = dx / mag;
            dy = dy / mag;
        }

        // Rotate the screen-local pan (dx=right, dy=forward) into world XZ using the
        // engine's yaw convention (see EditorCamera): forward=(-sin,-cos), right=(cos,-sin).
        // world = right*dx + forward*dy. The previous formula flipped the cross-term signs,
        // which is a reflection rather than a rotation, so WASD desynced once the camera rotated.
        float yawRad = this.yaw * Config::DEG_TO_RAD;
        float sinY = sin(yawRad);
        float cosY = cos(yawRad);
        float worldDX = dx * cosY - dy * sinY;
        float worldDZ = -dx * sinY - dy * cosY;

        float speed = this.panSpeed * (0.5 + this.zoomLevel);
        this.focalX = this.focalX + worldDX * speed * deltaTime;
        this.focalZ = this.focalZ + worldDZ * speed * deltaTime;

        this.focalX = Util::clampF(this.focalX, Config::MAP_MIN_X, Config::MAP_MAX_X);
        this.focalZ = Util::clampF(this.focalZ, Config::MAP_MIN_Z, Config::MAP_MAX_Z);

        float scroll = Input::getMouseScrollDeltaY();
        if (scroll != 0.0) {
            this.zoomLevel = this.zoomLevel - scroll * this.zoomSensitivity;
            if (this.zoomLevel < 0.0) { this.zoomLevel = 0.0; }
            if (this.zoomLevel > 1.0) { this.zoomLevel = 1.0; }
        }

        if (InputAction::isDown("RotateCamera")) {
            this.yaw = this.yaw + Input::getMouseDeltaX() * this.rotateSensitivity;
        }

        this.applyTransform();
    }

    public function onDestroy(): void {

    }

    // Snap the camera focal point to a world XZ position (clamped to map bounds).
    // Used by MinimapController for minimap click-jump / drag-to-pan.
    public function jumpTo(float x, float z): void {
        this.focalX = x;
        this.focalZ = z;
        this.focalX = Util::clampF(this.focalX, Config::MAP_MIN_X, Config::MAP_MAX_X);
        this.focalZ = Util::clampF(this.focalZ, Config::MAP_MIN_Z, Config::MAP_MAX_Z);
        this.applyTransform();
    }

    private function applyTransform(): void {
        // Follow the terrain by sampling the CPU heightfield directly (no physics
        // collider dependency). Off-map samples return 0; keep the last good height.
        if (Terrain::hasHeightAt(this.focalX, this.focalZ)) {
            this.lastTerrainY = Terrain::heightAt(this.focalX, this.focalZ);
        }

        float currentHeight = this.minHeight + (this.maxHeight - this.minHeight) * this.zoomLevel;

        Vec3f camPos = new Vec3f(this.focalX, this.lastTerrainY + currentHeight, this.focalZ);
        Camera::setPosition(this.selfId, camPos);
        Camera::setRotation(this.selfId, new Vec3f(this.pitch, this.yaw, 0.0));
    }
}
