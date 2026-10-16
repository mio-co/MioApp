'use strict';
// utilityProcess 入口：主进程发 { id, lists, resources }，这里构建 + 序列化引擎，回 { id, bytes, stats } / { id, error }
const { buildEngine } = require('./adblock-engine');

process.parentPort.on('message', (e) => {
  const { id, lists, resources } = e.data || {};
  try {
    const { bytes, stats } = buildEngine(lists, resources);
    process.parentPort.postMessage({ id, bytes, stats });
  } catch (err) {
    process.parentPort.postMessage({ id, error: String((err && err.stack) || err) });
  }
});
