# Performance Optimization (VertexForge / mType)

Target: **≤16 ms/frame (60 FPS)**. Profile first, then fix the measured
bottleneck — don't guess.

## Profile first

VertexForge ships in-editor profilers; use them before optimizing:

- **StatusBar FPS** — viewport-only frame rate (excludes editor ImGui draw) plus
  a **total draw-call** readout with a per-category breakdown tooltip.
- **Task Graph Profiler** — CPU task timings; the per-frame work breakdown and
  draw-call-by-category tab live here.
- **Render Graph Profiler** — per-GPU-pass timings.
- **GPU Memory** diagnostics window — VRAM usage, fragmentation map, peaks.

Read the measured frame time and the dominant cost (CPU task vs. GPU pass vs.
draw calls) and attack that. A healthy editor CPU frame is sub-millisecond; if
script work dominates, the hot path is usually in `onUpdate`/`tick`.

## Script hot-path rules

These are the highest-leverage script-side wins:

1. **Cache handles in `onStart`, never in `onUpdate`.**
   ```mtype
   public function onStart(): void {
       this.selfId   = Entity::self();
       this.targetId = Entity::findByName("Player");   // once
   }
   ```
   Never call `Entity::findByName` / `findAll` per frame — it's a scan.

2. **No allocations in hot paths.** Avoid `new` inside `onUpdate`/`tick` and
   tight loops. Reuse arrays/objects; prefer `distanceSquared` over `distance`.

3. **Frame-independent movement** — always scale by the `deltaTime` argument:
   `pos.add(dir.multiply(speed * deltaTime))`.

4. **Throttle expensive logic.** Not everything needs to run every frame.
   Run scans/AI decisions on an accumulator, and lean on the BT tick rate for AI
   rather than `onUpdate`.
   ```mtype
   private float acc;
   public function onUpdate(float deltaTime): void {
       this.acc = this.acc + deltaTime;
       if (this.acc < 0.25) { return; }     // 4 Hz
       this.acc = 0.0;
       this.runExpensiveScan();
   }
   ```

5. **Pool, don't churn.** Pre-instantiate inactive entities and toggle
   `Entity::setActive`; never create/destroy per frame (see `ecs-patterns.md`).

6. **Watch the continue/narrowing gotcha** — `if (x == null) { continue; }`
   doesn't narrow; an unguarded deref later can throw in the hot loop.

## Rendering / draw calls

- Watch the **total draw-call** count and its category breakdown. Spikes in a
  category point at the system to optimize (UI batching, decals, particles, ...).
- Use the engine's **LOD** and **world-sector streaming** for large worlds rather
  than keeping everything resident.
- Keep VFX bounded — prefer pooled/`spawnAt` instances over unbounded emission.
- Use async/streamed loading (`Scene::loadAsync`, streaming primitives) so asset
  loads don't stall the frame.

## Physics

- Use `applyImpulse` for instantaneous changes and `applyForce` for continuous —
  don't fight the integrator by teleporting via `setPosition` every frame on a
  dynamic body.
- Set sensible **collision layers** (`Physics::setCollisionLayer`) to cut
  broadphase pair count.
- Build runtime bodies once (`Physics::createBody`); only `rebuildBody` when the
  collider shape actually changes.

## Memory / GPU

- The engine has a memory-budget system (pressure-accelerated release;
  referenced resources are immune). Don't hold strong refs to assets you no
  longer need.
- Watch the GPU memory bar and fragmentation map for leaks/spikes during play.

## Validation checkpoint

Before declaring a feature done:
1. Build Scripts (no mType diagnostics).
2. Play-test under representative load (max units/projectiles/VFX).
3. Confirm StatusBar FPS holds ≥60 and no draw-call category is runaway.
4. If a regression appears, bisect with the diagnose loop — reproduce, isolate
   the offending system via the profiler, fix, re-measure.
