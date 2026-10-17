# ОБЯЗАТЕЛЬНО: МЕНЬШЕ СЛОВ — БОЛЬШЕ ДЕЛА. ДОВОДИТЬ РАБОТУ ДО КОНЦА.

- Пользователь приходит за готовыми исправлениями, а не за общением. Не писать длинных объяснений, оправданий, повторений запроса и планов вместо действий. В ответе — только краткая причина, фактический результат, ссылка на коммит и статус проверки.
- Не останавливаться после первого небольшого изменения и не отвечать «сделано» через 30–50 секунд, когда задача ещё не завершена. Прорабатывать все связанные файлы и пути исполнения, исправлять первопричину, проверять сборку, Actions и логи, по возможности тестировать; доводить задачу до рабочего результата, а не до косметического патча.
- Не объявлять работу законченной без проверки. Если проверить на iOS невозможно или остаются ошибки — прямо указать «не проверено»/«не завершено» и конкретную причину. Не подменять выполнение обещаниями.
- Работать только в согласованной ветке; не трогать a13-ios-build, Vulkan, workflow V1/V2 без прямого разрешения. Каждый значимый патч и результат фиксировать в этом MEMORY.md с SHA для отката.

# ПРАВИЛО РАБОТЫ — ДЕЛО ВМЕСТО БОЛТОВНИ

Когда пользователь говорит «сделай/исправь», СРАЗУ работать с реальным кодом, логами и коммитами; не выдавать план или обещания вместо результата. Решать все перечисленные проблемы комплексно, проверять сборку и логи, честно отмечать непроверенное. Каждое изменение фиксировать здесь с веткой, файлами, коммитом, результатом и возможностью отката. НЕ трогать a13-ios-build, Vulkan и workflows без явного разрешения.

## Графические настройки Zero Hour на iOS
- Источник настроек графики — **Options внутри игры**, НЕ лаунчер. Лаунчер отвечает только за камеру/FPS.
- Low: упрощённые текстуры, без теней; Medium: средние текстуры и 2D-тени; High: полные текстуры и 3D-тени; Very High: максимальный встроенный профиль; Custom: индивидуальные переключатели и ползунки.
- Коммит в текущем изменении: GameLOD.cpp применяет Apple-only тени и текстуры по выбранному профилю, оставляет Custom и не перезаписывает FPS из графического пресета. Не обещать, что stencil, вода, MSAA или аппаратные ограничения уже исправлены без тестирования на iOS.

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

### 2026-10-12: iOS SIGSEGV in projected tree shadows
- Runtime `logs/generals-stderr.log` ends with signal 11 in `W3DProjectedShadowManager::queueDecal` called from `W3DTreeBuffer::drawTrees` during first menu frames.
- Earlier log reports projected-shadow render target allocation failed; manager initialization failed. Tree decals were nevertheless submitted with missing resources.
- Commit `253ed89e98d6dd713ec9a860d6e0afedb4e29680` adds an early guard in `queueDecal` for null shadow, missing index/vertex buffers, absent terrain renderer or heightmap. Prevents this particular invalid-resource path; runtime validation pending.
- Active branch `fix/mods-visible-cross-platform-sync`; A13 build branch and Vulkan workflows untouched.

### 2026-10-12: independent shadow initialization
- Commits 2b82ba6 and follow-up formatting: projected render-target failure no longer forces the entire W3DShadowManager init to fail when volumetric shadows initialized successfully. The projected render-target failure itself remains unresolved, and there is no device verification. No changes to water, terrain, Vulkan, or A13 build workflows.

### 2026-10-12: render target caps bypass for non-Windows (d9d5782)
- `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.cpp`: in the single-texture `DX8Wrapper::Create_Render_Target`, non-Windows no longer rejects a requested format solely on legacy D3D8 caps; tries actual texture allocation and retains the existing null-result check. Windows unchanged. Intended to address projected shadow render-target failure and possibly reflection render targets. Does not supply missing wave shader files. Not built or device-tested. Black terrain texture issue still unresolved.

### 2026-10-12: Apple projected shadow render target fallback
- Commit `b9e99887f0cbdedf084127dd6ad0121b111e17d2`: W3DProjectedShadowManager::ReAcquireResources tries 256x256 alpha then default render targets on Apple if both original 512x512 formats fail. Existing Windows logic unchanged. Device testing pending; shadow render passes may assume 512x512 and require adjustment. Water reflection and black terrain edge problems remain open.

### 2026-10-12: projected shadow copy bounds (5f21fa2)
- In `GeneralsMD/.../Shadow/W3DProjectedShadow.cpp`, `W3DProjectedShadow::updateTexture` now queries source and destination surface dimensions and copies their minimum rectangle, instead of always requesting 512x512. This matches the Apple 256x256 render-target fallback that reportedly enabled infantry 2D shadows.
- Only `fix/mods-visible-cross-platform-sync` changed. Not compiled or device-tested. Vehicle/building 3D shadow selection, wave-shader water reflections, and black terrain-edge corruption remain unresolved and must not be reported fixed.

### 2026-10-12: vehicle/building shadow fallback (2943ec3)
- In GeneralsMD W3DShadow.cpp `addShadow`, try original SHADOW_VOLUME first. On Apple only, if volume creation fails (stencil unavailable, disabled volumes, or geometry failure), attempt `SHADOW_DYNAMIC_PROJECTION` with a local copy of ShadowTypeInfo. Preserve original shadow settings and non-Apple behavior.
- Not device-tested; projected manager may still be unavailable, and projection might not be valid for all models. This does not restore genuine stencil 3D shadows, and water reflection/terrain-edge bugs remain unresolved.

### 2026-10-12: water reflection target format fallback
- On Apple only, W3DWater now retries reflection texture creation with explicit WW3D_FORMAT_A8R8G8B8 if the display-format target fails. Does not override shader availability; only one identified render-target failure path is addressed.
- Branch `fix/mods-visible-cross-platform-sync`; A13 and Vulkan workflows untouched. Device validation pending; this is not a verified fix for the three visual regressions.


### 2026-10-12 — iOS reduced-size render-target fallbacks
- Branch `fix/mods-visible-cross-platform-sync`: projected shadows now retry 128x128 and 64x64 alpha/non-alpha render targets if 512/256 fail (`W3DProjectedShadow.cpp`, commit `554aa6d5`).
- Water reflection target now retries 256x256 and 128x128 alpha/non-alpha targets when default resolution fails (`W3DWater.cpp`, commit `79e945e3`).
- These are resource allocation fallbacks, NOT a fix for disabled volumetric 3D shadows, missing wave shaders, terrain seams, fog or MSAA/anisotropic settings. Validate on-device and check fresh log. Do not change `a13-ios-build` or Vulkan workflow.


### 2026-10-12 — iOS stencil depth selection and terrain atlas pitch
- Apple-only: when depth mode detection fails, retry validated D24S8 depth/stencil before falling back to non-stencil depth. Does not falsely report stencil support; stencil shadows still require DXVK/MoltenVK compatibility.
- TerrainTextureClass::update: use actual D3D locked surface row pitch when writing tile pixels; avoids corruption and black seams on drivers with padded texture rows.
- Scope: fix/mods-visible-cross-platform-sync only; A13 branch and iOS workflows untouched. Water shader/reflection and actual on-device output remain to be validated.

## 2026-10-12 — terrain row pitch and in-game preset follow-up
- Branch fix/mods-visible-cross-platform-sync. TerrainTex.cpp: fixed remaining active atlas vertical border copies, flat terrain texture writes and edge atlas diagnostic writes to use locked_rect.Pitch rather than width-based row stride. Prevents corruption with padded GPU rows.
- GameLOD.cpp: Apple-only in-game quality presets now control cloud shadows, ground lighting, soft shorelines, alongside earlier texture reduction and shadow settings; Custom keeps individual toggles.
- CI diagnostic: workflow 38249666944 failed in vcpkg setup due to HTTP 504, before C++ compilation. Latest runs 38250407602 / 38250407457 were in progress when inspected. Runtime on A13 not yet verified. Outstanding: full water reflection and wave shader functionality, fog/MSAA/FXAA/anisotropy UI, Very Low preset, stencil support and cross-platform networking; do not call these finished.

## 2026-10-12 — скриншот iOS: чёрные полосы на берегу, нет 3D-теней и отражений
- Скриншот показывает чёрные/полосатые артефакты вдоль стыка воды и суши. НЕ считать исправленными 3D-тени, отражения, волны или весь берег без теста на устройстве.
- TerrainTex.cpp: в update() блок вертикального копирования краёв атласа использовал surface_desc.Width*pixelBytes как stride вместо locked_rect.Pitch; исправлено на Pitch, чтобы не читать неверные строки при padded GPU texture rows.
- Проверка на iOS и подтверждение причины всех полос пока отсутствуют. Требуется изучить runtime log, shoreline mesh/UV, stencil capability и water reflection path; не трогать a13-ios-build/Vulkan/workflows.

## 2026-10-12 — texture atlas border diagnostic
- В TerrainTex.cpp исправлено чтение верхней обёртки: исходный код для всех четырёх строк читал одну строку из-за width*Pitch вместо (width+j)*Pitch. Нижнюю обёртку НЕ менять до проверки направления копирования и адресов.
- Водные отражения и 3D тени не подтверждены; сборка/тест на iPhone не выполнялись.

## 2026-10-12 — graphics preset shoreline state and terrain validation
- In both Generals and GeneralsMD GameLOD.cpp, shoreline-detail refresh now compares effective iOS preset settings rather than only raw INI flags; fixes preset transitions where soft water edge changes but INI flags match.
- TerrainTex.cpp updateFlat rejects both incorrect atlas width and incorrect height before writing.
- No Vulkan/A13 workflows or launcher changed. These changes require iOS build and visual testing; they are not proof that 3D stencil shadows, reflections, or MSAA work.

## 2026-10-12 — graphics code comparison with ammaarreshi
- Compared the source `ammaarreshi/Generals-Mac-iOS-iPad` main tree with `fix/mods-visible-cross-platform-sync`: 35 different shared graphics-related source/header files (out of 1000 graphics-matching files). Blind wholesale replacement would erase iOS A13-specific rendering, terrain pitch, shadow and water fallbacks.
- Ported the upstream coordinated per-render-frame cloud animation update into both Core FlatHeightMap.cpp and HeightMap.cpp, and added the upstream W3DShaderManager::updateCloud/TerrainShader2Stage::updateCloud declarations and implementation, retaining existing mod-related clock animation logic in updateNoise1. This changes the cloud offset update to frame-based rather than relying solely on shader pass calls.
- Did not overwrite iOS rendering backends, build workflows, water/shadow fallback or mod files. Requires actual iOS build and rendering verification.

## 2026-10-12 Direct graphics copy from ammaarreshi
- User explicitly requested direct upstream replacement, excluding SDL3GameEngine. Copied 20 graphics files in commits c5bd940, f1fc2df and cb496250 on fix/mods-visible-cross-platform-sync: W3D terrain, water, shadow, display, shader, view, particle, shroud, graphics LOD/options, DX8 renderer/wrapper/bitmap/polygon renderer. No SDL3GameEngine or workflows changed.
- These exact overwrites intentionally discard previous A13-specific graphics fixes in overwritten files. Build and runtime compatibility not yet verified. Remaining WW3D2 texture/surface/asset files have NOT been copied.

## 2026-10-17 — Generals X Web browser-engine test
- Branch: `generals-x-web-engine` forked from `fix/mods-visible-cross-platform-sync`; native branch untouched.
- `launcher_web/index.html`: loads `web-engine-bridge.js` before existing `app.js`.
- `launcher_web/web-engine-bridge.js`: intercepts Play only in browser mode, navigates to `/game/` for Zero Hour; native WebKit bridge is unaffected. Mod profiles explicitly unsupported.
- Render build must copy `launcher_web` to publish root and download the upstream TheodoryLabs v0.5.1-web HTML/JS/WASM into `game/`. No original .big assets are bundled; current upstream engine build and multiplayer are NOT integrated. Web rendering/playability unverified.
- Rollback: revert commits on `generals-x-web-engine` or delete test branch; original iOS branch untouched.

- Correction: no separate browser game window or new launcher installer. `web-engine-bridge.js` now reuses the existing Play button and embeds the engine viewport over the existing launcher, with Back control. IndexedDB caches engine JS/WASM; current engine HTML still fetches its own runtime from `/game/`, so offline and game asset integration remain incomplete. Native installation logic remains untouched. Browser playability not verified.

## 2026-10-17 — remove redundant browser engine installation
- Branch `generals-x-web-engine`: removed the incorrect IndexedDB JS/WASM download/install path from `web-engine-bridge.js`. The existing Generals X Play control now loads the deployed WebAssembly engine directly in the same browser tab, with a return button. The launcher UI and native installer were not changed.
- Critical limitation: the existing launcher installer uses the native WKWebView bridge and cannot install/mount `.big` game files in a plain web browser without a new browser-specific filesystem adapter. Therefore playable game is NOT verified and this commit must not be represented as complete installation integration.


## 2026-10-17 — Generals X browser engine integration (test branch)
- Branch: `generals-x-web-engine`. Original `launcher_web` HTML/CSS, settings, native installation/unpacking/profile management and `window.webkit.messageHandlers.generalsX` are preserved.
- `launcher_web/app.js`: when no native IPA bridge exists, the existing Play button for base `online` profile navigates in the SAME TAB to `./engine/GeneralsZH.html`; native IPA path remains untouched. Browser mods are not claimed supported.
- Render static service `generals-x-web-integrated` deploys the existing `launcher_web` and fetches pinned TheodoryLabs WebAssembly engine release `v0.5.1-web` into `public/engine/`. Engine binary is not copied into GitHub.
- CRITICAL LIMITATION: engine does NOT bundle game `.big` assets. Its documented VFS requires game archives available under `/engine/assets/` with HTTP Range support. Current static deployment does not supply these assets; actual gameplay cannot be claimed functional until a lawful local-asset browser import/VFS adapter is implemented and tested.
- CRITICAL LIMITATION: upstream SETUP.md explicitly states Safari is unsupported (WebAssembly Asyncify), so iPhone Safari success must NOT be claimed.
- Web multiplayer is not implemented in upstream engine (WebRTC transport pending); do not claim cross-platform online works.
- No changes to `SDL3GameEngine`, iOS build workflows, or the production branch.


## 2026-10-17 — Correction: NO separate game window
- User requires existing `launcher_web` to handle download, installation, verification, and game launch through the existing native Generals X bridge; only engine internals may be replaced.
- Removed erroneous browser navigation to `./engine/GeneralsZH.html` from `launcher_web/app.js` (commit `5e160a1`). The native download/install/launch handler remains unchanged.
- Browser-only static site cannot execute native IPA installation or start the native engine. Do not present Render WASM test sites as the finished app. Engine replacement is NOT complete or verified.

## 2026-10-17 — Browser Play handler integration (commit 088b62ea)
- Changed only `launcher_web/app.js` in experimental `generals-x-web-engine` branch. Existing Play button now calls `launchBrowserEngine()` in regular browsers instead of displaying the IPA-only message. Native bridge behavior is unchanged.
- Inline runtime creates a canvas in the same document (no iframe, duplicate launcher or redirect), loads `engine/GeneralsZH.js` and configures `Module.canvas`/`locateFile`.
- Explicit preflight checks WebAssembly, WebGL2, the engine WASM, and `/engine/assets/INIZH.big` before starting. Render currently bundles WASM/JS but NOT legally owned game archives; browser gameplay remains BLOCKED until lawful asset import/range-serving integration. This is partial integration, not a verified playable release. Upstream does not support Safari.

## 2026-10-17 — Browser download blocked at 0%
- Browser installer now attempts same-origin `/api/packages/<profile>` before direct R2 CORS fetch, with explicit diagnostic when both unavailable. Render static site does not currently implement this API; CORS or a dynamic proxy must be configured for actual fix. OPFS remains device-local; no confirmed successful download or playable browser game. Production iOS branch unchanged.
