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
      const response = await fetch(item.release.packageURL, {mode:"cors",credentials:"omit",cache:"no-store"}).catch(error => { throw new Error("Сервер пакетов R2 блокирует загрузку из браузера (CORS) или сеть недоступна: " + error.message + ". Для исправления нужен CORS на R2 либо прокси того же домена."); });
      if (!response.ok || !response.body) throw new Error("Ошибка загрузки пакета: HTTP " + response.status);
      const dir = await directory();
      const file = await dir.getFileHandle(id + ".gxmod", {create:true});
      writer = await file.createWritable();
      const reader = response.body.getReader();
      let received = 0;
      while (true) {
        const {done,value} = await reader.read();
        if (done) break;
        await writer.write(value);
        received += value.byteLength;
        progress?.(received,expected);
      }
      await writer.close(); writer = null;
      if (received !== expected) {
        await dir.removeEntry(id + ".gxmod");
        throw new Error("Размер загруженного пакета отличается от каталога Hub");
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
