# VertexForge Script Model & Engine Native API

Gameplay in VertexForge is written as **mType `@Script` classes** attached to
entities, plus **behavior-tree task scripts** for AI and **plugin components**
for engine-bridged game data. Scripts talk to the engine through static native
wrapper classes under `assets/scripts/lib/engine/`.

## The `@Script` component model

An entity is an `int` id. A script is a behavioral component attached to an
entity; an entity may carry several scripts. Each `@Script` class can implement
lifecycle hooks the engine calls:

```mtype
import * from "engine/Log.mt";
import * from "engine/Entity.mt";

@Script
public class Mover {
    private int selfId;
    private float speed;

    public constructor() { this.selfId = -1; this.speed = 4.0; }

    public function onStart(): void {           // once, when activated
        this.selfId = Entity::self();
    }

    public function onUpdate(float deltaTime): void {   // every frame
        Vec3f p = Entity::getPosition(this.selfId);
        Entity::setPosition(this.selfId, p.add(new Vec3f(this.speed * deltaTime, 0, 0)));
    }

    public function onDestroy(): void { }        // on teardown
}
```

**Lifecycle hooks:** `onStart()`, `onUpdate(float deltaTime)`, `onDestroy()`.
Behavior-tree tasks instead implement `tick(float deltaTime): string` returning
`"running" | "success" | "failure"`, plus optional `onAbort()`.

**Event listeners:** implement an interface to receive callbacks —
`ICollisionListener` (`onCollisionEnter/Exit`), `ITriggerListener`
(`onTriggerEnter/Exit`), `IInputActionListener`, `IUIButtonListener`, and the
many `IUI*Listener` / scene / animation / nav listeners under `lib/engine/`.

```mtype
@Script
public class Trap implements ITriggerListener {
    @Override public function onTriggerEnter(int other): void {
        Physics::applyImpulse(other, new Vec3f(0, 20, 0));
    }
    @Override public function onTriggerExit(int other): void { }
}
```

**Cross-script communication:**
```mtype
bool has = Entity::hasScriptOfType(id, "Mover");
Mover m  = Entity::getScript<Mover>(id, "Mover");
m.set(8.0);
```

> **Build step:** after editing scripts, run **Build Scripts** in the editor
> (compiles `.mt` → bytecode) before Play. New assets need an asset rescan.

## Native API catalog (real signatures)

All native classes are static; call with `::`. Selected, commonly-used methods —
see the wrapper files under `lib/engine/` for the complete set.

### Entity (`engine/Entity.mt`)
```mtype
int  Entity::self()                                  // this script's entity
int  Entity::findByName(string name)                 // (don't call per-frame)
int[] Entity::findAll(string name)
int[] Entity::findWithComponent(string componentType)
bool Entity::isValid(int e)        bool Entity::isActive(int e)
void Entity::setActive(int e, bool active)           // pooling on/off
string Entity::getName(int e)      void Entity::setName(int e, string n)
Vec3f Entity::getPosition(int e)   void Entity::setPosition(int e, Vec3f p)
Vec3f Entity::getRotation(int e)   void Entity::setRotation(int e, Vec3f euler)
Vec3f Entity::getScale(int e)      void Entity::setScale(int e, Vec3f s)
bool Entity::hasComponent(int e, string type)
bool Entity::addComponent(int e, string type)   bool Entity::removeComponent(int e, string type)
int  Entity::getParent(int e)      bool Entity::setParent(int e, int parent)
int[] Entity::getChildren(int e)
int  Entity::create(string name)   int Entity::createChild(string name, int parent)
void Entity::destroy(int e)
int  Entity::instantiate(string prefabPath)          // spawn .vfPrefab
int  Entity::instantiateChild(string prefabPath, int parent)
T    Entity::getScript<T>(int e, string className)
bool Entity::setMesh(int e, string meshPath)    bool Entity::setMaterial(int e, string materialPath)
```

### Physics (`engine/Physics.mt`)
```mtype
bool  Physics::hasRigidBody(int e)
Vec3f Physics::getLinearVelocity(int e)   void Physics::setLinearVelocity(int e, Vec3f v)
void  Physics::applyForce(int e, Vec3f f)            // continuous
void  Physics::applyImpulse(int e, Vec3f j)          // instant
void  Physics::applyForceAtPosition(int e, Vec3f f, Vec3f worldPos)
void  Physics::applyTorque(int e, Vec3f t)
void  Physics::setMass(int e, float m)
bool  Physics::isTrigger(int e)   void Physics::setTrigger(int e, bool t)
int   Physics::getCollisionLayer(int e)   void Physics::setCollisionLayer(int e, int layer)
// runtime body lifecycle after configuring a collider:
Physics::createBody(int e)   Physics::rebuildBody(int e)   Physics::destroyBody(int e)
```
Collision/trigger callbacks arrive via `ICollisionListener` / `ITriggerListener`.

### Navmesh / AI movement (`engine/Navmesh.mt`)
```mtype
Vec3f[] Navmesh::findPath(Vec3f start, Vec3f end)
bool    Navmesh::isPointOnNavmesh(Vec3f p)   Vec3f Navmesh::getClosestPoint(Vec3f p)
void    Navmesh::setDestination(int e, Vec3f target)   // agent steering
void    Navmesh::moveTo(int e, Vec3f target)
void    Navmesh::stopAgent(int e)
void    Navmesh::setSpeed(int e, float s)    Vec3f Navmesh::getVelocity(int e)
```

### Blackboard (behavior-tree shared state) (`engine/Blackboard.mt`)
```mtype
void Blackboard::setInt(int e, string key, int v)     int   Blackboard::getInt(int e, string key)
void Blackboard::setFloat(int e, string key, float v) float Blackboard::getFloat(int e, string key)
void Blackboard::setBool(int e, string key, bool v)   bool  Blackboard::getBool(int e, string key)
void Blackboard::setString(int e, string key, string v) string Blackboard::getString(int e, string key)
void Blackboard::setVec3(int e, string key, float x, float y, float z)
float[] Blackboard::getVec3(int e, string key)        // returns float[3]
bool Blackboard::hasKey(int e, string key)            bool Blackboard::hasBehaviorTree(int e)
void Blackboard::setEnabled(int e, bool on)           string Blackboard::getStatus(int e)
```

### Input (`engine/Input.mt`)
```mtype
bool  Input::isKeyDown(int keyCode)        bool Input::isKeyReleased(int keyCode)
bool  Input::isMouseButtonDown(int b)      bool Input::isDoubleClick(int b)
float Input::getMouseX()  Input::getMouseY()  Input::getViewportMouseX()  Input::getViewportMouseY()
float Input::getMouseDeltaX()  Input::getMouseDeltaY()
float Input::getMouseScrollDeltaY()
void  Input::setCursorVisible(bool v)
```
Key codes live in `engine/Key.mt`, mouse buttons in `engine/Mouse.mt`. Prefer
`InputAction`/`InputAxis` + `IInputActionListener` for rebindable input.

### UI (`engine/UI.mt`) — runtime UI on UI entities
```mtype
bool  UI::isButtonHovered(int e)   bool UI::isButtonPressed(int e)
bool  UI::isPointerOverUI()                          // gate world clicks
void  UI::setLabelText(int e, string text)   string UI::getLabelText(int e)
void  UI::setLabelColor(int e, float r, float g, float b, float a)
void  UI::setLabelFontSize(int e, float size)
void  UI::setImageTexture(int e, string assetPath)   void UI::setImageColor(int e, float r,float g,float b,float a)
bool  UI::setRectPixels(int e, float x, float y, float w, float h)   float[] UI::getRectPixels(int e)
bool  UI::isCheckboxChecked(int e)   int UI::getDropdownSelectedIndex(int e)
```
Button/checkbox/slider/dropdown/tabs callbacks via the matching `IUI*Listener`.

### VFX (`engine/VFX.mt`)
```mtype
void VFX::play(int e)   VFX::stop(int e)   bool VFX::isPlaying(int e)
int  VFX::spawnAt(string path, float x, float y, float z)        // fire-and-forget instance
int  VFX::spawnAtLooping(string path, float x, float y, float z)
void VFX::destroyInstance(int id)   void VFX::stopInstance(int id)
bool VFX::setOverride(int id, string name, float value)
bool VFX::setOverrideColor(int id, float r, float g, float b, float a)
```

### Audio (`engine/Audio.mt`)
```mtype
int  Audio::play2d(int e)   int Audio::play3d(int e)   void Audio::stop(int e)
void Audio::setVolume(int e, float v)   void Audio::setPitch(int e, float p)
void Audio::setBusVolume(string bus, float v)   void Audio::muteBus(string bus, bool m)
```

### Camera / Scene / Save / Material / Timer / DebugDraw
```mtype
int   Camera::getPrimary()   Vec3f Camera::getPosition(int e)   void Camera::setFOV(int e, float fov)
void  Scene::load(string path)   string Scene::loadAdditive(string path)   void Scene::unload(string name)
void  Scene::loadAsync(string path, ISceneLoadCallback cb)
void  Save::createSlot(string name)   void Save::save(string slot)   void Save::load(string slot)
bool  Material::setColor(int e, string name, float r, float g, float b, float a)
bool  Material::setScalar(int e, string name, float v)
async Timer::delay(float seconds): Promise<void>   async Timer::delayFrames(int n): Promise<void>
void  DebugDraw::line(Vec3f a, Vec3f b, Vec4f color)   DebugDraw::sphere(Vec3f c, float r, Vec4f color)
```

### Math (`math/*.mt`) — value classes
`Vec2f`, `Vec3f`, `Vec4f`, `Matrix3f`, `Matrix4f`, `Quaternion`, `Random`.
`Vec3f` methods: `add`, `subtract`, `multiply(float)`, `divide`, `dot`, `cross`,
`length`, `lengthSquared`, `normalize`, `distance`, `lerp`, `reflect`, plus
statics `Vec3f::zero()`, `Vec3f::one()`, `Vec3f::unitX()`.

## Plugin components (game data bridged into the engine)

Game-specific *components* (not just script behavior) belong in **plugins**, not
engine core. A plugin registers native components/importers and can expose mType
natives via the C ABI (`registerScriptFunction`). The engine proves the API; the
game's logic stays in mType/plugins. Changing the plugin bridge is an SDK/ABI
change that requires rebuilding all plugins.
