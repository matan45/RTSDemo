---
name: performance-optimization
description: Optimizes VertexForge engine runtime performance against the frame budget — CPU frame time, GPU frame time, draw calls, GPU memory, and asset streaming. Use when FPS drops below target, frames stutter/hitch, the CPU or GPU frame budget is blown, VRAM pressure appears, draw-call counts are high, or asset loading stalls — or when in-engine profiling reveals a bottleneck to fix.
---

# Performance Optimization (VertexForge)

## Overview

Measure before optimizing. Performance work without measurement is guessing — and in a game engine, guessing leads to premature micro-optimizations that add complexity and hurt cache behavior or instruction count without moving the frame time that actually matters. Profile first, identify whether you are CPU-bound, GPU-bound, memory-bound, or stalling on streaming, fix that one thing, then measure again. Optimize only what the profilers prove matters.

This engine ships its own in-editor profilers — use them. You almost never need to add `printf` timing.

## When to Use

- A frame-budget target exists (e.g. 60 FPS play-test) and the build misses it.
- FPS drops, or frames **stutter / hitch** (a spike on the max, not the average).
- You suspect a regression after a render-graph, ECS, terrain, or job-system change.
- Scene complexity is scaling (entity counts, draw calls, terrain LOD, VFX) and you need headroom.
- VRAM pressure, allocation failures, or eviction churn appears.

**When NOT to use:** Don't optimize before a profiler shows a problem. Premature optimization adds complexity that costs more than the time it saves.

## When NOT to Use / See Instead

This skill owns **measure-first triage** across subsystems. Once a capture pins the bottleneck to one domain, hand off:

- **GPU-internal work** (shader cost, pipeline state, descriptor/barrier overhead, render-pass restructuring) → `vulkan-graphics-dev`.
- **mType / gameplay-script perf** (script hot loops, entity/component update cost, object pooling, AI/navmesh budget) → `game-developer`.
- **C++-language-level optimization** (SIMD, memory layout, allocator choice, template/constexpr cost, build config) → `cpp-pro`.
- **Root-causing a "was fast, now slow" regression** (bisect → fix → regression-test) → `diagnose`.

Use *this* skill to measure first and decide which of the above owns the fix, and for cross-subsystem frame-budget work that doesn't belong to a single specialist.

## Frame Budget Targets

| Target | Total frame budget | Notes |
|--------|-------------------|-------|
| **60 FPS** (default play-test) | **16.67 ms** | CPU frame *and* GPU frame must each fit under this — they overlap, so the slower of the two gates you. |
| **30 FPS** (heavy-scene floor) | **33.3 ms** | Acceptable for stress scenes only; sustained sub-30 is a bug. |
| **120 FPS** (high-refresh) | **8.33 ms** | Stretch target; almost always GPU-bound here. |

| Sub-budget (rule of thumb, 60 FPS) | Reasonable share |
|------------------------------------|------------------|
| CPU **viewport** frame (`viewportFrameDurationNs()`, editor cost excluded) | ≤ ~10–12 ms, leaving slack for spikes |
| GPU frame (sum of `RenderGraphProfiler` passes) | ≤ ~14 ms |
| Single job-system task (`TaskProfiler`) | no task should dominate; watch the **max**, not the avg (hitches live there) |
| Editor / ImGui overhead (`EditorTaskStats`) | tracked separately — **must not** count against FPS judgement |

| Resource guardrail | Reasonable headroom |
|--------------------|---------------------|
| VRAM peak vs `VK_EXT_memory_budget` (`GpuAllocationStats`) | ≤ ~80% of budget; alloc failures / eviction = over budget |
| Fragmentation (`GpuMemorySnapshot`) | watch the largest free span shrink; `reclaimEmptyBlocks` when blocks go empty |
| Draw calls / frame (`FrameDrawStats`, 12 categories) | no hard number — a **category trending up** order-of-magnitude = missing batching/instancing |
| Staging ring (`GpuAllocationStats`) | should reach a steady-state size, not grow every frame |

> These are starting heuristics for a custom engine, **not** hardware specs. The real budget is the slowest target machine at the target resolution. Always profile in the **Development** config (O2 + symbols, validation on) on representative hardware — Debug numbers are meaningless, and confirm hot paths in Release.

## The Optimization Workflow

```
1. MEASURE  → Establish baseline with the in-engine profilers
2. IDENTIFY → Find the actual bottleneck (CPU / GPU / memory / streaming)
3. FIX      → Address the specific bottleneck
4. VERIFY   → Measure again, confirm improvement
5. GUARD    → Add a test or keep watching the relevant profiler readout
```

### Step 1: Measure

In-engine instrumentation (open from the editor `MainMenuBar`):

- **`StatusBar`** — always-on triage glance: viewport FPS (VSync-aware, editor cost already excluded), total + per-category draw calls, VRAM MB. **Start here.**
- **`TaskGraphWindow`** (tabs: **Timeline / Statistics / DAG / Draw Calls / GPU Passes / Loading**) — CPU task durations (`TaskProfiler`, 120-frame ring, min/avg/max), per-category draw calls (`FrameDrawStats`), per-pass GPU timings (`RenderGraphProfiler` via the request-driven `GpuPassStats` sink — toggle it on), and async asset loads (`ResourceLoadScheduler`).
- **`MemoryDiagnosticsWindow`** — VRAM budget bar, per-block fragmentation map, time-series, staging ring, leak watermarks, CSV export.
- **`CullingStatsWindow`** — `CullingDebugStats`: frustum/occlusion/distance/LOD visible-vs-culled, terrain tile + meshlet culling, streaming metrics.

External GPU tools (RenderDoc / Nsight / PIX) are the "synthetic capture" analog when you need per-draw / per-shader GPU detail beyond what `RenderGraphProfiler` exposes.

### Where to Start Measuring

**StatusBar first** (is it even slow, and CPU- or GPU-bound?) → the matching `TaskGraphWindow` tab → the specialized window.

```
Frame is slow / hitching — read the StatusBar (FPS, draw calls, VRAM).
│
├── CPU-BOUND  (viewportFrameDurationNs high; GPU passes show idle gaps)
│   └── TaskGraphWindow → Timeline / Statistics
│       ├── One task dominates the avg?   --> parallelize: parallelFor / split task (JobPriority)
│       ├── One task spikes on max only?  --> hitch: per-frame alloc, lock, or sync load
│       └── Main thread doing gather/cull/render work? --> move it onto the enkiTS job system
│
├── GPU-BOUND  (GPU frame > CPU frame; CPU waits on present)
│   └── TaskGraphWindow → GPU Passes (toggle the GpuPassStats sink on)
│       ├── One pass dominates?           --> optimize that pass (→ vulkan-graphics-dev)
│       ├── High barrier counts?          --> render-graph dependency / layout churn
│       └── Too many draws?               --> Draw Calls tab, then CullingStatsWindow
│
├── CULLING / OVERDRAW  (draw calls high for the visible scene)
│   └── CullingStatsWindow (CullingDebugStats)
│       ├── visible ≈ total?              --> GPU-driven culling not engaging / disabled
│       ├── LOD not dropping at range?    --> terrain / mesh LOD thresholds
│       └── meshlet cull ineffective?     --> mesh-shader cluster culling path
│
├── MEMORY-BOUND  (VRAM near budget; stutter on alloc; eviction)
│   └── MemoryDiagnosticsWindow
│       ├── budget bar near full?         --> reduce residency (GpuAllocationStats peak watermark)
│       ├── fragmentation map holey?      --> reclaimEmptyBlocks (GpuMemorySnapshot free spans)
│       ├── staging ring growing?         --> unbounded upload; bound / recycle staging
│       └── leak watermark climbing?      --> CSV export, diff over time
│
└── LOADING / STREAMING STALL  (hitch when an asset appears, not steady-state)
    └── TaskGraphWindow → Loading (ResourceLoadScheduler: queue-wait / run / progress)
        ├── long queue-wait?              --> raise priority (Critical bypasses the concurrency cap)
        ├── load runs on main thread?     --> must be async via ResourceLoadScheduler
        └── many small loads?             --> batch / coalesce requests
```

### Step 2: Identify the Bottleneck

**CPU frame:**

| Symptom | Likely Cause | Investigation |
|---------|-------------|---------------|
| High avg on one task | Serial work that could parallelize | TaskGraphWindow Statistics; dispatch via `parallelFor` |
| Spike on max, low avg | Per-frame heap alloc, lock contention, sync load | Timeline tab — correlate spike frame |
| Whole frame high, no single task | Main-thread work that belongs on the job system | Move gather/cull onto enkiTS `TaskGraph` |

**GPU frame:**

| Symptom | Likely Cause | Investigation |
|---------|-------------|---------------|
| One pass dominates | Expensive shader / bandwidth | GPU Passes tab → `vulkan-graphics-dev` |
| High barrier counts | Layout churn / poor render-graph deps | RenderGraphProfiler barrier counters |
| Draw category exploded | Missing batching / instancing | Draw Calls tab + CullingStatsWindow |
| `visible ≈ total` | GPU culling not engaging | CullingDebugStats frustum/occlusion ratio |

**Memory / streaming:**

| Symptom | Likely Cause | Investigation |
|---------|-------------|---------------|
| VRAM near budget, eviction | Over-residency, no budget pressure | MemoryDiagnosticsWindow budget bar + watermark |
| Fragmentation grows | Empty blocks never reclaimed | Fragmentation map; `reclaimEmptyBlocks` |
| Hitch on asset appear | Synchronous load on main thread | Loading tab — move to async scheduler |

### Step 3: Fix Common Anti-Patterns

#### Per-frame heap allocation on the render/update path

```cpp
// BAD: fresh allocation every frame — shows up as a max-but-not-avg spike in TaskProfiler
void buildDrawList() {
    std::vector<DrawItem> items;            // allocates + frees every frame
    for (auto e : view) items.push_back(makeItem(e));
}

// GOOD: persistent scratch buffer, reserved once, cleared and refilled
std::vector<DrawItem> scratch;              // member, reserved at init
void buildDrawList() {
    scratch.clear();                        // keeps capacity
    for (auto e : view) scratch.push_back(makeItem(e));
}
```

#### Draw-call explosion / missing batching

```cpp
// BAD: one draw per mesh — a FrameDrawStats category climbs with entity count
for (auto e : meshes) drawSingle(e);

// GOOD: instanced/indirect draws, batched by material/pipeline; let GPU-driven
// culling build the draw list. Watch the per-category count in the StatusBar.
```

#### Redundant pipeline / descriptor binds

```cpp
// BAD: bind pipeline + descriptors on every draw regardless of state
// GOOD: sort draws by pipeline/material, bind only on change; order render-graph
// passes to minimize state churn (watch barrier counts in RenderGraphProfiler).
```

#### Main-thread work that belongs on the job system

```cpp
// BAD: animation gather / culling / navmesh built serially on the main thread
for (auto e : skinned) gatherPose(e);

// GOOD: dispatch via enkiTS parallelFor with an appropriate JobPriority; confirm
// the task left the critical path in the Timeline tab.
parallelFor(skinned.size(), [&](size_t i){ gatherPose(skinned[i]); }, JobPriority::High);
```

#### Missing / disabled GPU culling

```
// BAD: CPU submits everything; CullingDebugStats shows visible ≈ total.
// GOOD: frustum + occlusion + distance/LOD culling engaged; verify the
// visible-vs-culled ratio in CullingStatsWindow.
```

#### Over-tessellated / non-dropping terrain & mesh LOD

```
// BAD: full-res terrain tiles / meshlets at distance; LOD thresholds never trip.
// GOOD: distance-based tile + meshlet culling; LOD reduces triangle load at range.
```

#### Synchronous asset loads on the main thread

```cpp
// BAD: load inline during update → frame hitch
auto mesh = loadMeshBlocking(path);

// GOOD: async via ResourceLoadScheduler; Critical priority for must-have-now assets
// (bypasses the concurrency cap). Observe in the Loading tab.
```

#### Unbounded staging ring / upload churn

```
// BAD: staging buffer grows every frame, never recycled.
// GOOD: bounded, recycled staging; steady-state size in GpuAllocationStats; coalesce uploads.
```

#### Cache-unfriendly ECS iteration / copies instead of moves

```cpp
// BAD: random component lookups by entity inside a loop; passing heavy aggregates by value
for (auto e : entities) { auto c = registry.get<Heavy>(e); process(c); }   // copy + pointer chase

// GOOD: iterate one tight EnTT view/group over packed arrays; take const& / std::span; std::move
registry.view<Heavy>().each([](const Heavy& c){ process(c); });
```

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "We'll optimize later" | Perf debt compounds. Fix obvious anti-patterns now (per-frame allocs, missing batching); defer micro-opts. |
| "It's fast on my GPU" | Your GPU isn't the target's. Profile on representative hardware at target resolution. |
| "This optimization is obvious" | If you didn't capture it, you don't know. Profile first. |
| "Players won't notice one hitch" | A single 33 ms spike is a visible stutter. Watch the **max**, not just the average. |
| "The render graph handles it" | The graph orders passes, but it can't fix a per-draw bind storm, missing culling, or a sync load on the main thread. |

## Red Flags

- Optimizing without a profiler capture to justify it.
- Heap allocation on the per-frame render/update path.
- A `FrameDrawStats` category climbing with entity count (no instancing/batching).
- Synchronous asset loads inside the update loop.
- VRAM near budget with no eviction / residency strategy.
- Gather/cull/animation work running serially on the main thread.
- Trusting numbers measured in the **Debug** config.

## Verification

After any performance-related change:

- [ ] Before/after numbers captured from `StatusBar` + `TaskGraphWindow` (specific ms / FPS / draw counts).
- [ ] Bottleneck classified — CPU vs GPU vs memory vs streaming — and the *specific* one addressed.
- [ ] Both CPU and GPU frame within the target budget.
- [ ] VRAM peak within headroom; no new fragmentation or staging-ring growth.
- [ ] No per-frame heap allocation added to the render path.
- [ ] Measured in the **Development** config on representative hardware.
- [ ] doctest CPU suite still passes (`bin/Tests/<Config>/x64/Tests.exe`). Note: there are no built-in perf benchmarks, so frame-time verification is **manual, in-engine**.
