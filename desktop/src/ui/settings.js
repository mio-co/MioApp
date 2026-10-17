'use strict';
const $ = (id) => document.getElementById(id);
const api = window.mioSettings;
let snap = null;
let message = '';

const fmt = (t) => (t ? new Date(t).toLocaleString() : '—');
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};

function render(s) {
  if (!s) return;
  snap = s;
  const st = s.settings;
  const ab = s.adblock;
  $('preferSystemBrowser').checked = !!st.preferSystemBrowser;
  $('backgroundPlayback').checked = !!st.backgroundPlayback;
  renderSponsorBlock(st);
  $('adblockEnabled').checked = !!st.adblockEnabled;
  $('youtubeFocus').checked = !!st.youtubeFocus;
  $('youtubeFocusPlayables').checked = !!st.youtubeFocusPlayables;
  $('youtubeFocusPlayables').disabled = !st.youtubeFocus;
  $('youtubeFocusInterval').value = String(st.youtubeFocusInterval);
  $('youtubeFocusInterval').disabled = !st.youtubeFocus;

  const host = s.currentHost;
  $('siteRow').hidden = !host;
  if (host) {
    $('siteHost').textContent = host;
    const wl = st.whitelist.some((p) => host === p || host.endsWith('.' + p));
    $('siteEnabled').checked = !wl;
    $('siteEnabled').disabled = !st.adblockEnabled;
  }

  const lists = $('lists');
  lists.textContent = '';
  for (const l of ab.lists) {
    const row = el('div', 'row');
    const label = el('div', 'label', l.name);
    const sub = el('div', 'sub', `${l.rules.toLocaleString()} 条规则${l.version ? ` · v${l.version}` : ''}`);
    label.appendChild(sub);
    row.appendChild(label);
    row.appendChild(el('div', 'value', l.id === 0 ? '内置' : `${l.source === 'remote' ? '下载于' : '内置 ·'} ${fmt(l.downloadedAt)}`));
    lists.appendChild(row);
  }
  $('resources').textContent = ab.resources ? `${ab.resources.scriptlets} 个 scriptlets · ${ab.resources.source === 'remote' ? '下载于' : '内置 ·'} ${fmt(ab.resources.downloadedAt)}` : '—';
  const busy = ab.busy === 'building' ? '正在构建引擎…' : ab.busy === 'updating' ? '正在检查更新…' : '';
  $('engine').textContent = busy || (ab.engine
    ? `${ab.engine.networkFilters.toLocaleString()} 条网络规则 · ${ab.engine.cosmeticFilters.toLocaleString()} 条元素规则 · 构建于 ${fmt(ab.engine.builtAt)}`
    : ab.error ? `加载失败：${ab.error}` : '准备中…');
  $('engine').className = ab.error && !ab.engine ? 'sub status-err' : 'sub';
  $('lastCheck').textContent = `${fmt(ab.lastCheck)}${ab.lastResult ? ` · ${ab.lastResult}` : ''}${message ? ` · ${message}` : ''}`;
  $('updateNow').disabled = !!ab.busy;
  $('updateNow').textContent = ab.busy === 'updating' ? '正在更新…' : '立即更新';

  const wl = $('wlList');
  wl.textContent = '';
  if (!st.whitelist.length) wl.appendChild(el('div', 'empty', '没有白名单网站'));
  for (const h of st.whitelist) {
    const row = el('div', 'row');
    row.appendChild(el('div', 'label', h));
    const del = el('button', 'btn link', '移除');
    del.onclick = () => api.removeWhitelist(h).then(render);
    row.appendChild(del);
    wl.appendChild(row);
  }
  $('about').textContent = `Mio ${s.appVersion} · ${s.platform}`;
}

$('youtubeFocusInterval').addEventListener('change', (e) => api.set('youtubeFocusInterval', Number(e.target.value)).then(render));
// SponsorBlock：总开关 + 分类复选框（存成逗号分隔字符串 sponsorBlockCategories）
const SB_CATS = [['sponsor', '赞助广告'], ['selfpromo', '自我推广'], ['interaction', '互动提醒'], ['intro', '片头'], ['outro', '片尾']];
function renderSponsorBlock(st) {
  $('sponsorBlock').checked = st.sponsorBlock !== false;
  $('sbCats').hidden = st.sponsorBlock === false;
  const on = new Set(String(st.sponsorBlockCategories || '').split(','));
  const box = $('sbCatList');
  box.textContent = '';
  for (const [key, label] of SB_CATS) {
    const l = el('label', 'sb-cat');
    l.style.marginRight = '12px';
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = on.has(key);
    cb.addEventListener('change', () => {
      const next = SB_CATS.map(([k]) => k).filter((k) => (k === key ? cb.checked : on.has(k)));
      api.set('sponsorBlockCategories', next.join(',')).then(render);
    });
    l.appendChild(cb);
    l.appendChild(document.createTextNode(' ' + label));
    box.appendChild(l);
  }
}

for (const key of ['preferSystemBrowser', 'backgroundPlayback', 'adblockEnabled', 'youtubeFocus', 'youtubeFocusPlayables', 'sponsorBlock']) {
  $(key).addEventListener('change', (e) => api.set(key, e.target.checked).then(render));
}
$('siteEnabled').addEventListener('change', (e) => snap && snap.currentHost && api.setSite(snap.currentHost, e.target.checked).then(render));
$('updateNow').onclick = async () => {
  message = '';
  $('updateNow').disabled = true;
  const r = await api.updateNow();
  message = '';
  render(r);
};
$('clearData').onclick = async () => {
  if (!confirm('清除内置浏览器的 Cookie、登录状态和缓存？（不影响 MioCore 主窗口）')) return;
  await api.clearData();
  $('clearData').textContent = '已清除';
  setTimeout(() => ($('clearData').textContent = '清除浏览数据'), 2000);
};
$('wlForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  $('wlError').textContent = '';
  try {
    render(await api.addWhitelist($('wlInput').value));
    $('wlInput').value = '';
  } catch (err) {
    $('wlError').textContent = '无效的域名';
  }
});

api.onChange(render);
api.get().then(render);
