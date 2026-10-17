'use strict';
// 设置页「软件更新」区块（desktop/src/updater.js 的 mio-update:* IPC）
(() => {
  const up = window.mioUpdate;
  if (!up) return;
  const $ = (id) => document.getElementById(id);
  const fmt = (t) => (t ? new Date(t).toLocaleString() : '从未');
  function render(s) {
    if (!s) return;
    $('updAuto').checked = !!s.autoCheck;
    $('updVersion').textContent = s.version;
    $('updStatus').textContent = `上次检查：${fmt(s.lastCheck)}${s.status ? ` · ${s.status}` : ''}`;
    $('updCheck').disabled = !!s.busy;
    $('updCheck').textContent = s.busy ? '检查中…' : '立即检查';
    $('updNote').textContent = s.mode === 'nsis'
      ? '安装版：新版本在 Mio 内下载（校验 SHA-512），重启后安装。安装包未做代码签名，Windows 可能提示「未知发布者」。'
      : '便携版 / 开发版：发现新版本时打开下载页，需手动下载替换。';
  }
  $('updAuto').addEventListener('change', (e) => up.setAuto(e.target.checked).then(render));
  $('updCheck').onclick = async () => {
    $('updCheck').disabled = true;
    render(await up.check());
  };
  up.onChange(render);
  up.get().then(render);
})();
