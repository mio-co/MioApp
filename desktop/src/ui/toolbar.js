'use strict';
const $ = (id) => document.getElementById(id);
const addr = $('addr');
let state = null;
let editing = false;

function displayUrl(s) {
  if (!s || !s.url) return '';
  return s.url;
}

function render(s) {
  if (!s) return;
  state = s;
  document.documentElement.classList.toggle('dark', !!s.dark);
  $('back').disabled = !s.canGoBack;
  $('forward').disabled = !s.canGoForward;
  document.body.classList.toggle('loading', !!s.loading);
  $('reload').title = s.loading ? '停止 (Esc)' : '刷新 (F5)';
  if (!editing) addr.value = displayUrl(s);
  const secure = /^https:/.test(s.url || '');
  $('lock').className = secure ? 'secure' : s.url ? 'insecure' : '';
  $('lock').title = secure ? '安全连接 (HTTPS)' : s.url ? '连接不安全' : '';
  const active = s.adblockEnabled && !s.siteWhitelisted && s.adblockReady;
  const shield = $('shield');
  shield.classList.toggle('off', !active);
  $('count').textContent = active && s.blocked ? (s.blocked > 99 ? '99+' : String(s.blocked)) : '';
  shield.title = !s.adblockEnabled ? '广告拦截已关闭' : s.siteWhitelisted ? `已在 ${s.host} 停用拦截` : !s.adblockReady ? '正在准备拦截规则…' : `已拦截 ${s.blocked} 个请求`;
}

$('back').onclick = () => window.mioToolbar.cmd('back');
$('forward').onclick = () => window.mioToolbar.cmd('forward');
$('reload').onclick = () => window.mioToolbar.cmd(state && state.loading ? 'stop' : 'reload');
$('external').onclick = () => window.mioToolbar.cmd('openExternal');
$('settings').onclick = () => window.mioToolbar.cmd('settings');
$('shield').onclick = () => window.mioToolbar.cmd('shieldMenu');

addr.addEventListener('focus', () => {
  editing = true;
  setTimeout(() => addr.select(), 0);
});
addr.addEventListener('blur', () => {
  editing = false;
  if (state) addr.value = displayUrl(state);
});
addr.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    addr.value = displayUrl(state);
    addr.blur();
  }
});
$('addrForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const v = addr.value.trim();
  if (!v) return;
  editing = false;
  addr.blur();
  window.mioToolbar.cmd('navigate', v);
});

window.mioToolbar.onState(render);
window.mioToolbar.onFocusAddress(() => {
  addr.focus();
  addr.select();
});
window.mioToolbar.state().then(render);
