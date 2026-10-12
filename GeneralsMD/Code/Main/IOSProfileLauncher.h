#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

// GeneralsX @feature dvorovrus 25/09/2026 Show the embedded launcher before game initialization.
// Returns "vanilla" or a safe installed/bundled profile ID (for example
// "enhanced" or "contra-x").
const char *GeneralsXRunIOSProfileLauncher();

// The launcher lives in a standalone dylib, so it must not directly import
// symbols implemented by the main executable. The engine provides this callback
// before showing the launcher; launcher-only fast builds remain compatible with
// older shells where the callback is never installed.
typedef void (*GeneralsXIOSDiagnosticClearCallback)();
void GeneralsXSetIOSDiagnosticClearCallback(GeneralsXIOSDiagnosticClearCallback callback);

#endif
