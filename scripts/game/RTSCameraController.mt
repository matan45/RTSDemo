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

import * from "../lib/engine/Camera.mt";
import * from "../lib/engine/Entity.mt";
import * from "../lib/engine/Input.mt";
import * from "../lib/engine/InputAction.mt";
import * from "../lib/engine/InputAxis.mt";
import * from "../lib/engine/Log.mt";
import * from "../lib/engine/Physics.mt";
import * from "../lib/engine/RaycastHit.mt";
import * from "../lib/engine/Window.mt";
import * from "../lib/math/Vec3f.mt";

@Script
class RTSCameraController {
    private int selfId = -1;
    private int terrainId = -1;

    private float yaw = 0.0;
    private float pitch = 50.0;

    private float zoomLevel = 0.5;
    private float zoomSensitivity = 0.1;
    private float minHeight = 8.0;
    private float maxHeight = 80.0;

    private float panSpeed = 30.0;
    private float edgeThresholdPx = 8.0;
    private float rotateSensitivity = 0.25;

    private float mapMinX = -256.0;
    private float mapMaxX = 256.0;
    private float mapMinZ = -256.0;
    private float mapMaxZ = 256.0;

    private float focalX = 0.0;
    private float focalZ = 0.0;
    private float lastTerrainY = 0.0;

    private float DEG_TO_RAD = 0.01745329252;

    constructor() {
    }

    public function onStart(): void {
        this.selfId = Entity::self();

        Camera::setIsPrimary(this.selfId, true);

        this.terrainId = Entity::findByName("Terrain");
        if (this.terrainId < 0) {
            Log::warn("[RTSCameraController] Terrain entity not found; height-follow will use fallback Y.");
        }


        this.applyTransform();
    }

    public function onUpdate(float deltaTime): void {
        float ax = InputAxis::getValue2DX("CameraPan");
        float ay = InputAxis::getValue2DY("CameraPan");

        float mx = Input::getMouseX();
        float my = Input::getMouseY();
        int   ww = Window::getWidth();
        int   wh = Window::getHeight();

        float ex = 0.0;
        float ey = 0.0;
        if (mx <= this.edgeThresholdPx) { ex = -1.0; }
        if (mx >= ww - this.edgeThresholdPx) { ex = 1.0; }
        // Y=0 is top of window; "forward" pan should fire when cursor is near the top edge.
        if (my <= this.edgeThresholdPx) { ey = 1.0; }
        if (my >= wh - this.edgeThresholdPx) { ey = -1.0; }

        float dx = ax + ex;
        float dy = ay + ey;
        float mag = sqrt(dx * dx + dy * dy);
        if (mag > 1.0) {
            dx = dx / mag;
            dy = dy / mag;
        }

        float yawRad = this.yaw * this.DEG_TO_RAD;
        float sinY = sin(yawRad);
        float cosY = cos(yawRad);
        float worldDX = dx * cosY + dy * sinY;
        float worldDZ = dx * sinY - dy * cosY;

        float speed = this.panSpeed * (0.5 + this.zoomLevel);
        this.focalX = this.focalX + worldDX * speed * deltaTime;
        this.focalZ = this.focalZ + worldDZ * speed * deltaTime;

        if (this.focalX < this.mapMinX) { this.focalX = this.mapMinX; }
        if (this.focalX > this.mapMaxX) { this.focalX = this.mapMaxX; }
        if (this.focalZ < this.mapMinZ) { this.focalZ = this.mapMinZ; }
        if (this.focalZ > this.mapMaxZ) { this.focalZ = this.mapMaxZ; }

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
        if (this.selfId >= 0) {
            Camera::setIsPrimary(this.selfId, false);
        }
    }

    private function applyTransform(): void {
        Vec3f rayOrigin = new Vec3f(this.focalX, 500.0, this.focalZ);
        Vec3f rayDir = new Vec3f(0.0, -1.0, 0.0);
        RaycastHit hit = Physics::raycastHit(rayOrigin, rayDir, 1000.0, "Static");
        if (hit.hit) {
            this.lastTerrainY = hit.point.y;
        }

        float currentHeight = this.minHeight + (this.maxHeight - this.minHeight) * this.zoomLevel;

        Vec3f camPos = new Vec3f(this.focalX, this.lastTerrainY + currentHeight, this.focalZ);
        Camera::setPosition(this.selfId, camPos);
        Camera::setRotation(this.selfId, new Vec3f(this.pitch, this.yaw, 0.0));
    }
}
