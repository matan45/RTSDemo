# VertexForge Graphics — Reference

Detail backing [SKILL.md](SKILL.md). For GLSL authoring specifically see [SHADERS.md](SHADERS.md).
Paths are relative to repo root `C:\matan\VertexForge`.

## Core file index (`VFEngine/graphics/core/`)

| File | Role |
|------|------|
| `Device.hpp/cpp` | Instance/physical/logical device; queues (present, graphics+compute, transfer, async-compute); mesh-shader & ray-query capability queries; queue-submit mutexes; pipeline-cache load/save. Validation setup + `debugCallback` + **intentional VUID suppressions** live in `Device.cpp`. |
| `SwapChain.hpp/cpp` | Swapchain images/views, depth attachment, present mode, per-frame MSAA sample count, render-extent override (upscaling). |
| `VulkanContext.hpp/cpp` | Static global accessor for Device/SwapChain; lifecycle `init()`/teardown; sets the global pipeline cache once. |
| `CommandPool.hpp` | Per-frame primary command buffers (one per swapchain image). |
| `ThreadCommandPoolManager.hpp` | Per-thread secondary pools for parallel pass recording; sized by swapchain image count. |
| `FrameSynchronizer.hpp` | Main↔render-thread handoff via condition variables. |
| `RenderThread.hpp` | Dedicated record/submit loop thread. |
| `AsyncComputeManager.hpp` | Async-compute queue + timeline semaphore; reads **previous-frame** data with no GPU waits; graphics waits before fragment shading. |
| `DeferredDeletionQueue.hpp` | Frees GPU resources **3 frames** after request (buffers/images/views/samplers/pools/lambdas). |
| `VulkanMemoryManager.hpp` | Allocator: per-type blocks, FreeList heap, `bufferImageGranularity` handling, `reclaimEmptyBlocks()`, optional `VK_EXT_memory_budget`. |
| `BufferUtilities.hpp` / `ImageUtilities.hpp` | Buffer/image creation + staging copies. |
| `MappedMemoryGuard.hpp` | RAII map/unmap. |
| `PerFrameBuffer.hpp` | Double-buffered (`MAX_FRAMES_IN_FLIGHT=2`) host-visible dynamic buffers. |
| `Shader.hpp/cpp` | Runtime GLSL→SPIR-V (shaderc), `#type`/`#include`, macro permutations, `.vfshader` precompiled load. |
| `PipelineUtilities.hpp` | `createGraphicsPipeline`, `createMeshShaderPipeline`, `createComputePipeline`, `createWireframePipeline`, UpdateAfterBind layout/pool helpers; global pipeline cache. |
| `DynamicRenderingHelpers.hpp` | `VkRenderingAttachmentInfo` factories + sync2 (`pipelineBarrier2KHR`) layout transitions. |
| `GraphicsConstants.hpp` | `MAX_FRAMES_IN_FLIGHT`, `MAX_SWAPCHAIN_IMAGES`, etc. `BindlessConstants.hpp` holds `MAX_BINDLESS_TEXTURES`. |

Render graph (`render/graph/`): `RenderGraph.hpp` (declare/compile/execute), `RenderGraphTypes.hpp`
(`ResourceHandle`, `ResourceUsage`, usage→stage/access/layout mapping), `RenderGraphPass.hpp`,
`ResourceTracker.hpp`, `BarrierBatcher.hpp`, `TransientResourcePool.hpp`, `RenderGraphProfiler.hpp`.

Frame orchestrator: `render/RenderPassHandler.hpp`.

## Descriptor-set conventions

See [SHADERS.md](SHADERS.md) for the full table. Summary: set 0 camera, 1 per-draw, 3 meshlets,
4 vertices, 5 bones (from `resources/shaders/gpudriven/mesh_shader_gpudriven.glsl`); higher sets
feature-specific (world mask 11/14, RT shadow 13, RT spot 15, RT point 16, bindless via
`BindlessTextureManager.hpp`). **Verify against the actual bound shader** — these are conventions,
not guarantees.

## Render-pass inventory (approximate — glob the subdir to confirm file names)

Under `VFEngine/graphics/render/`:

| Subsystem | Purpose |
|-----------|---------|
| `gpudriven/` | GPU-driven rendering, mesh shaders, culling, scene/bindless |
| `mesh/` | `StaticMeshPipeline`, `SkinnedMeshPipeline` |
| `shadow/` | Cascaded / VSM clipmap shadows |
| `raytracing/` | RT shadows + denoiser (point/spot overrides over VSM) |
| `gi/` | Probe tracing, SSGI |
| `lighting/` | Clustered light culling, cluster grid |
| `occlusion/` (depthprepass, hiz) | Depth prepass, Hi-Z, occlusion culling |
| `postprocess/` | Bloom, DOF, tone-map, color grading, TAA |
| `upscaling/` | DLSS / FSR / Streamline, reactive mask |
| `atmosphere/`, `cloud/` | Sky / aerial perspective, volumetric clouds |
| `volumetric/` | Volumetric fog |
| `ssr/` | Screen-space reflections |
| `water/` | Ocean FFT, water sim |
| `transparency/` | WBOIT order-independent transparency |
| `vfx/` | Particles, ribbons, distortion |
| `decal/` | Deferred decals |
| `billboard/` | Billboards, impostors |
| `vegetation/` | Grass / vegetation mesh shaders |
| `ibl/` | BRDF LUT, irradiance, prefiltered env |
| `ui/`, `text/` | UI + text rendering |
| `preview/` | Material/mesh preview rendering |
| `custom/` | Plugin custom pipelines (`CustomPipelineManager`) |
| `material/` | Material shader cache, texture cache |

## Gotchas (full)

1. **Shader runtime copy.** Editor runs from `bin/Editor/Debug/x64/` and resolves shaders to
   `bin/Editor/resources/shaders/`, *not* the source tree. Premake postbuild copies DLLs but does
   **not** sync the resources tree. Edit source → run `scripts/sync-shaders.*` → relaunch.
   Diagnostic: force a fragment to `vec4(1,0,1,1)`; if not purple, you edited the wrong copy.
2. **Frames-in-flight vs swapchain images.** `MAX_FRAMES_IN_FLIGHT = 2` (CPU submits ahead) is a
   different axis from `MAX_SWAPCHAIN_IMAGES`. Per-swapchain-image resources (e.g. thread-pool
   secondaries) are indexed by `imageIndex`, never by frame index — aliasing them causes
   use-after-GPU-submission corruption.
3. **Synchronization2 everywhere.** Barriers go through `vk::ImageMemoryBarrier2` /
   `pipelineBarrier2KHR` via `BarrierBatcher`. The RenderGraph plans them from declared
   `ResourceUsage`; if you record passes manually, you own the barriers.
4. **Descriptor pool reset invalidates sets.** After `descriptorPool.reset()` every set allocated
   from it is dead — reallocate before binding. Pattern seen in cloud/atmosphere param rebuilds.
5. **Bindless needs UpdateAfterBind.** Updating a descriptor that's in use (per-frame texture table)
   requires the layout/pool created via `PipelineUtilities::createUpdateAfterBind{Layout,Pool}`.
   Slot 0 in `BindlessTextureManager` is the default/error texture; a free list reuses slots.
6. **Streamline VUID suppressions are intentional.** `Device.cpp`'s `debugCallback` filters known
   Streamline (DLSS/Reflex) artifacts — SRGB-storage usage, layout-transition, descriptor-binding,
   buffer-device-address/1.2-core, and `sl.*` object-tracking messages. These are wrapped-handle
   noise; do not "fix" the suppressions or chase those VUIDs.
7. **Async compute reads previous-frame data.** `AsyncComputeManager` deliberately consumes last
   frame's light/cluster/terrain/TLAS buffers so the async queue never waits on graphics. Don't
   make it read current-frame results.
8. **Deferred deletion.** Free GPU resources through `DeferredDeletionQueue` (3-frame delay), not
   immediately — an in-flight frame may still reference them.
9. **Re-run premake after engine-header edits.** `premake5 vs2022` refreshes the exported `sdk/`;
   plugins compile against `sdk/`, so rebuild order is premake → engine → plugins.

## Validation

`VF_ENABLE_VALIDATION` (premake) enables `VK_LAYER_KHRONOS_validation` in **Debug and Development**
(Development keeps it on by user preference). `Device.cpp::debugCallback` routes messages to
`vfLogWarning` / `vfLogError` / `vfLogInfo`, which print to the Editor console (Editor stays a
ConsoleApp in all configs). Release ships no validation.

## Project memory

Detailed per-feature history (RT shadows, DLSS/FSR upscaling, VFX, water, performance passes,
draw-call instrumentation, plugin graphics APIs) lives in the project's auto-memory index
`MEMORY.md` (sections: Performance, Upscaling, RT Shadows, VFX, Engine UI, Plugin System).
Consult it before re-investigating a subsystem — prior fixes and their root causes are recorded there.
