# Online profile DefaultOptions.ini — 2026-10-11

## Scope
Branch: `fix/mods-visible-cross-platform-sync`
Commit: `231c190b98e94931b0262e675380bce08f0acb65`

## Confirmed source paths
- Installed Online profile: `Documents/Mods/online/profile/` (via `GXHubInstalledProfilePath(@"online")`).
- Profile default settings: `Documents/Mods/online/profile/DefaultOptions.ini`.
- Global engine options: `Library/Application Support/GeneralsX/GeneralsZH/Options.ini` (via `EngineOptionsPath()`).

## Change
`GeneralsMD/Code/Main/IOSModManager.mm` now carries forward an existing Online profile's `profile/DefaultOptions.ini` into the staged replacement when reinstalling/updating the Online mod. An error preserving the file aborts the update before replacing the existing installation. Other profiles are unaffected.

## Important limitations
This commit **does not** redirect launcher graphics settings to DefaultOptions.ini or change how the engine loads it. The launcher currently reads/writes the global Options.ini; the correct engine precedence and profile file format still require verification before changing that behavior. Cross-platform multiplayer desync is not fixed or validated by this commit. No iOS compilation or runtime test has been completed.

## Protected files
No edits to `.github/workflows/build-ios-shell.yml`, `SDL3GameEngine`, `IOSProfileLauncher.mm`, A13/Vulkan configuration or network code.

## Rollback
Revert commit `231c190b98e94931b0262e675380bce08f0acb65` if the Online profile installer behavior regresses.

## 2026-10-11 — launcher graphics defaults aligned
Commit: `4c45fd73a8b89ec2bfac5b2737e7ff60c66c8c`

`IOSProfileLauncher.mm` now supplies the five repository `DefaultOptions.ini` values as fallbacks when loading/saving Online graphics settings: `IdealStaticGameLOD=High`, `StaticGameLOD=High`, `TextureReduction=0`, `HeatEffects=Yes`, `DynamicLOD=No`. Existing user values in the global engine `Options.ini` take precedence. The native and web launcher both use these fallbacks; neither overwrites an existing graphics choice merely by reading settings. The FPS slider/limit and A13 build configuration are unchanged.

**Not implemented:** a new per-profile graphics file writer or new LOD selection UI; no claim of measured FPS improvement. Revert commit `4c45fd73a8b89ec2bfac5b2737e7ff60c66c8c` to undo this launcher change. Compilation and runtime verification are still required.

## 2026-10-11 — visible launcher controls for DefaultOptions.ini

Commits: `99ff569c1ea742f2b750f9e6d607ad007e3acff0` (web UI), `eff165aa13b8ecbcbe155082a2ab2c5b980cd06f` (native bridge).

Added **visible** Russian segmented settings for `IdealStaticGameLOD` and `StaticGameLOD` (High/Medium/Low) to the web launcher's Graphics section. Existing UI controls for `TextureReduction` (texture quality), `HeatEffects`, and `DynamicLOD` remain visible. The native settingsLoad/settingsSave bridge now reads and persists both LOD selections in `Options.ini`, validates the allowed values, and no longer hardcodes both to High at save time. Web default for HeatEffects is corrected to Yes. This is a UI/persistence change, not a measured FPS optimization. Native/UIKit fallback does not yet have separate LOD selectors. Revert the two commits above in reverse order to undo these UI controls; earlier fallback commit `4c45fd7` can be reverted separately. No Vulkan, A13 workflow, or SDL3GameEngine changes.
