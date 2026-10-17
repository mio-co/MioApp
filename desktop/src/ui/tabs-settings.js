'use strict';
// 设置页「标签页」区块：新标签页地址（空 = MioCore 导航，主窗口的登录状态会同步过来）
(() => {
  const api = window.mioSettings;
  if (!api) return;
  const $ = (id) => document.getElementById(id);
  const input = $('newTabUrl');
  if (!input) return;
  const render = (s) => {
    if (!s || document.activeElement === input) return;
    input.value = (s.settings && s.settings.newTabUrl) || '';
  };
  $('newTabForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    $('newTabError').textContent = '';
    try {
      const s = await api.set('newTabUrl', input.value.trim());
      input.blur();
      render(s);
      $('newTabError').textContent = '已保存';
    } catch {
      $('newTabError').textContent = '无效的网址（只支持 http / https）';
    }
  });
  $('newTabReset').onclick = async () => {
    input.value = '';
    render(await api.set('newTabUrl', ''));
  };
  api.onChange(render);
  api.get().then(render);
})();
