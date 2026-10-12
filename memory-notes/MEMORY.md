# Graphics fixes log

## 2026-10-12 — water shader fallback (commit 4905e6a)
- Branch: `fix/mods-visible-cross-platform-sync` only. `a13-ios-build` and `build-ios-shell.yml` unchanged.
- `Core/GameEngineDevice/Source/W3DDevice/GameClient/Water/W3DWater.cpp`: on non-Windows platforms, attempt to load optional precompiled `shaders/riverwater.pso`, `shaders/water.pso`, and `shaders/trapezoidwater.pso` via the existing VFS shader loader. If unavailable, preserve existing fallback and log `[WATER_SHADER]`.
- This is a preliminary compatibility change, not proof reflections or shadows are restored. Shader assets and iOS Actions build/runtime remain unverified; the water rendering path and shadows require further investigation.

- 2026-10-12 commit `98f846abca4a153dfd28e7c2d40f15e81f459c21`: `GeneralsMD/Code/GameEngineDevice/Source/W3DDevice/GameClient/Shadow/W3DShadow.cpp` now propagates failed volumetric/projected manager initialization or resource acquisition instead of always returning TRUE, and logs `[SHADOW-DIAG]` when those stages fail. This fixes error reporting, not yet confirmed to restore visible shadows; requires iOS build and runtime testing. No changes to `a13-ios-build`, `build-ios-shell.yml`, or v2 workflow.
