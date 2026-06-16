---
name: vulkan-graphics-dev
description: Navigate and modify VertexForge's Vulkan/C++ graphics module — Device/SwapChain/RenderGraph, pipelines, descriptor-set conventions, the provider/adapter/service exposure path, shaders, and project gotchas. Use when working in VFEngine/graphics, writing/editing GLSL shaders, adding render passes or pipelines, debugging Vulkan validation errors, or exposing rendering features to the Editor.
---

# VertexForge Vulkan / C++ Graphics

Engine-specific map for rendering work. Assumes Vulkan fluency — this is about *where things
live in this codebase* and *what bites you here*. Deep detail in [REFERENCE.md](REFERENCE.md).

## Module boundary

`Graphics` is a **StaticLib** linked into `Core`. Editor/Runtime **never** include Graphics or
Core directly — they go through the Services layer (provider → adapter → service → command).
Engine-wide: `vulkan.hpp` (`vk::` types) with `VULKAN_HPP_DISPATCH_LOADER_DYNAMIC=1` dynamic
dispatch, `GLM_FORCE_DEPTH_ZERO_TO_ONE` (Vulkan [0,1] depth). No `VK_CHECK` macro — errors go
through `vfLogError` / `vfLogAssert` (spdlog).

## Quick map (`VFEngine/graphics/core/`)

| Concern | File |
|---------|------|
| Device, queues, mesh-shader/ray-query caps, pipeline cache | `Device.hpp` |
| Swapchain, depth, MSAA samples, render-extent override | `SwapChain.hpp` |
| Static global accessor / lifecycle | `VulkanContext.hpp` |
| Pipeline builders (graphics/mesh/compute, UpdateAfterBind) | `PipelineUtilities.hpp` |
| Runtime GLSL→SPIR-V (shaderc), `#type`/`#include` | `Shader.hpp` |
| GPU allocator, FreeList, memory budget | `VulkanMemoryManager.hpp` |
| 3-frame-delayed resource deletion | `DeferredDeletionQueue.hpp` |
| Dynamic rendering attachment factories, sync2 layout helpers | `DynamicRenderingHelpers.hpp` |
| `MAX_FRAMES_IN_FLIGHT=2`, `MAX_SWAPCHAIN_IMAGES`, etc. | `GraphicsConstants.hpp` |

Frame orchestration: `render/RenderPassHandler.hpp`. Async compute: `core/AsyncComputeManager.hpp`
(reads previous-frame data, no GPU waits). Main↔render-thread handoff: `core/FrameSynchronizer.hpp`.

## Render graph (`render/graph/`)

DAG-based dynamic rendering: declare passes / import or create resources → `compile()` (topo-sort
+ automatic barrier planning) → `execute(cmd, imageIndex)`. `ResourceUsage` (e.g.
`ColorAttachmentWrite`, `ShaderRead`, `StorageWrite`) maps to stage/access/layout, so **you
declare usage, not barriers**. Source of truth: `RenderGraph.hpp`, `RenderGraphTypes.hpp`;
batching in `BarrierBatcher.hpp`; temp targets in `TransientResourcePool.hpp`.

## Editing a shader (critical — read this)

Source GLSL lives in `resources/shaders/**.glsl` and is compiled at runtime via shaderc. **The
Editor reads the *copy* under `bin/Editor/resources/shaders/`, NOT the source tree** — editing
source alone has zero runtime effect. After every GLSL edit:

```
pwsh .claude/skills/vulkan-graphics-dev/scripts/sync-shaders.ps1 gpudriven/mesh_shader_gpudriven.glsl
# or, from the Bash tool:
bash .claude/skills/vulkan-graphics-dev/scripts/sync-shaders.sh gpudriven/mesh_shader_gpudriven.glsl
```

No argument mirrors the whole shader tree. `#include` paths resolve relative to the shaders root
(`ShaderIncluder` in `Shader.hpp`). Diagnostic if unsure: force `outColor = vec4(1,0,1,1)` and
relaunch — no purple means you edited the wrong copy.

**Writing GLSL** — `#type` stage split, `common/` shared structs (std430 must match C++), set/binding
conventions, macro permutations, `.vfshader` precompiled path: see [SHADERS.md](SHADERS.md).

## Add a render pass + expose to Editor

1. Pipeline in `graphics/render/<feature>/` — build via `PipelineUtilities::create{Graphics,MeshShader,Compute}Pipeline`; shader in `resources/shaders/<feature>/`.
2. Register it in the RenderGraph / `RenderPassHandler`.
3. To surface it to the Editor, follow CLAUDE.md "Exposing Graphics Functionality to Editor":
   provider interface in `services/providers/` → adapter in `core/adapters/` → service method +
   Command/Query event → register handler → wire into `EditorBootstrap`. Editor calls it via
   `EventDispatcher`, never by including Graphics.

## Build & validate

`premake5 vs2022`, then build `Graphics` / `Core` / `Editor`. **Hand the build off to the user**
(they build themselves). Validation layers are ON in Debug **and** Development
(`VF_ENABLE_VALIDATION`); messages route through `vfLog*` to the Editor console. Re-run premake
after editing engine headers before building plugins/SDK.

## Top gotchas (full detail in REFERENCE.md)

- Shader edits need the **runtime copy** (`sync-shaders`) — #1 time-waster.
- `MAX_FRAMES_IN_FLIGHT=2` ≠ swapchain image count; per-image resources are indexed by `imageIndex`.
- Barriers are **synchronization2** (`pipelineBarrier2KHR` / `BarrierBatcher`).
- Descriptor `set`/`binding` indices in C++ must match the shader exactly — silent failure otherwise.
- Streamline VUID suppressions in `Device.cpp` are **intentional**; don't "fix" them.
- `descriptorPool.reset()` invalidates all sets from it; bindless updates need UpdateAfterBind.
