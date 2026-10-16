'use strict';
// 用过滤列表文本 + uBO resources.json 构建 Ghostery 引擎并序列化（在 utilityProcess 里跑，不卡主进程；测试里直接调用）
const { FiltersEngine } = require('@ghostery/adblocker');

// 序列化格式随 Ghostery 版本变：缓存的 engine.bin 用这个 key 判定是否可用
const ENGINE_FORMAT = `ghostery-${require('@ghostery/adblocker/package.json').version}-mio1`;

const ENGINE_CONFIG = {
  loadNetworkFilters: true,
  loadCosmeticFilters: true,
  loadGenericCosmeticsFilters: true,
  loadExtendedSelectors: true,
  loadCSPFilters: true,
  loadExceptionFilters: true,
  enableMutationObserver: true,
  enableCompression: false,
  enableHtmlFiltering: false,
};

/** @returns {{ bytes: Uint8Array, stats: object }} */
function buildEngine(listTexts, resourcesText) {
  const t0 = Date.now();
  const engine = FiltersEngine.parse(listTexts.join('\n'), ENGINE_CONFIG);
  let scriptlets = 0;
  if (resourcesText) {
    engine.updateResources(resourcesText, String(resourcesText.length));
    try {
      scriptlets = JSON.parse(resourcesText).scriptlets.length;
    } catch {
      scriptlets = 0;
    }
  }
  const bytes = engine.serialize();
  const filters = engine.getFilters();
  return {
    bytes,
    stats: {
      networkFilters: filters.networkFilters.length,
      cosmeticFilters: filters.cosmeticFilters.length,
      scriptlets,
      buildMs: Date.now() - t0,
      bytes: bytes.length,
    },
  };
}

module.exports = { buildEngine, ENGINE_FORMAT, ENGINE_CONFIG };
