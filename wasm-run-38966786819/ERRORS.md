# Local error extraction from workflow run 38966786819

Job: 117195113711
Raw downloaded decoded job log size: 54542490 chars
Build and configure succeeded; packaging failed.

## Errors

```text
2026-10-16T21:12:43.1577193Z   883 |         fprintf(stderr, "FATAL ERROR: %s\n%s\n", prompt.str(), mesg.str());
2026-10-16T21:12:43.1582408Z   883 |         fprintf(stderr, "FATAL ERROR: %s\n%s\n", prompt.str(), mesg.str());
2026-10-16T21:14:12.6280706Z ERROR: no builds found in /home/runner/work/Generals-Mac-iOS-iPad/Generals-Mac-iOS-iPad/engine/web/gamedata/
2026-10-16T21:14:12.6297285Z ##[error]Process completed with exit code 1.
```

## Last 45 lines

```text
2026-10-16T21:13:53.0830976Z   245 |     virtual Bool has3DSensitiveStreamsPlaying() const = 0;
2026-10-16T21:13:53.0831601Z       |                  ^
2026-10-16T21:13:53.0832338Z In file included from /home/runner/work/Generals-Mac-iOS-iPad/Generals-Mac-iOS-iPad/engine/GeneralsMD/Code/GameEngineDevice/Source/VideoDevice/FFmpeg/FFmpegVideoPlayer.cpp:65:
2026-10-16T21:13:53.0833953Z /home/runner/work/Generals-Mac-iOS-iPad/Generals-Mac-iOS-iPad/engine/Core/GameEngineDevice/Include/OpenALAudioDevice/OpenALAudioManager.h:160:15: warning: 'setDeviceListenerPosition' overrides a member function but is not marked 'override' [-Winconsistent-missing-override]
2026-10-16T21:13:53.0835118Z   160 |         virtual void setDeviceListenerPosition(void);
2026-10-16T21:13:53.0835433Z       |                      ^
2026-10-16T21:13:53.0836168Z /home/runner/work/Generals-Mac-iOS-iPad/Generals-Mac-iOS-iPad/engine/Core/GameEngine/Include/Common/GameAudio.h:320:16: note: overridden virtual function is here
2026-10-16T21:13:53.0837045Z   320 |                 virtual void setDeviceListenerPosition() = 0;
2026-10-16T21:13:53.0837378Z       |                              ^
2026-10-16T21:13:53.0838484Z /home/runner/work/Generals-Mac-iOS-iPad/Generals-Mac-iOS-iPad/engine/GeneralsMD/Code/GameEngineDevice/Source/VideoDevice/FFmpeg/FFmpegVideoPlayer.cpp:519:18: warning: comparison of array 'this->m_frame->data' equal to a null pointer is always false [-Wtautological-pointer-compare]
2026-10-16T21:13:53.0839681Z   519 |     if (m_frame->data == nullptr) {
2026-10-16T21:13:53.0839953Z       |         ~~~~~~~~~^~~~    ~~~~~~~
2026-10-16T21:13:53.0840203Z 77 warnings generated.
2026-10-16T21:14:12.2109312Z [1370/1371] Linking CXX executable GeneralsMD/GeneralsXZH.js
2026-10-16T21:14:12.2110595Z em++: warning: -pthread + ALLOW_MEMORY_GROWTH may run non-wasm code slowly, see https://github.com/WebAssembly/design/issues/1271 [-Wpthreads-mem-growth]
2026-10-16T21:14:12.2112533Z em++: warning: running limited binaryen optimizations because DWARF info requested (or indirectly required) [-Wlimited-postlink-optimizations]
2026-10-16T21:14:12.2163806Z ##[group]Run mkdir -p web/dist
2026-10-16T21:14:12.2164167Z [36;1mmkdir -p web/dist[0m
2026-10-16T21:14:12.2164430Z [36;1mbash scripts/web/make-dist.sh[0m
2026-10-16T21:14:12.2226617Z shell: /usr/bin/bash -e {0}
2026-10-16T21:14:12.2226870Z env:
2026-10-16T21:14:12.2228402Z   PATH: /home/runner/work/_temp/fa7eff5a-978e-4888-bbca-239f0704c014/emsdk-main:/home/runner/work/_temp/fa7eff5a-978e-4888-bbca-239f0704c014/emsdk-main/upstream/emscripten:/snap/bin:/home/runner/.local/bin:/opt/pipx_bin:/home/runner/.cargo/bin:/home/runner/.config/composer/vendor/bin:/usr/local/.ghcup/bin:/home/runner/.dotnet/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games
2026-10-16T21:14:12.2230139Z   EMSDK: /home/runner/work/_temp/fa7eff5a-978e-4888-bbca-239f0704c014/emsdk-main
2026-10-16T21:14:12.2230776Z   EMSDK_NODE: /home/runner/work/_temp/fa7eff5a-978e-4888-bbca-239f0704c014/emsdk-main/node/24.19.0_64bit/bin/node
2026-10-16T21:14:12.2231597Z ##[endgroup]
2026-10-16T21:14:12.2364477Z ==> Shell
2026-10-16T21:14:12.2441634Z ==> Wasm build
2026-10-16T21:14:12.6279695Z     buildId: 25454a295e62
2026-10-16T21:14:12.6280706Z ERROR: no builds found in /home/runner/work/Generals-Mac-iOS-iPad/Generals-Mac-iOS-iPad/engine/web/gamedata/
2026-10-16T21:14:12.6297285Z ##[error]Process completed with exit code 1.
2026-10-16T21:14:12.6439080Z Post job cleanup.
2026-10-16T21:14:12.7304267Z [command]/usr/bin/git version
2026-10-16T21:14:12.7355788Z git version 2.55.0
2026-10-16T21:14:12.7397443Z Temporarily overriding HOME='/home/runner/work/_temp/8242a366-2386-4471-aa36-41dc68bd39f8' before making global git config changes
2026-10-16T21:14:12.7399115Z Adding repository directory to the temporary git global config as a safe directory
2026-10-16T21:14:12.7405805Z [command]/usr/bin/git config --global --add safe.directory /home/runner/work/Generals-Mac-iOS-iPad/Generals-Mac-iOS-iPad/engine
2026-10-16T21:14:12.7452853Z [command]/usr/bin/git config --local --name-only --get-regexp core\.sshCommand
2026-10-16T21:14:12.7496509Z [command]/usr/bin/git submodule foreach --recursive sh -c "git config --local --name-only --get-regexp 'core\.sshCommand' && git config --local --unset-all 'core.sshCommand' || :"
2026-10-16T21:14:12.7774660Z [command]/usr/bin/git config --local --name-only --get-regexp http\.https\:\/\/github\.com\/\.extraheader
2026-10-16T21:14:12.7816623Z [command]/usr/bin/git submodule foreach --recursive sh -c "git config --local --name-only --get-regexp 'http\.https\:\/\/github\.com\/\.extraheader' && git config --local --unset-all 'http.https://github.com/.extraheader' || :"
2026-10-16T21:14:12.8106162Z [command]/usr/bin/git config --local --name-only --get-regexp ^includeIf\.gitdir:
2026-10-16T21:14:12.8143812Z [command]/usr/bin/git submodule foreach --recursive git config --local --show-origin --name-only --get-regexp remote.origin.url
2026-10-16T21:14:12.8546067Z Cleaning up orphan processes
2026-10-16T21:14:12.8879341Z ##[warning]Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24: actions/checkout@v4, mymindstorm/setup-emsdk@v14. For more information see: https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/

```
