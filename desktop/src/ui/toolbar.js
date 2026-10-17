'use strict';
const $ = (id) => document.getElementById(id);
const addr = $('addr');
let state = null;
let editing = false;

// 不编辑时只显示域名（Safari 式）；点进去显示完整网址
function displayUrl(s) {
  if (!s || !s.url) return '';
  return s.displayHost || s.url;
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

const SVG_NS = 'http://www.w3.org/2000/svg';
function closeIcon() {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  const p = document.createElementNS(SVG_NS, 'path');
  p.setAttribute('d', 'M7 7l10 10M17 7L7 17');
  svg.appendChild(p);
  return svg;
}

let dragFrom = -1;
function renderTabs(s) {
  const box = $('tabs');
  const tabs = s.tabs || [];
  const containers = new Map((s.containers || []).map((c) => [c.id, c]));
  // 只在结构变化时重建，否则就地更新（避免拖拽 / 悬停时闪烁）
  const sig = tabs.map((t) => t.id).join(',');
  if (box.dataset.sig !== sig) {
    box.dataset.sig = sig;
    box.textContent = '';
    tabs.forEach((t, i) => {
      const tab = el('div', 'tab');
      tab.dataset.id = String(t.id);
      tab.setAttribute('role', 'tab');
      tab.draggable = true;
      const fav = el('span', 'fav');
      const title = el('span', 'title');
      const close = el('button', 'tclose');
      close.title = '关闭标签页 (Ctrl+W)';
      close.appendChild(closeIcon());
      close.addEventListener('mousedown', (e) => e.stopPropagation());
      close.addEventListener('click', (e) => {
        e.stopPropagation();
        window.mioToolbar.cmd('closeTab', t.id);
      });
      tab.append(fav, title, close);
      tab.addEventListener('mousedown', (e) => {
        if (e.button === 0) window.mioToolbar.cmd('selectTab', t.id);
      });
      // 中键关闭
      tab.addEventListener('auxclick', (e) => {
        if (e.button === 1) {
          e.preventDefault();
          window.mioToolbar.cmd('closeTab', t.id);
        }
      });
      tab.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        window.mioToolbar.cmd('tabContextMenu', t.id);
      });
      tab.addEventListener('dragstart', (e) => {
        dragFrom = i;
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', String(i));
      });
      tab.addEventListener('dragover', (e) => {
        if (dragFrom < 0) return;
        e.preventDefault();
        tab.classList.add('drop');
      });
      tab.addEventListener('dragleave', () => tab.classList.remove('drop'));
      tab.addEventListener('drop', (e) => {
        e.preventDefault();
        tab.classList.remove('drop');
        if (dragFrom >= 0 && dragFrom !== i) window.mioToolbar.cmd('moveTab', `${dragFrom},${i}`);
        dragFrom = -1;
      });
      tab.addEventListener('dragend', () => (dragFrom = -1));
      box.appendChild(tab);
    });
  }
  const nodes = box.children;
  tabs.forEach((t, i) => {
    const n = nodes[i];
    if (!n) return;
    const label = t.title || t.host || '新标签页';
    const c = t.containerId && t.containerId !== 'default' ? containers.get(t.containerId) : null;
    n.classList.toggle('active', !!t.active);
    n.classList.toggle('loading', !!t.loading);
    n.classList.toggle('unloaded', !t.loaded);
    n.classList.toggle('locked', !!t.locked);
    // 容器色条（容器模块接入后有颜色）
    n.style.setProperty('--container', c && /^#[0-9a-f]{3,8}$/i.test(c.color || '') ? c.color : 'transparent');
    n.setAttribute('aria-selected', t.active ? 'true' : 'false');
    n.title = [label, t.host, c ? `容器：${c.name}${t.locked ? '（已锁定）' : ''}` : ''].filter(Boolean).join('\n');
    n.querySelector('.title').textContent = label;
    n.querySelector('.fav').textContent = (t.host || '·').charAt(0).toUpperCase();
    if (t.active && !n.dataset.shown) n.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    n.dataset.shown = t.active ? '1' : '';
  });
  document.body.classList.toggle('many', tabs.length > 12);
  $('tabCount').textContent = tabs.length > 1 ? (tabs.length > 99 ? '∞' : String(tabs.length)) : '';
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
  $('reader').hidden = !s.readerable;
  $('mio').hidden = !s.pageTools;
  shield.title = !s.adblockEnabled ? '广告拦截已关闭' : s.siteWhitelisted ? `已在 ${s.host} 停用拦截` : !s.adblockReady ? '正在准备拦截规则…' : `已拦截 ${s.blocked} 个请求`;
  renderTabs(s);
}

$('hideBrowser').onclick = () => window.mioToolbar.cmd('hide');
$('back').onclick = () => window.mioToolbar.cmd('back');
$('forward').onclick = () => window.mioToolbar.cmd('forward');
$('reload').onclick = () => window.mioToolbar.cmd(state && state.loading ? 'stop' : 'reload');
$('external').onclick = () => window.mioToolbar.cmd('openExternal');
$('translate').onclick = () => window.mioToolbar.cmd('translateMenu');
$('settings').onclick = () => window.mioToolbar.cmd('settings');
$('shield').onclick = () => window.mioToolbar.cmd('shieldMenu');
$('share').onclick = () => window.mioToolbar.cmd('share');
$('tabsBtn').onclick = () => window.mioToolbar.cmd('tabsMenu');
$('newTab').onclick = () => window.mioToolbar.cmd('newTab');
$('newTab').addEventListener('contextmenu', (e) => {
  e.preventDefault();
  window.mioToolbar.cmd('newTabMenu');
});
$('stripNew').onclick = () => window.mioToolbar.cmd('newTab');
$('stripNew').addEventListener('contextmenu', (e) => {
  e.preventDefault();
  window.mioToolbar.cmd('newTabMenu');
});
// 双击标签条空白处：新建标签页
$('tabstrip').addEventListener('dblclick', (e) => {
  if (e.target === $('tabstrip') || e.target === $('tabs')) window.mioToolbar.cmd('newTab');
});
$('mio').onclick = () => window.mioToolbar.cmd('pageMenu');
$('reader').onclick = () => window.mioToolbar.cmd('reader');

addr.addEventListener('focus', () => {
  editing = true;
  document.body.classList.add('editing');
  if (state && state.url) addr.value = state.url;
  setTimeout(() => addr.select(), 0);
});
addr.addEventListener('blur', () => {
  editing = false;
  document.body.classList.remove('editing');
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

let noticeTimer = null;
function notice(text) {
  const n = $('notice');
  n.textContent = text;
  n.classList.add('show');
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => n.classList.remove('show'), 2500);
}

window.mioToolbar.onState(render);
window.mioToolbar.onFocusAddress(() => {
  addr.focus();
  addr.select();
});
if (window.mioToolbar.onNotice) window.mioToolbar.onNotice(notice);
window.mioToolbar.state().then(render);
