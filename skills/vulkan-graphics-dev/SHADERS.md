# GLSL Shader Authoring (VertexForge)

How shaders are written and compiled in this engine. Pairs with the **Editing a shader** workflow
in [SKILL.md](SKILL.md) — remember every source edit must be `sync-shaders`'d to the runtime copy
before it takes effect.

## File format

Shaders are single `.glsl` files containing one or more stages, split by a `#type` directive
parsed by `Shader::parseShaderSource` (`VFEngine/graphics/core/Shader.hpp`). A file may hold
multiple stages (e.g. vertex + fragment) separated by their `#type` headers.

```glsl
#type MESH
#version 460 core
#extension GL_EXT_mesh_shader : require
#extension GL_GOOGLE_include_directive : require

#include "../common/gpu_types.glsl"
#include "../common/camera_types.glsl"
// ... stage body ...
```

- **`#type`** values: `VERTEX`, `FRAGMENT`, `COMPUTE`, `MESH`, `TASK` (map to `resource::ShaderType`
  → `vk::ShaderStageFlagBits` in `Shader::shaderTypeToVulkanStage`).
- **`#version 460 core`** is the baseline. Add `#extension GL_GOOGLE_include_directive : require`
  whenever you use `#include`. Mesh/task stages need `GL_EXT_mesh_shader : require`.
- **`#include "../common/foo.glsl"`** resolved by `ShaderIncluder` relative to the shader's
  directory (base path = the shaders root). Shared structs/functions live in
  `resources/shaders/common/` — reuse them, don't redefine.

## `common/` library (reuse, don't duplicate)

Shared GLSL lives in `resources/shaders/common/`. Glob it for the current set; high-value ones:

| File | Provides |
|------|----------|
| `gpu_types.glsl` | `PerDrawData`, `GPUMeshlet`, instance/draw structs (std430-matched to C++) |
| `camera_types.glsl` | `CameraData` (view/proj/frustum/jitter/time) — the set 0 UBO payload |
| `gpu_instance_types.glsl` | GPU-driven instance structs |
| `lighting_functions.glsl`, `ibl_functions.glsl` | PBR / IBL evaluation |
| `shadow_sampling.glsl`, `shadow_sampling_types.glsl` | VSM / shadow lookups |
| `cluster_culling.glsl`, `culling_functions.glsl`, `hiz_occlusion.glsl` | GPU culling helpers |
| `motion_vectors.glsl` | reprojection / TAA / upscaling motion vectors |
| `gi_sampling.glsl`, `volumetric_common.glsl`, `caustic_sampling.glsl`, `wetness.glsl`, `snow_accumulation.glsl`, `lod_crossfade.glsl` | feature-specific shared math |

**Struct layout must match C++ exactly.** GPU structs use `layout(std430, ...)` buffers; the C++
mirror (often in `graphics/core` or a feature's `*GPU*` header) must have identical field order,
sizes, and `vec4` alignment/padding. A mismatched struct is silent corruption, not a compile error.

## Descriptor set conventions

Set/binding numbers in GLSL must match the C++ descriptor-set-layout binding order exactly — there
is no validation that they line up. From `gpudriven/mesh_shader_gpudriven.glsl`:

| Set | Contents |
|-----|----------|
| 0 | `CameraUBO` (frame-wide camera/frustum/time) |
| 1 | `PerDrawDataBuffer` (per-draw instance data, std430) |
| 3 | meshlet buffers: `MeshletBuffer`, `MeshletVertexBuffer`, `MeshletPrimitiveBuffer` |
| 4 | `VertexBuffer` (raw `float vertexData[]`) |
| 5 | `BoneMatrices` (skinned only) |

Higher sets are feature-specific and documented in project memory (verify against the actual bound
shader before relying): world mask **11 / 14**, RT shadow mask **13**, RT spot **15**, RT point
**16**; bindless texture array via `core/BindlessConstants.hpp` (cap `MAX_BINDLESS_TEXTURES`,
manager `render/gpudriven/scene/BindlessTextureManager.hpp`). **The bound `.glsl` is the source of
truth** — open it and confirm.

## Compilation & permutations

- Compiled at **runtime** by shaderc (`Shader::compileFromSource`), not at build time. No offline
  SPIR-V step during development.
- **Permutations**: `Shader::addMacroDefinition(name[, value])` injects `#define`s before
  compilation (e.g. `RT_SHADOW_ENABLED`). The macro set forms a permutation key
  (`computePermutationKey`) so material/pipeline caches can key on it. Guard optional features with
  `#ifdef`.
- **Shipped builds** load pre-compiled `.vfshader` SPIR-V archives via
  `Shader::loadPrecompiledShader` (produced by the GameExport `ShaderPrecompiler`); no shaderc at
  runtime there.
- A compile failure surfaces via `Shader::getLastCompilationError()` → `vfLogError` in the console.

## Authoring checklist

1. Pick the right `#type` and `#version 460 core`; add needed `#extension` lines.
2. `#include` shared structs/functions from `common/` instead of redefining.
3. Match every `layout(set=…, binding=…)` to the C++ descriptor layout, and every `std430` struct
   to its C++ mirror (field order + alignment).
4. Guard optional features behind macro `#ifdef`s if the pipeline compiles permutations.
5. **`sync-shaders`** the file to `bin/Editor/resources/shaders/`, relaunch, verify (purple-frag
   diagnostic if a change seems ignored).
