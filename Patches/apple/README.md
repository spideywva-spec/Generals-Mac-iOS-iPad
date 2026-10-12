# Apple graphics patches (work in progress)

Target: `fix/apple-global-render-target-fallback`. Apply only to the corresponding sources; these are **not automatically applied by the iOS build**.

| Feature | Patch | Status |
|---|---|---|
| Projected shadows (buildings and units where projected) | 01-projected-shadows.patch | Draft, not applied/tested |
| Water reflection target | 02-water-reflections.patch | Draft, not applied/tested |
| Other unit/volumetric shadows | — | Needs stencil/depth compatibility inspection |
| Fog of war | — | Needs source/destination texture format and CPU pixel layout inspection |
| Shroud filtering | — | Must preserve existing filtering; no safe patch yet |
| Terrain | — | A1R5G5B5 texture data must be converted if format changes |
| Particles | — | Vertex buffers and texture creation need independent checks |
| Explosions | — | Blend modes and particle shader states need independent checks |
| Decals | — | Texture formats and alpha blending need independent checks |
| Postprocessing | — | Depth/RT dimensions and shaders need independent checks |

The common render-target fallback is **already directly committed** to `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.cpp` in this branch, and is not a separate .patch file. It does not cover all texture/depth/shader creation paths.

All platform-specific changes must be guarded with `#if defined(__APPLE__)`. Do not change SDL3GameEngine, the A13 build workflow, Vulkan 1.2/1.3 flags, or multiplayer simulation logic.

**Caution:** A format fallback that changes pixel layout without converting the source data will corrupt shroud/terrain; an unconditional 256x256 fallback can break render-target size assumptions. Do not claim coverage without builds and runtime screenshots/logs.
