# iOS build failure — run 38038325029

Downloaded artifact: `GeneralsXZH-ios-build-logs` (artifact ID `11666325276`). The ZIP was downloaded and extracted locally; the failure is in the final arm64 link step, not CMake configuration or compilation.

## Fatal linker error

`ld: symbol(s) not found for architecture arm64`

Undefined symbols include:
- `_gm_acosf`
- `_gm_asinf`
- `_gm_atan2f`
- `_gm_atanf`
- `_gm_ceilf`
- `_gm_cosf`
- `_gm_floorf`
- `_gm_sinf`
- `_gm_sqrtf`
- `_gm_tanf`

These are referenced by `libz_gameengine.a` and engine/render libraries. The final command links `GeneralsMD/GeneralsXZH.app/GeneralsXZH`, then clang exits 1 and Ninja stops at step 1467/1468. This indicates the implementation/object file or library defining the `gm_*f` math symbols is missing from the iOS link target (or the target's math shim exports different symbol names). Next fix: locate definitions/references for `gm_acosf`, `gm_asinf`, `gm_atan2f`, `gm_atanf`, `gm_ceilf`, `gm_cosf`, `gm_floorf`, `gm_sinf`, `gm_sqrtf`, `gm_tanf`; ensure the source is compiled into the iOS target or its library is linked. Do not treat the numerous CMake feature probes marked 'not found' as fatal errors.

Workflow: https://github.com/spideywva-spec/Generals-Mac-iOS-iPad/actions/runs/38038325029

Original artifact ZIP (downloaded locally): `GeneralsXZH-ios-build-logs.zip`; it contains `build_ios_hub_online.log` (42,695,928 bytes) and `configure_ios_hub_online.log` (209,818 bytes).