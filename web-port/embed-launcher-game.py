#!/usr/bin/env python3
"""Embed the browser engine in the existing Generals X launcher."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
app = root / "app.js"
text = app.read_text()
old = 'showToast("Демо: запрос запуска для " + activeCard.dataset.title);'
if text.count(old) != 1:
    raise RuntimeError("Expected launcher demo Play hook exactly once")
app.write_text(text.replace(old, "window.GeneralsXWebGame.open();"))

html = root / "index.html"
source = html.read_text()
marker = '<script src="./app.js"></script>'
if source.count(marker) != 1:
    raise RuntimeError("Expected launcher app.js exactly once")
overlay = """
<section id="gxWebGame" hidden style="position:fixed;inset:0;z-index:2147483000;background:#090e14">
  <button id="gxWebGameBack" type="button" style="position:absolute;top:16px;left:16px;z-index:3;padding:12px;background:#123451;color:white">← В лаунчер</button>
  <iframe id="gxWebGameFrame" title="Generals Zero Hour" allow="fullscreen;autoplay;gamepad" style="width:100%;height:100%;border:0"></iframe>
</section>
<script>
window.GeneralsXWebGame = (() => {
  const panel = document.getElementById('gxWebGame');
  const frame = document.getElementById('gxWebGameFrame');
  const back = document.getElementById('gxWebGameBack');
  function close() {
    panel.hidden = true;
    panel.style.display = 'none';
    frame.src = 'about:blank';
    document.body.style.overflow = '';
  }
  function open() {
    panel.hidden = false;
    panel.style.display = 'block';
    frame.src = './game/';
    document.body.style.overflow = 'hidden';
  }
  back.addEventListener('click', close);
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && !panel.hidden) close();
  });
  return {open, close};
})();
</script>
"""
html.write_text(source.replace(marker, overlay + marker))
