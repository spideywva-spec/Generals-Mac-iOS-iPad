# Generals X browser port — experimental

This is a **separate WebAssembly experiment**, not the existing iOS IPA, and does not alter SDL3GameEngine.

## Engine source
The initial browser build tests the existing open-source browser port:
https://github.com/Lolendor/Generals-WebAssembly

The upstream README documents Emscripten, WebGL2, browser storage and WebRTC. The source and its license must be reviewed before importing or modifying code. The GitHub Actions workflow checks out upstream at build time; this is not yet a vendored or independently maintained fork.

## Run a test build
Run the **Build browser Zero Hour (experimental)** workflow on branch `web-port-wasm`. If it succeeds, download the `generals-x-browser-experimental` artifact and serve the distribution over HTTPS with the headers needed for WebAssembly threads.

**No copyrighted Zero Hour assets are included.** Users need their own legitimately obtained game files. The engine may require asset packaging before gameplay can start.

## Current limitations
- Browser build **not yet verified** in GitHub Actions or on iPhone Safari.
- No live gameplay is deployed at generals-x-pwa.onrender.com; that site is still a PWA launcher.
- Browser multiplayer and iPhone compatibility remain unverified.
- This workflow is an initial compile test, not a promise of a working game.
