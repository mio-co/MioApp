'use strict';
const q = new URLSearchParams(location.search);
const url = q.get('url') || 'https://mio.300031.xyz/mio/nav';
const safe = /^https:\/\/mio\.300031\.xyz\//.test(url) ? url : 'https://mio.300031.xyz/mio/nav';
document.getElementById('detail').textContent = `请检查网络连接后重试。（${q.get('desc') || '加载失败'} ${q.get('code') || ''}）`;
document.getElementById('retry').onclick = () => {
  location.href = safe;
};
window.addEventListener('online', () => {
  location.href = safe;
});
