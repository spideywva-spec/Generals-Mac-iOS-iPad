# memory.rd — GeneralsX iOS / Android reference audit

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
