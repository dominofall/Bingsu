// 순수 브라우저 코드 + localStorage
(() => {
  const log = (name, ok, extra) => {
    const d = document.createElement('div'); d.className = ok ? 'ok' : 'fail';
    d.textContent = (ok ? 'OK ' : 'FAIL ') + name + (extra ? ' · ' + extra : '');
    document.getElementById('log').appendChild(d);
    console.warn('[fixture] ' + d.textContent);
  };
  const runs = Number(localStorage.getItem('runs') || 0) + 1;
  localStorage.setItem('runs', String(runs));
  document.getElementById('runs').textContent = runs;
  log('localStorage', true, 'runs=' + runs);
  log('no node', typeof require === 'undefined');
  const size = () => { document.getElementById('size').textContent = innerWidth + '×' + innerHeight; };
  size(); addEventListener('resize', size);
  log('layout 800x600', innerWidth === 800 && innerHeight === 600, innerWidth + 'x' + innerHeight);
  const me = document.getElementById('me');
  let x = Number(localStorage.getItem('x') || 380), y = Number(localStorage.getItem('y') || 280), steps = 0;
  const draw = () => { me.style.left = x + 'px'; me.style.top = y + 'px'; localStorage.setItem('x', x); localStorage.setItem('y', y); };
  draw();
  addEventListener('keydown', (e) => {
    const d = { ArrowLeft: [-20, 0], ArrowRight: [20, 0], ArrowUp: [0, -20], ArrowDown: [0, 20] }[e.key];
    if (!d) return;
    x = Math.max(0, Math.min(innerWidth - 40, x + d[0])); y = Math.max(0, Math.min(innerHeight - 40, y + d[1]));
    document.getElementById('steps').textContent = ++steps; draw();
  });
  addEventListener('pointerdown', (e) => { x = Math.round(e.clientX - 20); y = Math.round(e.clientY - 20); draw(); console.warn('[fixture] tap ' + Math.round(e.clientX) + ',' + Math.round(e.clientY)); });
})();
