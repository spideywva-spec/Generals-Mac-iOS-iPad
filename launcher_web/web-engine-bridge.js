/* Generals X web engine integration.
 * Preserves the existing launcher UI. Does not introduce a second installer.
 * The native installer depends on WKWebView messageHandlers and cannot be
 * called from a normal browser; game-data mounting requires a browser adapter.
 */
(() => {
  if (window.webkit?.messageHandlers?.generalsX) return;
  let overlay = null;
  function notice(text) {
    const toast = document.getElementById("toast");
    if (toast) { toast.textContent = text; toast.hidden = false; }
    else console.warn(text);
  }
  function openEngine() {
    if (overlay) return;
    overlay = document.createElement("section");
    overlay.id = "generalsXWebEngine";
    overlay.setAttribute("aria-label", "Generals Zero Hour WebAssembly");
    overlay.style.cssText = "position:fixed;inset:0;z-index:2147483646;background:#000;display:flex;flex-direction:column";
    const toolbar = document.createElement("div");
    toolbar.style.cssText = "flex:none;background:#101b2a;color:white;padding:calc(env(safe-area-inset-top) + 8px) 12px 8px;display:flex;justify-content:space-between;align-items:center";
    const title = document.createElement("span");
    title.textContent = "Generals X · Zero Hour";
    const close = document.createElement("button");
    close.type = "button";
    close.textContent = "← В лаунчер";
    close.style.cssText = "background:#24415d;color:white;border:1px solid #567b9d;border-radius:7px;padding:8px 12px";
    close.onclick = () => { overlay.remove(); overlay = null; };
    toolbar.append(title, close);
    const frame = document.createElement("iframe");
    frame.src = "./game/GeneralsZH.html";
    frame.title = "Zero Hour WebAssembly";
    frame.allow = "fullscreen; autoplay; gamepad";
    frame.style.cssText = "border:0;flex:1;width:100%;background:#000";
    overlay.append(toolbar, frame);
    document.body.append(overlay);
  }
  document.addEventListener("DOMContentLoaded", () => {
    const button = document.getElementById("playButton");
    if (!button) return;
    button.addEventListener("click", event => {
      event.preventDefault();
      event.stopImmediatePropagation();
      const active = document.querySelector(".mode-card.is-active");
      if (active && active.dataset.id !== "zero-hour-online") {
        notice("Этот мод пока не поддерживается браузерным движком.");
        return;
      }
      openEngine();
    }, true);
  });
})();
