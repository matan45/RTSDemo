# Entity/Script/Component Architecture & Game Patterns (mType)

VertexForge is EnTT-based under the hood, but from script you work with **entity
ids** (`int`) and **`@Script` behavioral components**. This file covers how to
structure gameplay and the classic game patterns in mType.

## Entity / component / script split

- **Entity** — an `int` handle. Created/destroyed via `Entity::create` /
  `Entity::instantiate` / `Entity::destroy`.
- **Engine components** — data the engine owns (Mesh, Collider, AudioSource,
  NavmeshAgent, UI*, ...). Query/toggle with `Entity::hasComponent` /
  `addComponent` / `removeComponent`.
- **Scripts** — `@Script` classes attached to an entity; this is where *behavior*
  lives. Keep a script focused on one responsibility (movement, health, AI).
- **Plugin components** — game-specific *data* components are registered by
  plugins, not added to engine core.

### Data-oriented mindset
Even though logic sits in scripts, keep per-frame work tight: cache ids in
`onStart`, read/write through natives, avoid allocations in `onUpdate`.

```mtype
@Script
public class Health {
    private int selfId;
    private float current;
    private float max;

    public constructor() { this.current = 100.0; this.max = 100.0; }
    public function onStart(): void { this.selfId = Entity::self(); }

    public function damage(float amount): void {
        this.current = this.current - amount;
        if (this.current <= 0.0) { this.onDeath(); }
    }
    public function heal(float amount): void {
        this.current = this.min(this.current + amount, this.max);
    }
    private function onDeath(): void { Entity::setActive(this.selfId, false); }
    private function min(float a, float b): float { return a < b ? a : b; }
}
```

## Object pooling

Spawning/destroying entities every frame is the #1 hitch source. Pre-instantiate
inactive entities and recycle them.

```mtype
import * from "engine/Entity.mt";
import * from "engine/Physics.mt";
import * from "math/Vec3f.mt";

@Script
public class BulletPool {
    private int[] pool;
    private int capacity;
    private int cursor;

    public constructor() { this.capacity = 128; this.cursor = 0; }

    public function onStart(): void {
        this.pool = new int[this.capacity];
        for (int i = 0; i < this.capacity; i = i + 1) {
            int e = Entity::instantiate("assets/prefabs/Bullet.vfPrefab");
            Entity::setActive(e, false);
            this.pool[i] = e;
        }
    }

    public function fire(Vec3f from, Vec3f dir, float speed): void {
        int e = this.pool[this.cursor];
        this.cursor = (this.cursor + 1) % this.capacity;   // ring buffer
        Entity::setPosition(e, from);
        Entity::setActive(e, true);
        Physics::setLinearVelocity(e, dir.normalize().multiply(speed));
    }

    public function recycle(int e): void { Entity::setActive(e, false); }

    public function onDestroy(): void {
        for (int i = 0; i < this.capacity; i = i + 1) { Entity::destroy(this.pool[i]); }
    }
}
```

A bullet script parks itself on lifetime expiry instead of destroying:
```mtype
@Script
public class Bullet {
    private int selfId;
    private float life;
    public function onStart(): void { this.selfId = Entity::self(); this.life = 3.0; }
    public function onUpdate(float deltaTime): void {
        this.life = this.life - deltaTime;
        if (this.life <= 0.0) { Entity::setActive(this.selfId, false); } // park, don't destroy
    }
}
```

## State machine

Real engine AI uses `if/else` dispatch on a `string` state. Keep enter/exit side
effects in one place.

```mtype
@Script
public class GuardFSM {
    private int selfId;
    private string state;

    public constructor() { this.state = "patrol"; }
    public function onStart(): void { this.selfId = Entity::self(); }

    public function onUpdate(float deltaTime): void {
        if (this.state == "patrol") {
            if (this.canSeePlayer()) { this.transition("chase"); }
        } else if (this.state == "chase") {
            if (this.inAttackRange()) { this.transition("attack"); }
            else if (!this.canSeePlayer()) { this.transition("patrol"); }
        } else if (this.state == "attack") {
            if (!this.inAttackRange()) { this.transition("chase"); }
        }
    }

    private function transition(string next): void {
        // exit current
        if (this.state == "chase") { Navmesh::stopAgent(this.selfId); }
        // enter next
        this.state = next;
    }

    private function canSeePlayer(): bool { return false; }
    private function inAttackRange(): bool { return false; }
}
```

## Behavior trees (the AI workhorse)

For non-trivial AI, prefer the engine's behavior-tree system over a hand-rolled
FSM. A BT task is a `@Script` with `tick()` returning a status string; shared
state flows through the `Blackboard`. Reactive conditions + observer aborts let
high-priority branches interrupt running tasks.

```mtype
import * from "engine/Entity.mt";
import * from "engine/Blackboard.mt";
import * from "math/Vec3f.mt";

@Script
public class FindNearestEnemy {
    private int selfId;
    public function onStart(): void { this.selfId = Entity::self(); }

    public function tick(float deltaTime): string {
        int[] enemies = Entity::findAll("Enemy");     // BT tick rate, not every render frame
        if (enemies.length == 0) { return "failure"; }

        Vec3f me = Entity::getPosition(this.selfId);
        int best = -1;
        float bestSq = 1.0e30;
        for (int i = 0; i < enemies.length; i = i + 1) {
            float d = me.distanceSquared(Entity::getPosition(enemies[i]));
            if (d < bestSq) { bestSq = d; best = enemies[i]; }
        }
        Blackboard::setInt(this.selfId, "enemyId", best);
        return "success";
    }
}
```

- **In/out contract:** document blackboard keys read/written at the top of each
  task script (the real engine scripts do this).
- **`onAbort()`** — stop in-flight work (e.g. `Navmesh::stopAgent`) when a
  higher-priority branch preempts the node.

## Spatial / nearest-target queries

Pull positions through natives and compare **squared** distances
(`distanceSquared`) to skip the `sqrt`. For dense queries call
`Entity::findWithComponent` once per tick and cache, or use the engine's `EQS`
environment-query system (`engine/EQS.mt`).

## Component communication

- **Direct:** `Entity::getScript<T>(id, "ClassName")` then call methods.
- **Blackboard:** decouple AI tasks via shared keys.
- **Messages:** `Entity::sendMessage` / `broadcastMessage` with a `ScriptCallback`.
- **Events:** implement listener interfaces (`ICollisionListener`,
  `IInputActionListener`, scene/animation/UI listeners) for engine-driven events.

## Anti-patterns

- Creating/destroying entities in loops → pool.
- `Entity::findByName` in `onUpdate` → resolve once in `onStart`, cache the id.
- One mega-script doing movement + AI + UI → split by responsibility.
- Allocating `new Vec3f(...)` repeatedly in hot loops → reuse where the API allows.
- Putting game-specific data components in engine core → use plugins.
