// Generals X: native launcher remains unchanged; browser engine runs on its own canvas.
window.GeneralsXBrowser = (() => {
  let bootPromise;
  function script(path) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = './game/' + path;
      s.onload = resolve;
      s.onerror = () => reject(new Error('Модуль не загрузился: ' + path));
      document.body.appendChild(s);
    });
  }
  function element(tag, id, parent, value) {
    const e = document.createElement(tag);
    e.id = id;
    if (value !== undefined) e.textContent = value;
    parent.appendChild(e);
    return e;
  }
  function makeStage() {
    const stage = element('section', 'gx-embedded-stage', document.body);
    stage.style.cssText = 'position:fixed;inset:0;z-index:2147483640;background:#08162b;color:#e5f0ff;font:15px system-ui,sans-serif';
    const canvas = element('canvas', 'canvas', stage);
    canvas.tabIndex = 0;
    canvas.oncontextmenu = e => e.preventDefault();
    canvas.style.cssText = 'width:100%;height:100%;display:block;outline:0';
    const overlay = element('div', 'gx-overlay', stage);
    overlay.style.cssText = 'position:absolute;inset:0;background:linear-gradient(135deg,#08162b,#102f55);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px;text-align:center';
    element('h1', 'gx-title', overlay, 'GENERALS X');
    element('div', 'gx-sub', overlay, 'ZERO HOUR');
    const progress = element('div', 'gx-progress-wrap', overlay);
    progress.style.cssText = 'width:min(380px,85vw)';
    for (const [bar,val,track] of [['gx-bar','gx-dl-val','gx-track'],['gx-bar2','gx-un-val','gx-track2']]) {
      const row = element('div','',progress);
      row.style.margin = '12px 0';
      element('span',val,row,'0%');
      const t = element('div',track,row);
      t.style.cssText='height:7px;margin-top:7px;background:#203d5d;border-radius:8px;overflow:hidden';
      const b = element('div',bar,t);
      b.style.cssText='width:0;height:100%;background:#52aaff';
    }
    element('div','gx-detail',overlay,'Подготовка движка…');
    const play = element('button','gx-play',overlay,'Играть');
    const settings = element('button','gx-settings-btn',overlay,'Настройки');
    for (const b of [play,settings]) b.style.cssText='padding:12px 28px;border:1px solid #4887c4;border-radius:8px;background:#143b66;color:white;cursor:pointer';
    const box = element('div','gx-settings',overlay);
    box.hidden=true;
    const fps = element('select','gx-fps',box);
    for(const n of [30,60,90,120,144]) {const o=document.createElement('option');o.value=n;o.textContent=n+' FPS';fps.appendChild(o);}
    const builds=element('select','gx-build',box);
    const opt=document.createElement('option');opt.value='default_ru';opt.textContent='Zero Hour';builds.appendChild(opt);
    element('button','gx-wipe',box,'Очистить данные');
    element('div','gx-wipe-note',box,'Удалить загруженные файлы');
    const error=element('div','gx-error',overlay);
    error.style.cssText='color:#ffb5b5;max-width:500px;overflow-wrap:anywhere';
    element('div','gx-storage-kind',overlay);
    const mp=element('div','gx-mp',stage);
    mp.hidden=true;
    element('button','gx-mp-toggle',mp,'Сетевая игра');
    const panel=element('div','gx-mp-panel',mp);panel.hidden=true;
    for(const [tag,id] of [['button','gx-mp-host'],['button','gx-mp-join'],['div','gx-mp-hostbox'],['div','gx-mp-key'],['div','gx-mp-joinbox'],['input','gx-mp-keyinput'],['button','gx-mp-connect'],['div','gx-mp-status'],['div','gx-mp-peers']]) element(tag,id,panel);
    document.getElementById('gx-mp-hostbox').hidden=true;
    document.getElementById('gx-mp-joinbox').hidden=true;
    return stage;
  }
  async function launch() {
    if (bootPromise) return bootPromise;
    bootPromise=(async()=>{
      const stage=makeStage();
      window.GeneralsXEmbedded=true;
      for(const path of ['brotli.min.js','i18n/ru.js','i18n/en.js','i18n/i18n.js','storage.js','signaling.js','netbridge.js','loadscreen.js','lobby.js','mp-ui.js','game.js','loader.js']) await script(path);
      const boot = window.gxBoot();
      // Generals X Play is the single launch action: continue after storage init.
      const button = document.getElementById('gx-play');
      const timer = setInterval(() => {
        if (button.style.display === 'inline-block') {
          clearInterval(timer);
          button.click();
        }
      }, 100);
      setTimeout(() => clearInterval(timer), 30000);
      await boot;
    })().catch(err=>{
      bootPromise=null;
      const e=document.getElementById('gx-error');
      if(e)e.textContent=err.message;
      throw err;
    });
    return bootPromise;
  }
  return {launch};
})();
