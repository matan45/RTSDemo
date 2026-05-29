// PickerProbe - VK-1301 verification probe.
//
// On each left-click release, prints what the runtime picker resolves under the
// cursor: an entity (physics raycast, Dynamic layer), else a terrain point, else
// empty. Attach via a ScriptComponent on any always-present entity (e.g. the camera).
//
//   AC1 click ground -> [Pick] TERRAIN @ (x,y,z)
//   AC2 click a unit  -> [Pick] ENTITY id=N
//   AC3 click sky/off -> [Pick] EMPTY

import * from "../lib/engine/Picker.mt";
import * from "../lib/engine/Input.mt";
import * from "../lib/engine/Mouse.mt";
import * from "../lib/engine/Log.mt";
import * from "../lib/engine/RaycastHit.mt";

@Script
class PickerProbe {
    constructor() {
    }

     public function onStart(): void {
        
    }

    public function onUpdate(float deltaTime): void {
        if (!Input::isMouseButtonReleased(Mouse::LEFT)) {
            return;
        }

        float mx = Input::getViewportMouseX();
        float my = Input::getViewportMouseY();

        RaycastHit e = Picker::pickEntity(mx, my, "Dynamic");
        if (e.hit) {
            Log::info("[Pick] ENTITY id=" + e.entityId + " @ (" + e.point.x + ", " + e.point.y + ", " + e.point.z + ")");
            return;
        }

        RaycastHit t = Picker::pickTerrainPhysics(mx, my);
        if (t.hit) {
            Log::info("[Pick] TERRAIN @ (" + t.point.x + ", " + t.point.y + ", " + t.point.z + ")");
            return;
        }

        Log::info("[Pick] EMPTY (no entity, no terrain)");
    }

    public function onDestroy(): void {
        
    }
}
