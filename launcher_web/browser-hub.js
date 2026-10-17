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
      // 8 MiB bounded requests: one buffer at a time, without buffering a multi-GB package.
      const BLOCK = 8 * 1024 * 1024;
      const CHECKPOINT = 4; // commit OPFS every 32 MiB so interrupted downloads can resume
      let received = (await file.getFile()).size;
      if (received > expected) {
        await dir.removeEntry(filename);
        throw new Error("Неверный размер частично загруженного пакета");
      }
      progress?.(received, expected);
      let blocks = 0;
      while (received < expected) {
        const end = Math.min(expected - 1, received + BLOCK - 1);
        let response;
        try {
          response = await fetch(proxy, {mode:"cors",credentials:"omit",cache:"no-store",
            headers:{"Range":"bytes=" + received + "-" + end}});
        } catch (error) {
          throw new Error("Прокси недоступен: " + error.message + ". Загруженные блоки сохранены.");
        }
        const range = response.headers.get("Content-Range");
        if (response.status !== 206 || range !== "bytes " + received + "-" + end + "/" + expected)
          throw new Error("Сервер не поддерживает безопасную докачку: HTTP " + response.status + ", Content-Range: " + range);
        const chunk = await response.arrayBuffer();
        if (chunk.byteLength !== end - received + 1)
          throw new Error("Получен неполный блок. Повторите загрузку.");
        if (!writer) writer = await file.createWritable({keepExistingData:true});
        await writer.write({type:"write",position:received,data:chunk});
        received += chunk.byteLength;
        progress?.(received,expected);
        if (++blocks % CHECKPOINT === 0 || received === expected) {
          await writer.close(); writer = null;
          // Yield to Safari's UI loop between storage checkpoints.
          await new Promise(resolve=>setTimeout(resolve,0));
        }
      }
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
