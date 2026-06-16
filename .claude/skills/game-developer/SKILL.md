---
name: game-developer
description: "Use when building game systems in the VertexForge engine with mType scripting, implementing gameplay features, or optimizing game performance. Invoke to write @Script game scripts, implement entity/component logic, configure physics and colliders, drive AI with behavior trees and the navmesh, build runtime UI, optimize frame rates to 60+ FPS targets, or apply game design patterns such as object pooling and state machines. Trigger keywords: VertexForge, mType, game development, game script, entity component, game physics, behavior tree, navmesh, game optimization, game AI, runtime UI."
license: MIT
metadata:
  author: https://github.com/Jeffallan
  version: "2.0.0"
  domain: specialized
  triggers: VertexForge, mType, game development, game script, entity component, game physics, behavior tree, navmesh, game optimization, game AI, runtime UI, object pooling, state machine
  role: specialist
  scope: implementation
  output-format: code
  related-skills:
---

# Game Developer (VertexForge / mType)

This skill targets the **VertexForge** engine and its **mType** scripting language (`.mt`).
Gameplay logic lives in mType scripts; engine systems (rendering, physics, audio,
navmesh, UI) are exposed to scripts through static native wrapper classes
(`Entity::`, `Physics::`, `Navmesh::`, `UI::`, `Input::`, `VFX::`, ...).

> **Engine boundary:** game logic belongs in mType scripts and plugins, never in
> engine core C++. The engine proves the API; the game uses it. If a needed native
> is missing, that is an engine/plugin change (SDK/ABI) — flag it rather than
> hacking around it in script.

## Core Workflow

1. **Analyze requirements** — Identify genre, mechanics, what entities/components and scripts are needed, performance targets.
2. **Design architecture** — Decide which behavior is a `@Script` component, which state lives on the entity vs. a blackboard, and how scripts communicate.
3. **Implement** — Write `@Script` classes with `onStart`/`onUpdate`/`onDestroy`, BT `tick()` tasks for AI, drive movement via Physics/Navmesh, build UI via `UI::` natives.
4. **Optimize** — Profile and optimize for 60+ FPS, avoid per-frame allocations and lookups.
   - ✅ **Validation checkpoint:** Use the editor profiler (Task Graph / Render Graph profiler, StatusBar FPS & draw-call readouts). Verify frame time ≤16 ms (60 FPS). Resolve CPU/GPU bottlenecks iteratively.
5. **Test** — Play-test in the editor (Build Scripts → Play), validate AI/navmesh, stress-test spawn-heavy systems.
   - ✅ **Validation checkpoint:** Confirm stable frame rate under load; verify scripts compile (Build Scripts) with no mType diagnostics before shipping.

## Reference Guide

Load detailed guidance based on context:

| Topic | Reference | Load When |
|-------|-----------|-----------|
| mType language | `references/mtype-language.md` | Syntax, types, classes, control flow, gotchas |
| Script model & engine natives | `references/vertexforge-scripting.md` | `@Script` lifecycle, entity/component model, native API catalog |
| ECS & game patterns | `references/ecs-patterns.md` | Entity/script/component design, pooling, state machines, behavior trees |
| Performance | `references/performance-optimization.md` | FPS optimization, profiling, avoiding allocations/lookups |
| Networking | `references/multiplayer-networking.md` | Multiplayer via mType stdlib net, client-server, lag compensation |

## Constraints

### MUST DO
- Target 60+ FPS; profile regularly (Task Graph / Render Graph profiler, StatusBar FPS & draw calls).
- Cache `Entity::self()` and component/entity handles in `onStart`, not in `onUpdate`.
- Use object pooling for frequently spawned entities (projectiles, VFX, units) — pre-spawn inactive and toggle active.
- Use the `deltaTime` argument of `onUpdate(float deltaTime)` for frame-independent movement.
- Use **typed declarations** (`int x = 0;`), never `var`.
- Drive AI movement through `Navmesh::setDestination` and gate decisions on the `Blackboard`.
- Use `LOD`/streaming and async loading provided by the engine for large worlds.
- Put game-specific components/logic in **plugins or scripts**, not engine core.

### MUST NOT DO
- Create/destroy entities in tight loops every frame — pool instead.
- Allocate (`new ...`) inside `onUpdate`/`tick` hot paths when avoidable.
- Look up entities by name (`Entity::findByName`) every frame — resolve once and cache the id.
- Skip profiling and performance testing.
- Hardcode tunable game values in code — drive from data/config where practical.
- Rely on `if (x == null) { continue; }` to narrow a nullable in a loop (see gotcha below).
- Add gameplay logic to engine C++ core.

## mType gotchas (high-impact)

- **No `var`** — every declaration is typed: `float speed = 5.0;`.
- **String building** — convert numbers with `parsePrimitive(...)` before `+`: `"t=" + parsePrimitive(totalTime)`.
- **Continue/break narrowing** — `if (x == null) { continue; }` does **not** narrow `x` afterward (only `return` narrows). Use `x?.method()` or `if (x != null) { ... }`.
- **For-each typing** — iterate with the concrete element type (`for (string s in list)`), not `Object`, or you lose the type.
- **Static vs instance** — engine natives are static, called with `::` (`Entity::self()`); your object methods use `.` (`pos.normalize()`).

## Output Templates

When implementing game features, provide:
1. The `@Script` class (or BT `tick()` task / plugin component) implementing the feature.
2. Supporting data (blackboard keys used, prefab/asset references, config values).
3. Performance considerations (what is cached, what is pooled, allocation in hot paths).
4. Brief explanation of architecture decisions (why a script vs. blackboard vs. plugin).

## Key Code Patterns

### Script lifecycle (mType)
```mtype
import * from "engine/Log.mt";

@Script
public class PlayerController {
    private float speed = 5.0;
    private int selfId;

    public constructor() {
        this.selfId = -1;
    }

    public function onStart(): void {
        this.selfId = Entity::self();        // cache once
        Log::info("PlayerController started");
    }

    public function onUpdate(float deltaTime): void {
        // frame-independent: scale by deltaTime, use cached handles
    }

    public function onDestroy(): void {
    }
}
```

### Object pooling (pre-spawned inactive entities)
```mtype
import * from "engine/Entity.mt";

@Script
public class ProjectilePool {
    private int[] pool;
    private int next;

    public function onStart(): void {
        this.next = 0;
        this.pool = new int[64];
        for (int i = 0; i < 64; i = i + 1) {
            int e = Entity::instantiate("assets/prefabs/Bullet.vfPrefab");
            Entity::setActive(e, false);     // park it, never destroy
            this.pool[i] = e;
        }
    }

    // Reuse instead of create/destroy in hot paths
    public function fire(Vec3f from, Vec3f dir): void {
        int e = this.pool[this.next];
        this.next = (this.next + 1) % 64;
        Entity::setPosition(e, from);
        Entity::setActive(e, true);
        Physics::setLinearVelocity(e, dir.multiply(40.0));
    }
}
```

### State machine (if/else dispatch — matches real AI scripts)
```mtype
@Script
public class EnemyBrain {
    private string state;
    private int selfId;

    public constructor() { this.state = "idle"; }

    public function onStart(): void {
        this.selfId = Entity::self();
    }

    public function onUpdate(float deltaTime): void {
        if (this.state == "idle") {
            if (this.seesTarget()) { this.enter("chase"); }
        } else if (this.state == "chase") {
            if (this.inRange()) { this.enter("attack"); }
        } else if (this.state == "attack") {
            if (!this.inRange()) { this.enter("chase"); }
        }
    }

    private function enter(string next): void {
        // exit-old / enter-new side effects go here
        this.state = next;
    }

    private function seesTarget(): bool { return false; }
    private function inRange(): bool { return false; }
}
```

### Behavior-tree task (AI via `tick()` returning a status string)
```mtype
import * from "engine/Entity.mt";
import * from "engine/Navmesh.mt";
import * from "engine/Blackboard.mt";

@Script
public class ChaseTarget {
    private int selfId;

    public function onStart(): void { this.selfId = Entity::self(); }

    // "running" | "success" | "failure" drives the tree
    public function tick(float deltaTime): string {
        int enemyId = Blackboard::getInt(this.selfId, "enemyId");
        if (enemyId < 0 || !Entity::isValid(enemyId)) { return "failure"; }
        Navmesh::setDestination(this.selfId, Entity::getPosition(enemyId));
        return "running";
    }

    public function onAbort(): void { Navmesh::stopAgent(this.selfId); }
}
```

For the full native API catalog (`Entity::`, `Physics::`, `Navmesh::`, `UI::`,
`Input::`, `VFX::`, `Blackboard::`, `Coroutine::`, ...) see
`references/vertexforge-scripting.md`.
