/* Browser runtime adapter: use existing launcher installation and Play UI.
   Native iOS bridge remains untouched. No extra game window or new installer. */
(() => {
  if (window.webkit?.messageHandlers?.generalsX) return;
  const DB = "generals-x-browser-assets";
  const STORE = "files";
  function openDB() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB, 1);
      req.onupgradeneeded = () => req.result.createObjectStore(STORE);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  async function getAsset(name) {
    const db = await openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const req = tx.objectStore(STORE).get(name);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
      tx.oncomplete = () => db.close();
    });
  }
  async function storeAsset(name, blob) {
    const db = await openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).put(blob, name);
      tx.oncomplete = () => { db.close(); resolve(); };
      tx.onerror = () => reject(tx.error);
    });
  }
  async function installed() {
    return !!(await getAsset("GeneralsZH.wasm"));
  }
  function message(msg) {
    const toast = document.getElementById("toast");
    if (toast) { toast.textContent = msg; toast.hidden = false; }
    else alert(msg);
  }
  async function install() {
    message("Загрузка браузерного движка…");
    for (const name of ["GeneralsZH.js", "GeneralsZH.wasm"]) {
      const response = await fetch("./game/" + name);
      if (!response.ok) throw new Error("Не удалось скачать " + name + ": HTTP " + response.status);
      await storeAsset(name, await response.blob());
    }
    message("Движок установлен в браузере. Игровые .big ресурсы нужно добавить отдельно.");
  }
  async function launch() {
    const wasm = await getAsset("GeneralsZH.wasm");
    const js = await getAsset("GeneralsZH.js");
    if (!wasm || !js) throw new Error("Сначала установите движок.");
    // The original engine HTML bootstraps Emscripten. Embed its page into the
    // existing launcher viewport instead of navigating to a separate window.
    const frame = document.createElement("iframe");
    frame.title = "Generals Zero Hour";
    frame.src = "./game/";
    frame.allow = "fullscreen; gamepad; autoplay";
    frame.style.cssText = "position:fixed;inset:0;width:100%;height:100%;border:0;z-index:2147483646;background:#000";
    const back = document.createElement("button");
    back.textContent = "← Generals X";
    back.style.cssText = "position:fixed;top:env(safe-area-inset-top,12px);left:12px;z-index:2147483647;padding:10px 14px;background:#101b2a;color:#fff;border:1px solid #4d719a;border-radius:8px";
    back.onclick = () => { frame.remove(); back.remove(); };
    document.body.append(frame, back);
  }
  document.addEventListener("DOMContentLoaded", () => {
    const button = document.getElementById("playButton");
    if (!button) return;
    button.addEventListener("click", async event => {
      event.stopImmediatePropagation();
      event.preventDefault();
      const card = document.querySelector(".mode-card.is-active");
      if (card && card.dataset.id !== "zero-hour-online") {
        message("Браузерный движок для этого мода ещё не подключён.");
        return;
      }
      button.disabled = true;
      try { if (!(await installed())) await install(); else await launch(); }
      catch (error) { message(error.message || "Ошибка браузерного движка"); }
      finally { button.disabled = false; }
    }, true);
  });
})();
