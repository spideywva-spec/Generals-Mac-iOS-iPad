# Graphics fixes log

## 2026-10-12 — water shader fallback (commit 4905e6a)
- Branch: `fix/mods-visible-cross-platform-sync` only. `a13-ios-build` and `build-ios-shell.yml` unchanged.
- `Core/GameEngineDevice/Source/W3DDevice/GameClient/Water/W3DWater.cpp`: on non-Windows platforms, attempt to load optional precompiled `shaders/riverwater.pso`, `shaders/water.pso`, and `shaders/trapezoidwater.pso` via the existing VFS shader loader. If unavailable, preserve existing fallback and log `[WATER_SHADER]`.
- This is a preliminary compatibility change, not proof reflections or shadows are restored. Shader assets and iOS Actions build/runtime remain unverified; the water rendering path and shadows require further investigation.

- 2026-10-12 commit `98f846abca4a153dfd28e7c2d40f15e81f459c21`: `GeneralsMD/Code/GameEngineDevice/Source/W3DDevice/GameClient/Shadow/W3DShadow.cpp` now propagates failed volumetric/projected manager initialization or resource acquisition instead of always returning TRUE, and logs `[SHADOW-DIAG]` when those stages fail. This fixes error reporting, not yet confirmed to restore visible shadows; requires iOS build and runtime testing. No changes to `a13-ios-build`, `build-ios-shell.yml`, or v2 workflow.

## 2026-10-12 water stability follow-up
- Branch: fix/mods-visible-cross-platform-sync only.
- Commit d65e85a: on non-Windows builds, skip destination-alpha shoreline blending because the destination alpha may be unreliable on DXVK/MoltenVK.
- Commit 8d9ee32: guard reflective-water render target and shader handles in drawSea, and require a camera and parent scene for mirror updates. Fall back to regular water drawing if reflection resources are absent.
- Neither change is verified in an iOS runtime test. Full shadows and reflections remain open; shader asset availability and actual render mode must be checked.
- a13-ios-build and build-ios-shell.yml were not changed.

## 2026-10-12 graphics source fixes (second pass)
- fac30f2: non-Windows RTS_DEBUG builds no longer force TERRAIN_LOD_NO_WATER during automatic terrain LOD calculation; legacy Windows debug shortcut remains.
- 0d10d86: removed speculative non-Windows .pso water shader VFS lookups (riverwater/water/trapezoidwater) because Windows generates these shader programs at runtime and the referenced assets were missing in the iOS log.
- e774486: fixed escaped newline sequences in volumetric/projected shadow diagnostic output.
- Branch fix/mods-visible-cross-platform-sync only; A13 workflow and a13-ios-build unchanged. Changes need CI and device verification; real-time D3D8 shader assembly and full water/shadow rendering are not implemented by these commits.

## 2026-10-12 water renderer follow-up
- 05cfda4: optional wave shader/target failure no longer returns early from ReAcquireResources, allowing remaining shared water resources to initialize; added null-safe reflection texture binding. The water object still selects translucent fallback on failure.
- 2ca6bf7: reflection prepass now delegates mode and target eligibility to WaterRenderObjClass instead of relying on possibly stale global water type; guards primaryW3DView.
- Only fix/mods-visible-cross-platform-sync changed. No device/CI verification performed. These commits do not create missing wave shader assets or prove that water reflections, shadows, and shoreline textures now render correctly.

## 2026-10-12 follow-up: safe wave shader fallback
- 073360e: only allocate the reflection render target after BOTH wave shader stages load; release any partial shader handles and select translucent water if either stage or target fails. This avoids leaked handles and expensive unusable targets while preserving shared water resource initialization.
- a7d1406: correct escaped newline characters in water fallback diagnostics.
- Scope: fix/mods-visible-cross-platform-sync only. No Vulkan/workflow changes. No iOS build/device verification; these changes protect the fallback, not restoration of unavailable shader effects.

## 2026-10-12 projected shadows
- 2ea548d: W3DProjectedShadowManager::ReAcquireResources checks both render-target format attempts and returns FALSE with diagnostic if neither is available, rather than continuing with null render target. This is a safety/diagnostic fix; it does not solve missing shadows or broken terrain textures without actual runtime evidence.
- Branch fix/mods-visible-cross-platform-sync only; no A13 or Vulkan workflow modifications.
