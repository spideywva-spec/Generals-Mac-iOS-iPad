# Generals Hub — remote updates and release channels

## Architecture

Generals Hub uses a small JSON catalog plus large binary objects in Cloudflare R2.
The app ships with a bundled catalog and refreshes a remote catalog over HTTPS. If the network is unavailable, the last valid cached catalog remains usable.

Channels are independent:

- `stable` — normal releases;
- `beta` — test releases.

The selected channel is stored on-device. A mod can have different current versions in Stable and Beta.

The current bootstrap catalog is public through the GitHub branch URL. Once R2 is configured, publishing changes `remoteCatalogURL` to the R2 public `catalog.json`; old Hub builds first discover that URL through GitHub and then migrate to R2 automatically.

## R2 layout

```text
catalog.json
mods/
  online/
    stable/<version>.gxmod
    beta/<version>.gxmod
  enhanced/
    stable/<version>.gxmod
    beta/<version>.gxmod
  contra-x/
    stable/<version>.gxmod
    beta/<version>.gxmod
hub/
  stable/<version>/GeneralsZH-Hub-Online-unsigned.ipa
  beta/<version>/GeneralsZH-Hub-Online-unsigned.ipa
```

## Cloudflare R2 setup

Create one R2 bucket, for example `generals-hub`, and enable a public R2.dev URL or a custom download domain.
Create an R2 API token with Object Read & Write access for this bucket.

Run the interactive configurator once from the project worktree:

```powershell
.\scripts\publish\windows\configure-r2.ps1
```

It installs AWS CLI for the current Windows user when needed, stores the R2 key in the standard local AWS profile `generals-r2`, persists only the non-secret R2 settings as user environment variables, uploads a temporary probe object to verify both private bucket access and the public URL, and writes the required GitHub Actions secrets through `gh secret set`.

The secret key never needs to be pasted into ChatGPT or committed to the repository.

The configurator creates these GitHub repository secrets:

```text
CLOUDFLARE_ACCOUNT_ID
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
R2_BUCKET
```

The `Hub | Publish Catalog to R2` workflow mirrors `ios/hub/HubCatalog.json` to `catalog.json` whenever the catalog changes.

## Publish the current Stable content in one command

After configuration, build `online.gxmod`, Enhanced and Contra X, then publish all three packages together:

```powershell
.\scripts\publish\windows\publish-stable-mods-r2.ps1 -CommitAndPush
```

This uploads the shared Zero Hour + Online base package plus Enhanced and Contra X, updates their Stable channel records, uploads `catalog.json` to R2, commits the updated local catalog once, and pushes it to GitHub.

## Build and publish the Online/base package

```powershell
.\scripts\build\ios\windows\build-online-gxmod.ps1 `
  -Channel stable `
  -Version '1.04+GO-100126_QFE6'

.\scripts\publish\windows\publish-gxmod-r2.ps1 `
  -PackagePath 'D:\project\test\Generals-iPad\output\mods\online.gxmod' `
  -Channel stable `
  -ReleaseNotes 'Zero Hour 1.04 + Generals Online 100126_QFE6 base content' `
  -CommitAndPush
```

The Online package is a required base dependency for every playable Hub profile. It is downloaded once; Enhanced and Contra X do not duplicate retail GameData.

## Build and publish a mod

Enhanced stable example:

```powershell
.\scripts\build\ios\windows\build-enhanced-gxmod.ps1 `
  -Channel stable `
  -Version '1.0+2024-03-28'

.\scripts\publish\windows\publish-gxmod-r2.ps1 `
  -PackagePath 'D:\project\test\Generals-iPad\output\mods\enhanced.gxmod' `
  -Channel stable `
  -ReleaseNotes 'Stable Enhanced release' `
  -CommitAndPush
```

Enhanced beta example:

```powershell
.\scripts\build\ios\windows\build-enhanced-gxmod.ps1 `
  -Channel beta `
  -Version '1.1.0-beta.1'

.\scripts\publish\windows\publish-gxmod-r2.ps1 `
  -PackagePath 'D:\project\test\Generals-iPad\output\mods\enhanced.gxmod' `
  -Channel beta `
  -ReleaseNotes 'Testing new Enhanced changes' `
  -CommitAndPush
```

The publisher uploads the package, calculates SHA-256 and size, updates the selected catalog channel, uploads the new catalog to R2 and optionally commits/pushes the catalog.

## Publish a Hub update

The Hub IPA cannot replace its own signed application on iOS. It can detect a new release and show the version/changelog/download button; the user still installs/signs the IPA through the sideloading method in use.

```powershell
.\scripts\publish\windows\publish-hub-r2.ps1 `
  -IpaPath 'D:\project\test\Generals-iPad\output\GeneralsZH-Hub-Online-unsigned.ipa' `
  -Channel beta `
  -Version '0.2.0-beta.1' `
  -Build 21 `
  -ReleaseNotes 'Online and map-transfer fixes' `
  -CommitAndPush
```

## App behavior

`Mods & Updates` provides:

- Stable/Beta selector;
- manual Refresh;
- cached catalog fallback;
- Hub update status and changelog;
- Install/Update for Zero Hour + Online and mods when an HTTPS package URL exists;
- SHA-256 verification before installation;
- minimum Hub version enforcement;
- existing per-mod settings preservation during updates.

The bundled catalog remains a safe fallback if R2 or GitHub is unreachable.
