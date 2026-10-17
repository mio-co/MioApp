'use strict';
const $ = (id) => document.getElementById(id);
const api = window.mioTranslateSettings;

const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};

function fillSelect(sel, pairs, value) {
  if (sel.options.length !== pairs.length) {
    sel.textContent = '';
    for (const [v, label] of pairs) {
      const o = el('option', '', label);
      o.value = v;
      sel.appendChild(o);
    }
  }
  sel.value = value;
}

function setIfIdle(input, value) {
  if (document.activeElement !== input) input.value = value || '';
}

function render(s) {
  if (!s) return;
  const st = s.settings;
  fillSelect($('target'), s.langs, st.target);
  fillSelect($('engine'), s.engines, st.engine);
  $('display').value = st.display;
  $('selection').checked = !!st.selection;
  $('youtube').checked = !!st.youtube;
  $('aiCard').hidden = st.engine !== 'openai';
  setIfIdle($('openaiBase'), st.openaiBase);
  setIfIdle($('openaiModel'), st.openaiModel);
  setIfIdle($('openaiPrompt'), st.openaiPrompt);
  $('keyState').textContent = st.hasKey ? (s.encryption ? '已保存（系统加密）' : '已保存（本机未提供加密，仅编码保存）') : '未设置';
  $('cacheSize').textContent = `${s.cacheSize} 条`;
  const list = $('siteList');
  list.textContent = '';
  if (!st.autoSites.length) list.appendChild(el('div', 'empty', '没有自动翻译的网站（可在工具栏「译」菜单里勾选「总是翻译」）'));
  for (const h of st.autoSites) {
    const row = el('div', 'row');
    row.appendChild(el('div', 'label', h));
    const del = el('button', 'btn link', '移除');
    del.onclick = () => api.site(h, false).then(render);
    row.appendChild(del);
    list.appendChild(row);
  }
}

const cleanError = (e) => String((e && e.message) || e).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
const set = (key, value) => api.set(key, value).then(render).catch((e) => alert(cleanError(e)));
$('target').onchange = (e) => set('target', e.target.value);
$('engine').onchange = (e) => set('engine', e.target.value);
$('display').onchange = (e) => set('display', e.target.value);
$('selection').onchange = (e) => set('selection', e.target.checked);
$('youtube').onchange = (e) => set('youtube', e.target.checked);
$('openaiBase').onchange = (e) => set('openaiBase', e.target.value.trim());
$('openaiModel').onchange = (e) => set('openaiModel', e.target.value.trim());
$('openaiPrompt').onchange = (e) => set('openaiPrompt', e.target.value);
$('saveKey').onclick = () => {
  const v = $('openaiKey').value.trim();
  api.setKey(v).then((s) => {
    $('openaiKey').value = '';
    render(s);
  });
};
$('test').onclick = () => {
  $('testResult').textContent = '测试中…';
  api.test().then((r) => {
    $('testResult').textContent = r ? `${r.ok ? '✅' : '⚠️'} ${r.message}` : '';
  });
};
$('clearCache').onclick = () => api.clearCache().then(render);
$('siteForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const v = $('siteInput').value.trim();
  if (!v) return;
  api.site(v, true).then((s) => {
    $('siteInput').value = '';
    $('siteError').textContent = '';
    render(s);
  }).catch((err) => {
    $('siteError').textContent = cleanError(err);
  });
});

api.onChange(render);
api.get().then(render);
