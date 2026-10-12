# iPad — Generals Hub

Generals Hub is the single iPad app for Generals Online plus installable mod profiles. The Hub does not expose a separate vanilla Zero Hour launch mode.

## Base app

The Hub IPA contains only the Online-capable iPad engine (`SAGE_USE_GENERALS_ONLINE=ON` + deterministic math), native bridge/web launcher, and `HubCatalog.json`. It intentionally contains **no retail GameData and no mods**. Zero Hour + Online base content, Enhanced and Contra X install after sideloading.

Build on Windows from the Hub worktree:

```powershell
.\scripts\build\ios\windows\build-hub-online.ps1
```

Expected output: `D:\project\test\Generals-iPad\output\GeneralsZH-Hub-Online-unsigned.ipa`.

## Downloadable content packages

Hub packages use the `.gxmod` extension. A package is an uncompressed USTAR archive with `manifest.json` first and files under `profile/`. iOS streams extraction to `Documents/Mods/<profileId>/profile` without holding a multi-gigabyte archive in memory.

`online.gxmod` is special: its `profile/` directory is the shared Zero Hour 1.04 + Generals Online **base GameData**. Enhanced and Contra X remain overlays and reuse that one base install.

Windows builders:

```powershell
.\scripts\build\ios\windows\build-online-gxmod.ps1
.\scripts\build\ios\windows\build-enhanced-gxmod.ps1
.\scripts\build\ios\windows\build-contra-gxmod.ps1
```

Outputs are `output\mods\online.gxmod`, `output\mods\enhanced.gxmod` and `output\mods\contra-x.gxmod`.

## First device test

1. Install the lightweight `GeneralsZH-Hub-Online-unsigned.ipa` with Sideloadly.
2. Open Generals Hub. Zero Hour + Online should show **NOT INSTALLED** and the primary action should be **INSTALL**.
3. Before the Online package is published to R2, tap INSTALL and choose `online.gxmod` from Files. After publishing, the same button downloads it directly.
4. Verify Zero Hour + Online changes to READY and can launch into skirmish/Online.
5. Install `enhanced.gxmod` from Add Mod (remote or Files). Enhanced should become Installed and expose Play, Settings, and Remove.
6. Open Enhanced Settings, change one Enhanced-only option, save, and return.
7. Start Enhanced and verify it reuses the installed Online/base GameData plus the Enhanced overlay.
8. Repeat with Contra X, then export Diagnostics/logs.

Expected log markers:

```text
[HUB] installed profile='online' ...
[HUB] iOS working directory (downloaded Online base): .../Documents/Mods/online/profile
[HUB] installed profile='enhanced' ...
[HUB] external profile selected id='enhanced' path='.../Documents/Mods/enhanced/profile'
INFO: iOS launcher: profile 'enhanced' -> -mod ...
```

Enhanced then builds its normal `Documents/EnhancedRuntime` overlay from the externally installed source profile.

## Settings isolation

Hub Settings contains only shared engine, graphics, camera and performance options. Mod-specific launcher options are never mixed into Hub Settings.

Known mod settings are stored independently:

```text
Documents/Mods/enhanced/settings.ini
Documents/Mods/contra-x/settings.ini
```

Updating a `.gxmod` package preserves its existing `settings.ini`. Legacy standalone `Documents/EnhancedSettings.ini` / `Documents/ContraSettings.ini` files are migrated when present.

## Updates and remote install

`HubCatalog.json` contains catalog version, package size, SHA-256 and `packageURL`. When the catalog version differs from the installed manifest, Mods exposes Update.

Remote Install/Update requires HTTPS and a matching SHA-256. A profile with an empty `packageURL` falls back to Files import for testing; once published to R2 the same launcher action downloads it directly. Never embed private GitHub credentials in the app.

## Storage and runtime precedence

Hub checks free space before extraction. Files import opens the security-scoped source directly instead of first copying the multi-gigabyte package into the app.

Base GameData precedence is:

1. `Documents/Mods/online/profile` — normal Hub path;
2. bundled `GameData` — legacy standalone compatibility only;
3. `Documents` — developer fallback.

Mod overlay precedence is:

1. `Documents/Mods/<profileId>/profile`;
2. bundled `Profiles/<profileId>` fallback for legacy standalone builds.

This keeps the signed Hub app small and immutable while allowing the large base content and mods to be installed and updated independently.
