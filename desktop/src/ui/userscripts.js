'use strict';
// 用户脚本管理窗口（DOM API 构建，不用 innerHTML）
const $ = (id) => document.getElementById(id);
const api = window.mioUserScripts;

const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};

function message(text, ok) {
  const m = $('message');
  m.textContent = text || '';
  m.className = `note ${ok === false ? 'status-err' : ok ? 'status-ok' : ''}`;
}

function done(r, okText) {
  if (!r) return;
  render(r.list);
  if (!r.ok) message(r.error, false);
  else if (typeof r.result === 'string' && r.result) message(okText ? okText(r.result) : r.result, true);
  return r;
}

function render(list) {
  const box = $('list');
  box.textContent = '';
  if (!list || !list.length) {
    box.appendChild(el('div', 'empty', '还没有安装用户脚本'));
    return;
  }
  for (const s of list) {
    const row = el('div', 'row');
    const label = el('div', 'label');
    label.appendChild(el('div', '', `${s.name}${s.version ? '  v' + s.version : ''}`));
    const sub = [];
    if (s.description) sub.push(s.description);
    sub.push(`运行于：${s.matches.length ? s.matches.slice(0, 4).join('、') + (s.matches.length > 4 ? ' …' : '') : '所有网页'}`);
    if (s.grants.length && !s.grants.includes('none')) sub.push(`权限：${s.grants.join('、')}`);
    const dec = Object.entries(s.decisions || {});
    if (dec.length) sub.push(`跨域授权：${dec.map(([h, a]) => `${h}${a ? '✓' : '✗'}`).join('、')}`);
    if (s.invalid.length) sub.push(`⚠️ 忽略无效规则：${s.invalid.join('、')}`);
    for (const t of sub) label.appendChild(el('div', 'sub', t));
    row.appendChild(label);

    const actions = el('div', '');
    actions.style.cssText = 'display:flex;gap:4px;flex-wrap:wrap;justify-content:flex-end;max-width:46%';
    const view = el('button', 'btn', '代码');
    view.onclick = async () => {
      const r = await api.code(s.id);
      if (!r || !r.ok) return;
      $('codeTitle').textContent = s.name;
      $('codeText').textContent = r.result || '';
      $('codeView').hidden = false;
      $('codeView').scrollIntoView();
    };
    actions.appendChild(view);
    if (s.canUpdate) {
      const up = el('button', 'btn', '更新');
      up.onclick = async () => {
        up.disabled = true;
        message('正在检查更新…');
        done(await api.checkUpdate(s.id));
        up.disabled = false;
      };
      actions.appendChild(up);
    }
    if (dec.length) {
      const rc = el('button', 'btn', '重置授权');
      rc.onclick = async () => done(await api.resetConnect(s.id));
      actions.appendChild(rc);
    }
    const del = el('button', 'btn danger', '删除');
    del.onclick = async () => {
      if (!confirm(`删除「${s.name}」及其保存的数据？`)) return;
      done(await api.remove(s.id));
    };
    actions.appendChild(del);
    row.appendChild(actions);

    const sw = el('label', 'switch');
    const cb = el('input');
    cb.type = 'checkbox';
    cb.checked = !!s.enabled;
    cb.onchange = async () => done(await api.enable(s.id, cb.checked));
    sw.appendChild(cb);
    sw.appendChild(el('span'));
    row.appendChild(sw);
    box.appendChild(row);
  }
}

const installed = (name) => `已安装「${name}」，对之后打开 / 刷新的页面生效`;

$('urlForm').onsubmit = async (e) => {
  e.preventDefault();
  const u = $('urlInput').value.trim();
  if (!u) return;
  message('正在下载…');
  const r = done(await api.installUrl(u), installed);
  if (r && r.ok && r.result) $('urlInput').value = '';
  else if (r && r.ok) message('');
};
$('pasteToggle').onclick = () => { $('pasteRow').hidden = !$('pasteRow').hidden; };
$('installCode').onclick = async () => {
  const code = $('codeInput').value;
  if (!code.trim()) return;
  const r = done(await api.installCode(code), installed);
  if (r && r.ok && r.result) { $('codeInput').value = ''; $('pasteRow').hidden = true; }
};
$('installFile').onclick = async () => done(await api.installFile(), installed);
$('checkAll').onclick = async () => {
  $('checkAll').disabled = true;
  message('正在检查更新…');
  done(await api.checkAll());
  $('checkAll').disabled = false;
};
$('codeClose').onclick = () => { $('codeView').hidden = true; };

api.onChange(render);
api.list().then((r) => r && render(r.list));
