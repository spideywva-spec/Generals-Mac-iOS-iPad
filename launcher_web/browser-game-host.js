// Browser-only game host. Keeps the original Generals X app.js and CSS intact.
(() => {
  if (window.webkit?.messageHandlers?.generalsX) return;
  const play = document.getElementById('playButton');
  if (!play) return;
  const root = document.createElement('section');
  root.id = 'gx-browser-host';
  root.hidden = true;
  root.setAttribute('aria-label', 'Zero Hour WebAssembly');
  Object.assign(root.style, {position:'fixed',inset:'0',zIndex:'99999',background:'#080b0d'});
  const back = document.createElement('button');
  back.type = 'button';
  back.textContent = '← Generals X';
  back.setAttribute('aria-label', 'Вернуться в лаунчер');
  Object.assign(back.style,{position:'absolute',top:'max(12px, env(safe-area-inset-top))',left:'12px',zIndex:'2',background:'#172c41',color:'#fff',border:'1px solid #527da5',borderRadius:'8px',padding:'10px 16px'});
  const frame = document.createElement('iframe');
  frame.title = 'Zero Hour browser engine';
  frame.allow = 'fullscreen; autoplay';
  Object.assign(frame.style,{width:'100%',height:'100%',border:'0'});
  root.append(back,frame);
  document.body.append(root);
  back.addEventListener('click', () => {root.hidden=true;frame.removeAttribute('src');});
  play.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
    root.hidden = false;
    if (!frame.hasAttribute('src')) frame.src = './game/index.html';
  }, true);
})();
