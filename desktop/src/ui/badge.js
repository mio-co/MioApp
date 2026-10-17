'use strict';
const render = (s) => {
  if (!s) return;
  document.getElementById('n').textContent = s.count > 99 ? '99+' : String(s.count);
  document.documentElement.classList.toggle('dark', !!s.dark);
};
document.getElementById('b').onclick = () => window.mioBadge.click();
window.mioBadge.onState(render);
window.mioBadge.state().then(render);
