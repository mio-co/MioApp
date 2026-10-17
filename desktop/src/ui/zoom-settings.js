'use strict';
// 设置页「页面缩放」：默认缩放（Safari 档位，settings.json 的 defaultZoom；按站点的缩放在 zoom.json）
(() => {
  const api = window.mioSettings;
  const sel = document.getElementById('defaultZoom');
  if (!api || !sel) return;
  const LEVELS = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3];
  for (const z of LEVELS) {
    const o = document.createElement('option');
    o.value = String(z);
    o.textContent = `${Math.round(z * 100)}%`;
    sel.appendChild(o);
  }
  const render = (s) => {
    if (s && s.settings && typeof s.settings.defaultZoom === 'number') sel.value = String(s.settings.defaultZoom);
  };
  sel.addEventListener('change', async () => render(await api.set('defaultZoom', Number(sel.value))));
  api.onChange(render);
  api.get().then(render);
})();
