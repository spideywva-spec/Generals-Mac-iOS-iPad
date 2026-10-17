// Embedded WebAssembly engine: stays in the original Generals X document.
window.GeneralsXBrowser = (() => {
  let bootPromise;
  async function script(path) {
    return new Promise((resolve, reject) => {
      const node = document.createElement('script');
      node.src = './game/' + path;
      node.onload = resolve;
      node.onerror = () => reject(new Error('Не загрузился модуль: ' + path));
      document.body.appendChild(node);
    });
  }
  async function launch() {
    if (bootPromise) return bootPromise;
    bootPromise = (async () => {
      const response = await fetch('./game/index.html', {cache:'no-cache'});
      if (!response.ok) throw new Error('Нет игрового интерфейса (' + response.status + ')');
      const html = new DOMParser().parseFromString(await response.text(), 'text/html');
      const stage = document.createElement('section');
      stage.id = 'gx-embedded-stage';
      stage.setAttribute('aria-label', 'Generals X — Zero Hour');
      stage.style.cssText = 'position:fixed;inset:0;z-index:2147483640;background:#080d15;overflow:hidden;';
      const style = document.createElement('style');
      style.textContent = [...html.querySelectorAll('style')].map(x => x.textContent).join('\n') +
        '\n#gx-embedded-stage canvas{width:100%;height:100%;display:block}'+
        '\n#gx-embedded-stage #gx-overlay{position:absolute;inset:0}';
      document.head.appendChild(style);
      // Transfer the game DOM, not its HTML page, iframe, or launcher.
      for (const child of [...html.body.children]) {
        if (child.tagName !== 'SCRIPT') stage.appendChild(document.importNode(child, true));
      }
      document.body.appendChild(stage);
      window.GeneralsXEmbedded = true;
      const modules = ['brotli.min.js','i18n/ru.js','i18n/en.js','i18n/i18n.js',
        'storage.js','signaling.js','netbridge.js','loadscreen.js',
        'lobby.js','mp-ui.js','game.js','loader.js'];
      for (const path of modules) await script(path);
      window.gxBoot();
      // Loader waits for its play button; initiate from Generals X's Play action.
      const button = document.getElementById('gx-play');
      const wait = setInterval(() => {
        if (button?.style.display === 'inline-block') {
          clearInterval(wait);
          button.click();
        }
      }, 100);
      setTimeout(() => clearInterval(wait), 30000);
    })().catch(error => {
      bootPromise = null;
      const stage = document.getElementById('gx-embedded-stage');
      if (stage) stage.innerHTML = '<div style="padding:40px;color:white;font:16px sans-serif"></div>';
      const msg = stage?.firstElementChild;
      if (msg) msg.textContent = 'Не удалось запустить движок: ' + error.message;
      throw error;
    });
    return bootPromise;
  }
  return { launch };
})();
