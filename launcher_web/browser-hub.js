/* Generals X browser adapter: same Hub catalog, same Play button, browser-private storage. */
window.GeneralsXBrowser = (() => {
  let catalogPromise;
  let busy = false;
  const catalog = async () => {
    if (!catalogPromise) catalogPromise = fetch("./hub-catalog.json", {cache:"no-store"}).then(r => {
      if (!r.ok) throw new Error("Каталог Hub недоступен");
      return r.json();
    });
    return catalogPromise;
  };
  async function profile(id) {
    const data = await catalog();
    const item = data.mods.find(m => m.profileId === id);
    if (!item) throw new Error("Профиль отсутствует в каталоге Hub");
    return { ...item, release: item.channels[data.defaultChannel || "stable"] || item.channels.stable };
  }
  async function directory() {
    if (!navigator.storage?.getDirectory) throw new Error("Браузер не поддерживает хранилище OPFS");
    return (await navigator.storage.getDirectory()).getDirectoryHandle("generals-x-profiles", {create:true});
  }
  async function installed(id) {
    const item = await profile(id);
    try {
      const dir = await directory();
      const file = await (await dir.getFileHandle(id + ".gxmod")).getFile();
      const meta = JSON.parse(await (await dir.getFileHandle(id + ".json")).getFile().then(f => f.text()));
      return meta.version === item.release.version && file.size === item.release.packageBytes;
    } catch { return false; }
  }
  async function install(id, progress) {
    if (busy) throw new Error("Установка другого профиля уже выполняется");
    busy = true;
    let writer;
    try {
      const item = await profile(id);
      const expected = item.release.packageBytes;
      const estimate = await navigator.storage?.estimate?.();
      if (estimate?.quota && estimate.quota - (estimate.usage || 0) < expected)
        throw new Error("Недостаточно свободного места в хранилище браузера");
      const dir = await directory();
      const filename = id + ".gxmod";
      const file = await dir.getFileHandle(filename, {create:true});
      const proxy = "https://generals-x-package-proxy.onrender.com/api/packages/" + encodeURIComponent(id);
      // Small, durable range requests: keep the working download on the device.
      // Closing after each block commits OPFS data; an interrupted download resumes safely.
      const BLOCK = 4 * 1024 * 1024;
      const MAX_RETRIES = 6;
      let received = (await file.getFile()).size;
      if (received > expected) {
        await dir.removeEntry(filename);
        throw new Error("Неверный размер частично загруженного пакета");
      }
      let lastProgressAt = 0;
      const report = (force = false) => {
        const now = performance.now();
        if (force || now - lastProgressAt > 350) {
          progress?.(received, expected);
          lastProgressAt = now;
        }
      };
      report(true);
      while (received < expected) {
        const end = Math.min(expected - 1, received + BLOCK - 1);
        let chunk = null;
        let lastError;
        for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
          try {
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 90000);
            try {
              const response = await fetch(proxy, {
                mode:"cors", credentials:"omit", cache:"no-store",
                signal:controller.signal,
                headers:{"Range":"bytes=" + received + "-" + end}
              });
              const range = response.headers.get("Content-Range");
              if (response.status !== 206 || range !== "bytes " + received + "-" + end + "/" + expected)
                throw new Error("HTTP " + response.status + "; Content-Range: " + range);
              chunk = await response.arrayBuffer();
              if (chunk.byteLength !== end - received + 1)
                throw new Error("Неполный блок данных");
            } finally {
              clearTimeout(timeout);
            }
            break;
          } catch (error) {
            lastError = error;
            if (attempt === MAX_RETRIES) break;
            // Exponential backoff with jitter-free bounded delays for mobile connections.
            await new Promise(resolve => setTimeout(resolve, Math.min(12000, 700 * 2 ** attempt)));
          }
        }
        if (!chunk) throw new Error("Загрузка прервалась после повторных попыток: " + lastError?.message + ". Прогресс сохранён — нажмите «Установить» для продолжения.");
        writer = await file.createWritable({keepExistingData:true});
        try {
          await writer.write({type:"write", position:received, data:chunk});
          await writer.close();
          writer = null;
        } catch (error) {
          await writer.abort().catch(()=>{});
          writer = null;
          throw new Error("Не удалось сохранить блок на устройстве: " + error.message);
        }
        received += chunk.byteLength;
        chunk = null;
        report();
        // Let Safari repaint the progress bar instead of monopolizing the UI thread.
        await new Promise(resolve => setTimeout(resolve,0));
      }
      report(true);
      const metadata = await dir.getFileHandle(id + ".json", {create:true});
      const metaWriter = await metadata.createWritable();
      await metaWriter.write(JSON.stringify({version:item.release.version,bytes:received,sha256Expected:item.release.sha256,format:"gxmod",unpacked:false}));
      await metaWriter.close();
      return item;
    } finally {
      if (writer) await writer.abort().catch(()=>{});
      busy = false;
    }
  }
  return {catalog,profile,installed,install};
})();
