// Mac Catalyst 回车键兜底脚本（MioWebCompat.returnKeyFixScript）
import test from 'node:test';
import assert from 'node:assert/strict';
import { extractScript, makeEnv, makeTextarea, makeEditable } from './harness.mjs';

const SCRIPT = extractScript('returnKeyFix');

function setup(opts) {
  const env = makeEnv(opts);
  env.run(SCRIPT);
  return env;
}

test('decide(): pure decision table', () => {
  const env = setup();
  const d = env.window.__mioReturnKeyFix.decide;
  assert.equal(d({ kind: 'textarea' }), 'insertText');
  assert.equal(d({ kind: 'textarea', shift: true }), 'insertText');
  assert.equal(d({ kind: 'contenteditable' }), 'insertParagraph');
  assert.equal(d({ kind: 'contenteditable', shift: true }), 'insertLineBreak');
  assert.equal(d({ kind: 'textarea', composing: true }), null);
  assert.equal(d({ kind: 'textarea', defaultPrevented: true }), null);
  assert.equal(d({ kind: 'textarea', handled: true }), null);
  assert.equal(d({ kind: 'textarea', meta: true }), null);
  assert.equal(d({ kind: 'textarea', ctrl: true }), null);
  assert.equal(d({ kind: 'textarea', alt: true }), null);
  assert.equal(d({ kind: null }), null);
});

test('native path broken: Enter in textarea inserts exactly one newline', () => {
  const env = setup();
  const ta = makeTextarea('abc');
  env.document.activeElement = ta;
  env.keydown(ta);
  assert.equal(env.exec.length, 0, 'must wait for the native insertion window');
  env.flush();
  assert.deepEqual(env.exec, [['insertText', '\n']]);
  assert.equal(ta.value, 'abc\n');
  assert.equal(env.window.__mioReturnKeyFix.count, 1);
});

test('native path broken: Shift+Enter in textarea inserts a newline', () => {
  const env = setup();
  const ta = makeTextarea('x');
  env.document.activeElement = ta;
  env.keydown(ta, { shiftKey: true });
  env.flush();
  assert.deepEqual(env.exec, [['insertText', '\n']]);
});

test('native path works (beforeinput/input fired): no double newline', () => {
  const env = setup();
  const ta = makeTextarea('abc');
  env.document.activeElement = ta;
  env.keydown(ta);
  env.fire('beforeinput', ta, { inputType: 'insertLineBreak' });
  ta.value += '\n';
  env.fire('input', ta, { inputType: 'insertLineBreak' });
  env.flush();
  assert.deepEqual(env.exec, []);
  assert.equal(ta.value, 'abc\n');
});

test('native path works without input events but value changed: no double newline', () => {
  const env = setup();
  const ta = makeTextarea('abc');
  env.document.activeElement = ta;
  env.keydown(ta);
  ta.value += '\n';
  env.flush();
  assert.deepEqual(env.exec, []);
});

test('page handles Enter itself (preventDefault on keydown, e.g. send on Enter): untouched', () => {
  const env = setup();
  const ta = makeTextarea('msg');
  env.document.activeElement = ta;
  env.keydown(ta, {}, (e) => { if (!e.shiftKey) e.preventDefault(); });
  env.flush();
  assert.deepEqual(env.exec, []);
  // …but Shift+Enter on the same page is not prevented → newline like Safari
  env.keydown(ta, { shiftKey: true }, (e) => { if (!e.shiftKey) e.preventDefault(); });
  env.flush();
  assert.deepEqual(env.exec, [['insertText', '\n']]);
});

test('page prevents keypress instead of keydown: untouched', () => {
  const env = setup();
  const ta = makeTextarea();
  env.document.activeElement = ta;
  env.keydown(ta);
  env.fire('keypress', ta, { key: 'Enter', keyCode: 13, which: 13 }, (e) => e.preventDefault());
  env.flush();
  assert.deepEqual(env.exec, []);
});

test('page cancels beforeinput: untouched', () => {
  const env = setup();
  const ta = makeTextarea();
  env.document.activeElement = ta;
  env.keydown(ta);
  env.fire('beforeinput', ta, { inputType: 'insertLineBreak' }, (e) => e.preventDefault());
  env.flush();
  assert.deepEqual(env.exec, []);
});

test('IME composition (isComposing / keyCode 229 / compositionend): untouched', () => {
  const env = setup();
  const ta = makeTextarea('ni');
  env.document.activeElement = ta;
  env.keydown(ta, { isComposing: true });
  env.flush();
  env.keydown(ta, { keyCode: 229 });
  env.flush();
  env.fire('compositionstart', ta);
  env.keydown(ta);
  env.flush();
  env.keydown(ta);
  env.fire('compositionend', ta);
  env.flush();
  assert.deepEqual(env.exec, []);
  // after composition finished, a plain Enter works again
  env.keydown(ta);
  env.flush();
  assert.deepEqual(env.exec, [['insertText', '\n']]);
});

test('modifier combos (Cmd/Ctrl/Alt+Enter) are left to the page / system', () => {
  const env = setup();
  const ta = makeTextarea();
  env.document.activeElement = ta;
  for (const m of [{ metaKey: true }, { ctrlKey: true }, { altKey: true }]) { env.keydown(ta, m); env.flush(); }
  assert.deepEqual(env.exec, []);
});

test('contenteditable: Enter → insertParagraph, Shift+Enter → insertLineBreak (Safari default)', () => {
  const env = setup();
  const ed = makeEditable();
  env.document.activeElement = ed;
  env.keydown(ed);
  env.flush();
  env.keydown(ed, { shiftKey: true });
  env.flush();
  assert.deepEqual(env.exec, [['insertParagraph', null], ['insertLineBreak', null]]);
});

test('contenteditable: input event from a child node counts as handled', () => {
  const env = setup();
  const ed = makeEditable();
  env.document.activeElement = ed;
  env.keydown(ed);
  env.fire('input', ed.child, { inputType: 'insertParagraph' });
  env.flush();
  assert.deepEqual(env.exec, []);
});

test('focus moved away before settle (page submitted / closed editor): untouched', () => {
  const env = setup();
  const ta = makeTextarea();
  env.document.activeElement = ta;
  env.keydown(ta);
  env.document.activeElement = null;
  env.flush();
  assert.deepEqual(env.exec, []);
});

test('non-editable targets (input, readonly/disabled textarea, button) are ignored', () => {
  const env = setup();
  const input = { nodeType: 1, tagName: 'INPUT', contains: (n) => n === input };
  const ro = makeTextarea(); ro.readOnly = true;
  const dis = makeTextarea(); dis.disabled = true;
  for (const t of [input, ro, dis]) { env.document.activeElement = t; env.keydown(t); env.flush(); }
  assert.equal(env.pendingTimers(), 0);
  assert.deepEqual(env.exec, []);
});

test('key repeat with broken native path: each keydown resolves the previous one', () => {
  const env = setup();
  const ta = makeTextarea();
  env.document.activeElement = ta;
  env.keydown(ta);
  env.keydown(ta);   // resolves #1 immediately
  env.keydown(ta);   // resolves #2
  env.flush();       // resolves #3
  assert.equal(env.exec.length, 3);
  assert.equal(ta.value, '\n\n\n');
});

test('non-Enter keys are ignored and do not leave pending state', () => {
  const env = setup();
  const ta = makeTextarea();
  env.document.activeElement = ta;
  env.fire('keydown', ta, { key: 'a', code: 'KeyA', keyCode: 65 });
  assert.equal(env.pendingTimers(), 0);
});

test('execCommand unavailable: textarea falls back to setRangeText + input event', () => {
  const env = setup({ execResult: false });
  const ta = makeTextarea('ab');
  ta.selectionStart = ta.selectionEnd = 1;
  env.document.activeElement = ta;
  env.keydown(ta);
  env.flush();
  assert.equal(ta.value, 'a\nb');
  assert.equal(ta.rangeTextCalls, 1);
  assert.equal(ta.dispatched.length, 1);
  assert.equal(ta.dispatched[0].type, 'input');
});

test('installing twice registers listeners once', () => {
  const env = setup();
  env.run(SCRIPT);
  assert.equal(env.listeners.keydown.length, 1);
});
