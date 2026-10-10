# memory.md — GeneralsX iOS / Android project log

**Canonical project memory file.** Use this file for future GeneralsX / Zero Hour task notes. `memory.rd` was created by mistake during the 2026-10-10 investigation; do not treat it as a separate source of truth.

Updated: 2026-10-10 (after linker correction)

## Required workflow
- Before each GeneralsX/Zero Hour investigation or code change, inspect this file first.
- Compare claims against the actual repository files and the actual Actions logs; never claim a fix, commit, upload, or successful build unless verified.
- After every investigation/fix, append what was actually inspected, what changed, the commit/branch, and what remains unverified.
- Keep protected branch `a13-ios-build` untouched; preserve its A13 Vulkan settings and Russian `IOSProfileLauncher`.

## 2026-10-10 — Android reference audit and iOS linker failure
- Inspected Android reference repository `MYSOREZ/GeneralsZH-Android-Port`, branch `claude/launcher-ui-refresh`. Its recursive Git tree has 6,415 entries and is not truncated. No file named `memory.rd` exists in that repository tree. No `memory.rd` exists in the current mounted workspace either; this file establishes the requested running record in this repository.
- Read Android project instructions (`AGENTS.md`, `.github/copilot-instructions.md`), Android port guide, current available development diary, `cmake/gamemath.cmake`, online `NetworkMesh.cpp`, `OnlineServices_LobbyInterface.cpp`, `NGMPGame.cpp`, `NextGenTransport.cpp`, and core `Connection.cpp`, `DisconnectManager.cpp`, `FrameDataManager.cpp`, `Network.cpp`.
- Android `NetworkMesh.cpp` uses up to 3 signalling attempts when `retry_signalling` is enabled and removes the peer through the cannot-connect callback when retries fail.
- Compared the iOS `NetworkMesh.cpp`: iOS has additional handling for unknown/known join order, a departed lobby peer, in-match reconnect attempts, capturing connection data before `SetDisconnected()` can invalidate the entry, deferred signalling-object cleanup, and avoiding making the host leave its own lobby. These differences are real code, not assumptions. The full in-match lobby failure still needs runtime logs to prove the precise cause of a particular disconnect.
- Inspected local ZIP logs from Actions run `38038325029` (branch `fix/ios-android-lobby-compat`, commit `100ea08797c2278bf1ea814662db7525ad8a055e`). Configure explicitly enables deterministic GameMath. Final arm64 link fails because `_gm_acosf`, `_gm_asinf`, `_gm_atan2f`, `_gm_atanf`, `_gm_ceilf`, `_gm_cosf`, `_gm_floorf`, `_gm_sinf`, `_gm_sqrtf`, and `_gm_tanf` are unresolved. The final link command contains the game static libraries but no GameMath archive/target.
- Confirmed upstream GameMath defines CMake target `gamemath::gamemath`; iOS workflow passes `-DSAGE_USE_DETERMINISTIC_MATH=ON`, while `GeneralsMD/Code/Main/CMakeLists.txt` did not link that target. This is the proven cause of the current linker failure; it is a build/link issue, not evidence that NetworkMesh caused that build failure.
- Applied correction in `GeneralsMD/Code/Main/CMakeLists.txt`: conditionally link `gamemath::gamemath` to `z_generals` when the target exists. Commit: `a47b1b598cb7f10dda246f95abef5d7d440ed026` on `fix/ios-android-lobby-compat`. This should place the GameMath archive on the final link line; validation requires a new Actions run, so the build is not yet confirmed fixed.
- No changes to Android reference repository and no changes to protected `a13-ios-build`.

## Follow-up audit — connection callback lifetime and CI state
- Re-read `memory.rd` before continuing this investigation, as required.
- In Android `NetworkMesh.cpp`, the disconnect callback calls `plrConnection.SetDisconnected(...)` and then later reads `plrConnection.m_SignallingAttempts` and `plrConnection.m_userID`. The iOS counterpart explicitly captures these values before `SetDisconnected()`, with a comment that `UpdateState()` can erase the map entry. This is a credible dangling-reference hazard in the Android reference path; it is already guarded against in the inspected iOS branch. It is not enough by itself to prove the user's specific 5–10-second in-match disconnect without the corresponding runtime log.
- Android reference documents cross-platform retail LAN float determinism as unverified. That makes a true simulation desync a separate possibility from a Steam connection teardown; runtime logs must distinguish CRC/simulation mismatch from a Steam connection-state failure.
- Actions run `38042315366` for commit `a47b1b598cb7f10dda246f95abef5d7d440ed026` was checked and was still `in_progress` at the time of inspection. No successful build claim until the run completes.


## 2026-10-10 — iOS vs Android transport protocol comparison
- Re-read this canonical `memory.md`, repository `AGENTS.md`, `.github/copilot-instructions.md`, and commit instructions before continuing. Protected `a13-ios-build` was not modified.
- Compared current iOS branch `fix/ios-android-lobby-compat` against `MYSOREZ/GeneralsZH-Android-Port` for `NetworkMesh.cpp`, `NextGenTransport.cpp`, and `NetworkDefs.h`.
- Confirmed wire header layout in `Core/GameEngine/Include/GameNetwork/NetworkDefs.h`: packed `TransportMessageHeader` is CRC then magic; `TransportMessage` is header, payload data, then local-only length/address/port metadata. Both implementations calculate CRC over magic through payload (excluding the CRC field). The Android call that passes `&m_outBuffer[i]` with length header+payload is contiguous and does not include the trailing metadata; the iOS temporary header+payload vector is safer/clearer but its comment overstates the old wire-layout corruption claim.
- Confirmed iOS and Android receive paths both remove the `ENetworkChannel` byte, validate the packet header/CRC with `isGeneralsPacket`, and store header+payload. iOS uses the `MAX_MESSAGE_LEN` alias, which `NetworkDefs.h` explicitly defines equal to `MAX_NETWORK_MESSAGE_LEN`; this name difference is not a packet-size mismatch.
- Confirmed a real transport contract difference: Android `NextGenTransport::doSend` uses `sendResult >= 0` and drops the queue entry on failure; iOS now requires `sendResult == k_EResultOK`, retains failed packets for up to three attempts, and logs final drops. This is the rationale for commit `ace201fc7fe26adbc5ac66b3c4006d99f7638244`; it is a targeted transport reliability fix, not proof that simulation desync is solved.
- iOS `NetworkMesh.cpp` also has extra retry/join-order/peer-left lifecycle handling compared with Android. Existing log evidence still shows a local simulation CRC divergence alongside ICE timeouts, but does not isolate whether lost commands or deterministic simulation differences caused that particular desync.
- No new production-code changes were made during this comparison. No build or real cross-platform match was run here; synchronization remains unverified. Next useful evidence is a fresh build of commit `ace201fc7fe26adbc5ac66b3c4006d99f7638244` plus matching logs from iOS and Android/PC at the same frame/CRC.

## 2026-10-10 — Current compatibility branch and uploaded match log
- Re-read this canonical file and the repository instructions before continuing. Worked on `fix/ios-android-lobby-compat` source at `26429268848989f7a372d745347b01d891a8e60d`; the protected `a13-ios-build` branch was not changed.
- Inspected the uploaded `logs` branch. Its tree contains only `generals-stderr.log`, an iOS (`platform=apple`) runtime capture; it does not contain a paired Android/PC log.
- The iOS capture records a real simulation CRC mismatch at frame 137 (validated frame 100): local CRC `0x41281139`, while all five remote players report `0x28CD9FBF`. Its local math CRC is `0x97B538BF`. It also records ICE end-to-end timeouts for user `109141` immediately before the mismatch; it has no `Game Packet Send` failure diagnostics. This confirms a desync occurred but does not isolate transport loss from cross-platform simulation divergence.
- Rechecked source at the current branch head: `GameLogic::update()` already applies `setFPMode()` and has `ScopedFPUGuard`; the iOS workflow enables deterministic math; `NextGenTransport::doSend()` treats only `k_EResultOK` as accepted, retains failed packets, and blocks later packets for that peer. These fixes are present; no additional safe code defect is established by the available single-device log.
- Verified GitHub Actions run `38045368900` for this exact HEAD completed successfully, including the iOS Online Hub engine build and shell packaging. This is build validation, not a paired-device multiplayer test.
- No production-code change was justified. Multiplayer synchronization remains unverified until matching logs from the iOS and Android/PC participants at the same frame are available.
