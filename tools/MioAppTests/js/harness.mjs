// 从 ios/App/App/MioWebCompat.swift 抽出注入页面的 JS（MIO_JS_BEGIN/END 段里的 #"""…"""# 原样字符串），
// 在一个最小的假 DOM 里运行（不依赖 jsdom，node --test 直接跑）。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const SWIFT = fileURLToPath(new URL('../../../ios/App/App/MioWebCompat.swift', import.meta.url));

export function extractScript(name) {
  const src = readFileSync(SWIFT, 'utf8');
  const begin = src.indexOf(`// MIO_JS_BEGIN ${name}`);
  const end = src.indexOf(`// MIO_JS_END ${name}`);
  if (begin < 0 || end < 0) throw new Error(`script ${name} not found`);
  const block = src.slice(begin, end);
  const open = block.indexOf('#"""');
  const close = block.lastIndexOf('"""#');
  const body = block.slice(block.indexOf('\n', open) + 1, close);
  // Swift 多行字符串按结束分隔符的缩进去掉前导空白
  const indent = /\n([ \t]*)$/.exec(body)?.[1] ?? '';
  return body.split('\n').map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l)).join('\n');
}

class FakeEvent {
  constructor(type, init = {}) {
    Object.assign(this, { bubbles: false, key: '', code: '', keyCode: 0, which: 0, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, isComposing: false }, init);
    this.type = type;
    this.defaultPrevented = false;
  }
  preventDefault() { this.defaultPrevented = true; }
}

export function makeTextarea(value = '') {
  const el = {
    nodeType: 1, tagName: 'TEXTAREA', value, readOnly: false, disabled: false,
    selectionStart: value.length, selectionEnd: value.length,
    contains(n) { return n === el; },
    setRangeText(text, start, end) {
      el.value = el.value.slice(0, start) + text + el.value.slice(end);
      el.selectionStart = el.selectionEnd = start + text.length;
      el.rangeTextCalls = (el.rangeTextCalls || 0) + 1;
    },
    dispatched: [],
    dispatchEvent(e) { el.dispatched.push(e); return true; },
  };
  return el;
}

export function makeEditable(html = '<p>hi</p>') {
  const child = { nodeType: 1, tagName: 'SPAN' };
  const el = {
    nodeType: 1, tagName: 'DIV', isContentEditable: true, innerHTML: html, child,
    contains(n) { return n === el || n === child; },
    dispatchEvent() { return true; },
  };
  return el;
}

/// 返回 { window, document, run(), keydown(), …, flush() }
export function makeEnv({ execResult = true } = {}) {
  const listeners = {};
  const timers = new Map();
  let nextTimer = 1;
  const logs = [];
  const exec = [];
  const document = {
    activeElement: null,
    addEventListener(type, fn, capture) { (listeners[type] ||= []).push({ fn, capture }); },
    execCommand(cmd, ui, arg) {
      exec.push([cmd, arg]);
      if (!execResult) return false;
      const el = document.activeElement;
      if (cmd === 'insertText' && el && 'value' in el) el.value += arg;
      if (cmd !== 'insertText' && el && 'innerHTML' in el) el.innerHTML += cmd === 'insertLineBreak' ? '<br>' : '<p></p>';
      return true;
    },
    createEvent() { return { initEvent(t) { this.type = t; } }; },
  };
  const window = { document };
  const context = vm.createContext({
    window, document, navigator: {},
    console: { info: (m) => logs.push(m), log: () => {} },
    setTimeout: (fn) => { const id = nextTimer++; timers.set(id, fn); return id; },
    clearTimeout: (id) => { timers.delete(id); },
    InputEvent: class InputEvent extends FakeEvent { constructor(t, i) { super(t, i); } },
    Object, String, Math, JSON, Array,
  });
  const env = {
    window, document, exec, logs, listeners,
    run(script) { vm.runInContext(script, context); },
    /// 先跑捕获阶段（我们的监听器），再跑页面自己的处理（pageHandler）
    fire(type, target, init = {}, pageHandler) {
      const e = new FakeEvent(type, init);
      e.target = target;
      for (const l of listeners[type] || []) l.fn(e);
      if (pageHandler) pageHandler(e);
      return e;
    },
    keydown(target, init = {}, pageHandler) {
      return env.fire('keydown', target, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, ...init }, pageHandler);
    },
    flush() { const fns = [...timers.values()]; timers.clear(); fns.forEach((f) => f()); },
    pendingTimers() { return timers.size; },
  };
  return env;
}
