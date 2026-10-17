'use strict';
// 设置页「容器管理」：增删改名、选颜色、删除二次确认（清数据）、站点默认容器规则。全部用 DOM API 构建
(() => {
  const api = window.mioContainers;
  if (!api) return;
  const $ = (id) => document.getElementById(id);
  const mk = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  };
  let snap = null;

  const showError = (e) => {
    $('ctrError').textContent = e ? String((e && e.message) || e).replace(/^Error invoking remote method '[^']+': (Error: )?/, '') : '';
  };
  const run = async (p) => {
    showError('');
    try {
      const s = await p;
      if (s) render(s);
    } catch (e) {
      showError(e);
    }
  };

  const dot = (hex) => {
    const d = mk('span');
    d.style.cssText = `display:inline-block;width:12px;height:12px;border-radius:50%;margin-right:8px;vertical-align:middle;background:${hex}`;
    return d;
  };

  const colorSelect = (selected) => {
    const sel = mk('select');
    for (const c of snap.colors) {
      const o = mk('option', null, c.name);
      o.value = c.id;
      if (c.id === selected) o.selected = true;
      sel.appendChild(o);
    }
    return sel;
  };

  function render(s) {
    snap = s;
    const list = $('ctrList');
    list.textContent = '';
    for (const c of s.containers) {
      const row = mk('div', 'row');
      const label = mk('div', 'label');
      label.appendChild(dot(c.hex));
      if (c.isDefault) {
        label.appendChild(document.createTextNode(c.name));
        label.appendChild(mk('div', 'sub', '原来的浏览数据，不能删除'));
        row.appendChild(label);
      } else {
        const name = mk('input', 'text');
        name.value = c.name;
        name.maxLength = 32;
        name.style.width = '160px';
        name.addEventListener('change', () => run(api.update(c.id, { name: name.value })));
        label.appendChild(name);
        if (c.tabs) label.appendChild(mk('div', 'sub', `${c.tabs} 个标签`));
        row.appendChild(label);
        const sel = colorSelect(c.color);
        sel.addEventListener('change', () => run(api.update(c.id, { color: sel.value })));
        row.appendChild(sel);
        const del = mk('button', 'btn danger', '删除');
        del.onclick = () => {
          if (!confirm(`删除容器「${c.name}」？\n会关闭它的标签，并清除其中的 Cookie、登录状态、网站存储和缓存，无法恢复。`)) return;
          run(api.remove(c.id));
        };
        row.appendChild(del);
      }
      list.appendChild(row);
    }

    const cs = $('ctrColor');
    const keep = cs.value;
    cs.textContent = '';
    for (const c of s.colors) {
      const o = mk('option', null, c.name);
      o.value = c.id;
      cs.appendChild(o);
    }
    const used = new Set(s.containers.map((c) => c.color));
    cs.value = keep && s.colors.some((c) => c.id === keep) ? keep : (s.colors.find((c) => !used.has(c.id)) || s.colors[0]).id;
    const full = s.containers.length - 1 >= s.max;
    $('ctrName').disabled = full || !s.supported;
    $('ctrName').placeholder = full ? `最多 ${s.max} 个容器` : '新容器名称，如 工作 / 小号 2';

    const rc = $('ctrRuleContainer');
    rc.textContent = '';
    for (const c of s.containers.filter((x) => !x.isDefault)) {
      const o = mk('option', null, c.name);
      o.value = c.id;
      rc.appendChild(o);
    }
    $('ctrRuleForm').hidden = !rc.options.length;
    const rules = $('ctrRules');
    rules.textContent = '';
    if (!s.siteRules.length) rules.appendChild(mk('div', 'empty', rc.options.length ? '没有站点规则：新标签按打开它的标签决定容器' : '先新建一个容器'));
    for (const r of s.siteRules) {
      const c = s.containers.find((x) => x.id === r.containerId);
      const row = mk('div', 'row');
      const label = mk('div', 'label', r.host);
      label.appendChild(mk('div', 'sub', `总是在「${c ? c.name : '?'}」容器打开`));
      row.appendChild(label);
      const del = mk('button', 'btn link', '移除');
      del.onclick = () => run(api.removeSiteRule(r.host));
      row.appendChild(del);
      rules.appendChild(row);
    }
  }

  $('ctrForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const name = $('ctrName').value;
    run(api.create(name, $('ctrColor').value).then((s) => {
      $('ctrName').value = '';
      return s;
    }));
  });
  $('ctrRuleForm').addEventListener('submit', (e) => {
    e.preventDefault();
    run(api.setSiteRule($('ctrRuleHost').value, $('ctrRuleContainer').value).then((s) => {
      $('ctrRuleHost').value = '';
      return s;
    }));
  });
  api.get().then(render);
})();
