'use strict';
// Mio 桌面壳常量（Windows / macOS Electron）

const SITE_ORIGIN = 'https://mio.300031.xyz';

module.exports = {
  SITE_ORIGIN,
  SITE_HOST: new URL(SITE_ORIGIN).hostname,
  START_URL: new URL('/mio/nav', SITE_ORIGIN).toString(),
  // 主窗口内允许直接跳转的站点（Cloudflare Access 登录、Google / GitHub 身份提供方），其余站外地址交给内置浏览器
  MAIN_ALLOWED_HOSTS: ['mio.300031.xyz', '*.cloudflareaccess.com', 'accounts.google.com', 'github.com'],
  MAIN_PARTITION: 'persist:mio',
  BROWSER_PARTITION: 'persist:mio-browser',
  SEARCH_URL: 'https://www.google.com/search?q=',
  UPDATE_INTERVAL_MS: 24 * 3600 * 1000,
  // 与 iOS / Android 相同的 AdGuard 列表；用 AdGuard 官方的 uBlock Origin 语法版本（Ghostery 引擎解析 ##+js() scriptlets）
  FILTER_LISTS: [
    { id: 2, name: 'AdGuard Base', url: 'https://filters.adtidy.org/extension/ublock/filters/2.txt' },
    { id: 11, name: 'AdGuard 移动广告', url: 'https://filters.adtidy.org/extension/ublock/filters/11.txt' },
    { id: 3, name: 'AdGuard 跟踪保护', url: 'https://filters.adtidy.org/extension/ublock/filters/3.txt' },
    { id: 101, name: 'EasyList', url: 'https://filters.adtidy.org/extension/ublock/filters/101.txt' },
    { id: 118, name: 'EasyPrivacy', url: 'https://filters.adtidy.org/extension/ublock/filters/118.txt' },
    { id: 224, name: 'AdGuard 中文', url: 'https://filters.adtidy.org/extension/ublock/filters/224.txt' },
  ],
  // App 自带（不远程更新）：Mio YouTube 补充规则
  BUILTIN_LIST: { id: 0, name: 'Mio YouTube 补充' },
  // uBlock Origin scriptlets / redirect 资源（Ghostery 维护的同步副本）
  RESOURCES_URL: 'https://raw.githubusercontent.com/ghostery/adblocker/master/packages/adblocker/assets/ublock-origin/resources.json',
};
