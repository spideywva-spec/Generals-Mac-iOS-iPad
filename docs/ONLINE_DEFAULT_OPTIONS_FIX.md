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
