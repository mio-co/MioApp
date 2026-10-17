'use strict';
// 「跳转系统浏览器后自动关闭标签页」：当前页交给系统默认浏览器，成功（shell.openExternal resolve）且开关开启时关闭内置浏览器的当前页。
// 内置浏览器只有一个页面（一个窗口），关闭它 = 用户手动关闭（command('close') → win.close()），主窗口不受影响，App 不退出。
// 打开失败（reject）不关闭。纯逻辑，openExternal / close 由调用方注入，便于单测。

const SETTING_KEY = 'closeTabAfterExternal';

/**
 * @param {{ url: string, enabled: boolean, openExternal: (url: string) => Promise<unknown>, close: () => void }} o
 * @returns {Promise<{ opened: boolean, closed: boolean }>}
 */
async function openExternalThenMaybeClose({ url, enabled, openExternal, close }) {
  try {
    await openExternal(url);
  } catch {
    return { opened: false, closed: false };
  }
  if (!enabled) return { opened: true, closed: false };
  close();
  return { opened: true, closed: true };
}

module.exports = { SETTING_KEY, openExternalThenMaybeClose };
