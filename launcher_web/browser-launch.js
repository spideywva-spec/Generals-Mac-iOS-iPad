// Browser-only adapter. Native iOS bridge and launcher UI remain unchanged.
(() => {
  if (window.webkit?.messageHandlers?.generalsX) return;
  const target = "https://generals-x-wasm-preview.onrender.com/";
  const play = document.getElementById("playButton");
  if (!play) return;
  play.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
    // This is a separate WASM preview, not a verified playable game build.
    window.location.assign(target);
  }, true);
})();
