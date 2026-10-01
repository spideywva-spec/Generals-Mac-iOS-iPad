#!/bin/bash
# Rebuild only the native iOS launcher dylib and inject it into an existing
# unsigned GeneralsXZH shell IPA. No engine/DXVK/SDL rebuild is performed.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <base-shell.ipa> <output.ipa>" >&2
  exit 2
fi

BASE_IPA="$1"
OUTPUT_IPA="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LAUNCHER_SRC="${PROJECT_ROOT}/GeneralsMD/Code/Main/IOSProfileLauncher.mm"
LAUNCHER_HEADER="${PROJECT_ROOT}/GeneralsMD/Code/Main/IOSProfileLauncher.h"
GAME_FILE_MANAGER_SRC="${PROJECT_ROOT}/GeneralsMD/Code/Main/IOSGameFileManager.mm"
GAME_FILE_MANAGER_HEADER="${PROJECT_ROOT}/GeneralsMD/Code/Main/IOSGameFileManager.h"
VERSION_FILE="${PROJECT_ROOT}/ios/version.env"

PROJECT_VERSION="0.0.0"
ENGINE_VERSION="0.0.0"
LAUNCHER_VERSION="0.0.0"
if [[ -f "${VERSION_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${VERSION_FILE}"
fi

test -f "${BASE_IPA}" || { echo "ERROR: base shell IPA not found: ${BASE_IPA}" >&2; exit 1; }
test -f "${LAUNCHER_SRC}" || { echo "ERROR: launcher source not found: ${LAUNCHER_SRC}" >&2; exit 1; }
test -f "${LAUNCHER_HEADER}" || { echo "ERROR: launcher header not found: ${LAUNCHER_HEADER}" >&2; exit 1; }
test -f "${GAME_FILE_MANAGER_SRC}" || { echo "ERROR: game file manager source not found: ${GAME_FILE_MANAGER_SRC}" >&2; exit 1; }
test -f "${GAME_FILE_MANAGER_HEADER}" || { echo "ERROR: game file manager header not found: ${GAME_FILE_MANAGER_HEADER}" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EXTRACTED="${TMP}/ipa"
LAUNCHER_LIB="${TMP}/libGeneralsXLauncher.dylib"
mkdir -p "${EXTRACTED}"

LAUNCHER_COMMIT="${GX_LAUNCHER_COMMIT:-${GITHUB_SHA:-unknown}}"
ENGINE_COMMIT="${GX_ENGINE_COMMIT:-unknown}"
BASE_SHELL_RUN="${GX_BASE_SHELL_RUN:-unknown}"
LAUNCHER_RUN="${GX_LAUNCHER_RUN:-${GITHUB_RUN_ID:-unknown}}"

echo "==> Compiling native launcher only"
echo "    launcher commit: ${LAUNCHER_COMMIT}"
echo "    engine commit:   ${ENGINE_COMMIT}"
echo "    base shell run:  ${BASE_SHELL_RUN}"
xcrun --sdk iphoneos clang++ \
  -target arm64-apple-ios16.0 \
  -std=c++17 \
  -fobjc-arc \
  -fblocks \
  -dynamiclib \
  "-DGX_PROJECT_VERSION=\"${PROJECT_VERSION}\"" \
  "-DGX_ENGINE_VERSION=\"${ENGINE_VERSION}\"" \
  "-DGX_LAUNCHER_VERSION=\"${LAUNCHER_VERSION}\"" \
  "-DGX_LAUNCHER_COMMIT=\"${LAUNCHER_COMMIT}\"" \
  "-DGX_ENGINE_COMMIT=\"${ENGINE_COMMIT}\"" \
  "-DGX_BASE_SHELL_RUN=\"${BASE_SHELL_RUN}\"" \
  "-DGX_LAUNCHER_RUN=\"${LAUNCHER_RUN}\"" \
  -Wl,-install_name,@rpath/libGeneralsXLauncher.dylib \
  -framework Foundation \
  -framework UIKit \
  -framework QuartzCore \
  -lobjc \
  "${LAUNCHER_SRC}" \
  "${GAME_FILE_MANAGER_SRC}" \
  -o "${LAUNCHER_LIB}"

file "${LAUNCHER_LIB}" | grep -q "Mach-O"
lipo -info "${LAUNCHER_LIB}" | grep -q "arm64"
otool -D "${LAUNCHER_LIB}" | grep -q "@rpath/libGeneralsXLauncher.dylib"

echo "==> Opening base shell IPA"
ditto -x -k "${BASE_IPA}" "${EXTRACTED}"
APP="$(find "${EXTRACTED}/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "${APP}" && test -d "${APP}" || {
  echo "ERROR: no .app bundle found in base shell IPA" >&2
  exit 1
}

ENGINE="${APP}/GeneralsXZH"
TARGET_LIB="${APP}/Frameworks/libGeneralsXLauncher.dylib"
test -f "${ENGINE}" || { echo "ERROR: GeneralsXZH executable missing from base shell" >&2; exit 1; }
test -d "${APP}/Frameworks" || { echo "ERROR: Frameworks directory missing from base shell" >&2; exit 1; }
otool -L "${ENGINE}" | grep -q "@rpath/libGeneralsXLauncher.dylib" || {
  echo "ERROR: base engine is not linked to @rpath/libGeneralsXLauncher.dylib" >&2
  exit 1
}

echo "==> Replacing libGeneralsXLauncher.dylib"
cp "${LAUNCHER_LIB}" "${TARGET_LIB}"

PLIST="${APP}/Info.plist"
if [[ -f "${PLIST}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${PROJECT_VERSION}" "${PLIST}"
fi

# The artifact must remain unsigned. Sideloadly/AltStore/etc. signs the final IPA.
find "${APP}" -name "_CodeSignature" -type d -prune -exec rm -rf {} + 2>/dev/null || true
rm -f "${APP}/embedded.mobileprovision"

echo "==> Auditing launcher runtime"
while IFS= read -r dependency; do
  [[ -n "${dependency}" ]] || continue
  if [[ "${dependency}" == @rpath/* ]]; then
    relative="${dependency#@rpath/}"
    candidate="${APP}/Frameworks/${relative}"
    [[ -e "${candidate}" ]] || {
      echo "ERROR: launcher dependency is not embedded: ${dependency}" >&2
      exit 1
    }
  fi
done < <(otool -L "${TARGET_LIB}" | tail -n +2 | awk '{ print $1 }')

mkdir -p "$(dirname "${OUTPUT_IPA}")"
rm -f "${OUTPUT_IPA}"
(
  cd "${EXTRACTED}"
  /usr/bin/zip -qry "${OUTPUT_IPA}" Payload
)

test -f "${OUTPUT_IPA}"
echo "==> Fast launcher IPA ready: ${OUTPUT_IPA}"
du -h "${OUTPUT_IPA}"
