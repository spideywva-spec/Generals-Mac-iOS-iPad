/* Generals X browser engine adapter. Native iOS bridge remains unchanged. */
(() => {
  if (window.webkit?.messageHandlers?.generalsX) return;
  document.addEventListener("DOMContentLoaded", () => {
    const button = document.getElementById("playButton");
    if (!button) return;
    button.addEventListener("click", (event) => {
      event.stopImmediatePropagation();
      event.preventDefault();
      const selected = document.querySelector(".mode-card.is-active, .mode-card.active, .mode-card[aria-selected='true']");
      const profile = selected?.dataset?.id || "zero-hour-online";
      if (profile !== "zero-hour-online") {
        const toast = document.getElementById("toast");
        if (toast) { toast.textContent = "Веб-движок пока поддерживает только Zero Hour без модов"; toast.hidden = false; }
        return;
      }
      sessionStorage.setItem("generals-x-web-profile", profile);
      window.location.assign("./game/");
    }, true);
    const label = document.getElementById("playLabel");
    if (label) label.textContent = "ИГРАТЬ В БРАУЗЕРЕ";
  });
})();
