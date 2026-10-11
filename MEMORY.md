# MEMORY.md — iOS cross-platform synchronization experiments

## 2026-10-11 — Enable deterministic math in iOS shell build (experimental)

- Branch: `a13-ios-build` (user explicitly requested changes on their branch, not a separate test branch).
- Changed only `.github/workflows/build-ios-shell.yml`: append `-DSAGE_USE_DETERMINISTIC_MATH=ON` to the existing `cmake --preset ios-vulkan-online` configure command.
- Existing `cmake/gamemath.cmake` and `wwmath.h` already contain optional GameMath integration; they were not replaced with dvorovrus files.
- Preserve DXVK A12/A13 samplerMirrorClampToEdge workaround, Vulkan 1.2/1.3 handling, Russian IOSProfileLauncher and SDL3GameEngine. None of these files were edited.
- Motivation: cross-platform match iOS player weyva (player 3) vs PC. At validated frame 100, iOS CRC `F3AC6A78`, PC CRC `DCB9257F`; mismatch displayed on PC at frame 107.
- **Status:** build and cross-platform sync unverified. The change may fail at configure if the pinned GameMath dependency is unavailable or its build integration is incompatible. Enabling deterministic math on iOS alone is not proof of compatibility with stock PC.
- **Rollback:** remove only `-DSAGE_USE_DETERMINISTIC_MATH=ON` from the configure command (or revert commit `b9f1b09ef248ae3d96a302a9bbf595ad187269b5`). Do not change the A13 Vulkan/DXVK configuration.
- Next: inspect GitHub Actions configure/build logs; if successful, retest same map and peer, compare math CRC and first mismatching simulation frame.
