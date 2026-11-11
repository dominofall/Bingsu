// 빙수 시험 터치: 칸마다 받은 이벤트를 화면과 console.warn("[fixture] …") 으로 남긴다.
// 같은 화면을 맥의 Chrome·Safari 에서 열어 PC 의 정답(이벤트 순서, detail)을 본다. 명세 IMPLEMENTATION-touch.md §11.
(() => {
  const $ = (id) => document.getElementById(id);
  const logs = {};
  const log = (cell, text) => {
    const pre = document.querySelector('#c' + cell + ' .log');
    const lines = (logs[cell] = logs[cell] || []);
    lines.push(text);
    while (lines.length > 4) lines.shift();
    if (pre) pre.textContent = lines.join('\n');
    console.warn('[fixture] c' + cell + ' ' + text);
  };
  $('clear').addEventListener('click', () => {
    for (const k of Object.keys(logs)) { logs[k] = []; const pre = document.querySelector('#c' + k + ' .log'); if (pre) pre.textContent = ''; }
  });

  // 위쪽 줄: 터치 기기로 보이는가 (§2.5), 레이아웃 크기
  const env = () => {
    const mm = (q) => { try { return matchMedia(q).matches ? 'y' : 'n'; } catch (e) { return '?'; } };
    $('env').textContent = innerWidth + '×' + innerHeight + ' · ontouchstart in window=' + ('ontouchstart' in window)
      + ' docEl=' + ('ontouchstart' in document.documentElement) + ' maxTouchPoints=' + navigator.maxTouchPoints
      + ' mm(hover:hover)=' + mm('(hover: hover)') + ' mm(pointer:coarse)=' + mm('(pointer: coarse)')
      + ' TouchEvent=' + (typeof window.TouchEvent);
  };
  env();
  addEventListener('resize', env);
  console.warn('[fixture] env ' + $('env').textContent);

  // 이벤트 순서 기록: 한 동작(마지막 이벤트 뒤 0.7초 조용하면 끝)의 순서를 한 줄로
  const short = { pointerover: 'pov', pointerenter: 'pen', pointerdown: 'pd', pointermove: 'pm', pointerup: 'pu', pointercancel: 'pc',
    pointerout: 'pout', pointerleave: 'ple', touchstart: 'ts', touchmove: 'tm', touchend: 'te', touchcancel: 'tc',
    mouseover: 'mov', mouseenter: 'men', mousemove: 'mm', mousedown: 'md', mouseup: 'mu', mouseout: 'mout', mouseleave: 'mle',
    click: 'C', dblclick: 'DC', contextmenu: 'CM', wheel: 'W', gotpointercapture: 'gpc', lostpointercapture: 'lpc' };
  const order = (el, cell, types) => {
    let seq = [], timer = 0, lastMove = '';
    for (const t of types) el.addEventListener(t, (e) => {
      let s = short[t] || t;
      if (e.pointerType) s += ':' + e.pointerType[0];
      if (!e.isTrusted) s += '*';
      if (t === 'click' || t === 'mousedown' || t === 'mouseup' || t === 'dblclick') s += '(' + e.detail + (e.button ? ',b' + e.button : '') + ')';
      if (t === 'pointermove' || t === 'mousemove') { if (lastMove === s) return; lastMove = s; } else lastMove = '';
      seq.push(s);
      clearTimeout(timer);
      timer = setTimeout(() => { log(cell, seq.join(' ')); seq = []; lastMove = ''; }, 700);
    }, { capture: true, passive: true });
  };
  const ALL = Object.keys(short).filter((t) => t !== 'wheel');

  // 1 click 횟수 + 전체 순서
  let n1 = 0;
  $('b1').addEventListener('click', () => { $('n1').textContent = ++n1; });
  order($('b1'), 1, ALL);

  // 2 mouseenter 에서 화면을 바꾸는 단추 (WebKit 의 첫 탭 버릇)
  let n2 = 0;
  $('b2').addEventListener('mouseenter', () => { $('b2info').style.visibility = 'visible'; });
  $('b2').addEventListener('mouseleave', () => { $('b2info').style.visibility = 'hidden'; });
  $('b2').addEventListener('click', () => { $('n2').textContent = ++n2; log(2, 'click ' + n2); });

  // 3 설명 창: enter/leave 하나, over/out 위임 하나
  const pop3 = $('pop3');
  $('tip3').addEventListener('mouseenter', () => { pop3.textContent = '특성 설명'; pop3.style.display = 'block'; log(3, 'enter'); });
  $('tip3').addEventListener('mouseleave', () => { pop3.style.display = 'none'; log(3, 'leave'); });
  $('dlg3').addEventListener('mouseover', (e) => {
    const c = e.target.closest('[data-i]'); if (!c) return;
    pop3.textContent = '위임 ' + c.dataset.i; pop3.style.display = 'block';
    log(3, 'over ' + c.dataset.i + (e.relatedTarget ? ' from ' + (e.relatedTarget.dataset.i || e.relatedTarget.tagName) : ''));
  });
  $('dlg3').addEventListener('mouseout', (e) => {
    const c = e.target.closest('[data-i]'); if (!c) return;
    if (e.relatedTarget && c.contains(e.relatedTarget)) return;
    pop3.style.display = 'none'; log(3, 'out ' + c.dataset.i);
  });

  // 4 :hover 메뉴 안쪽 항목 click, 늦게 더해진 <style>
  for (const id of ['b4', 'm4a', 'm4b']) $(id).addEventListener('click', () => log(4, 'click ' + id));
  // 가리킨 순간의 계산된 모양을 적는다 (손가락을 누른 채로는 화면을 볼 수 없어서)
  for (const id of ['b4', 'menu4', 'hh4', 'late4']) $(id).addEventListener('mouseenter', () => requestAnimationFrame(() => {
    const el = $(id), cs = getComputedStyle(el);
    const sub = el.querySelector('.sub');
    log(4, id + ' bg=' + cs.backgroundColor + ' outline=' + cs.outlineStyle + (sub ? ' sub=' + getComputedStyle(sub).display : ''));
  }));
  setTimeout(() => {
    const s = document.createElement('style');
    s.textContent = '.late:hover { background: #c4c; }';
    document.head.appendChild(s);
    log(4, 'late style added');
  }, 1500);

  // 5 스크립트로 넣는 title
  $('dyn5').title = '스크립트가 넣은 설명';

  // 6 mousedown·mousemove·mouseup 만으로 만든 끌기
  (() => {
    const box = $('box6'); let drag = null, moves = 0;
    box.addEventListener('mousedown', (e) => { drag = { x: e.clientX - box.offsetLeft, y: e.clientY - box.offsetTop }; moves = 0; log(6, 'down b=' + e.button + ' bs=' + e.buttons); });
    document.addEventListener('mousemove', (e) => {
      if (!drag) return; moves++;
      box.style.left = Math.max(0, Math.min(250, e.clientX - drag.x)) + 'px';
      box.style.top = Math.max(0, Math.min(30, e.clientY - drag.y)) + 'px';
    });
    document.addEventListener('mouseup', () => { if (drag) log(6, 'up moves=' + moves + ' at ' + box.style.left); drag = null; });
    box.addEventListener('click', () => log(6, 'click'));
  })();

  // 7 포인터 이벤트 + setPointerCapture (운빨던전 방식), touch-action: none
  (() => {
    const box = $('box7'); let drag = null, moves = 0;
    box.addEventListener('pointerdown', (e) => { box.setPointerCapture(e.pointerId); drag = { x: e.clientX - box.offsetLeft, y: e.clientY - box.offsetTop }; moves = 0; log(7, 'pd ' + e.pointerType); });
    box.addEventListener('pointermove', (e) => {
      if (!drag) return; moves++;
      box.style.left = Math.max(0, Math.min(250, e.clientX - drag.x)) + 'px';
      box.style.top = Math.max(0, Math.min(30, e.clientY - drag.y)) + 'px';
    });
    box.addEventListener('pointerup', () => { log(7, 'pu moves=' + moves + ' at ' + box.style.left); drag = null; });
    box.addEventListener('pointercancel', () => { log(7, 'pointercancel'); drag = null; });
    box.addEventListener('click', () => log(7, 'click'));
    box.addEventListener('mousedown', (e) => log(7, 'mousedown' + (e.isTrusted ? '' : '*')));
  })();

  // 8 dblclick, detail
  let n8 = 0;
  $('b8').addEventListener('click', (e) => log(8, 'click detail=' + e.detail));
  $('b8').addEventListener('dblclick', (e) => { $('n8').textContent = ++n8; log(8, 'dblclick detail=' + e.detail); });
  $('b8').addEventListener('mousedown', (e) => log(8, 'down detail=' + e.detail));

  // 9 진짜 마우스·트랙패드: contextmenu, mousedown 의 button, wheel (손가락으로는 만들지 않는다, 명세 §13)
  const a9 = $('area9');
  a9.addEventListener('contextmenu', (e) => { e.preventDefault(); log(9, 'contextmenu b=' + e.button + ' at ' + Math.round(e.offsetX) + ',' + Math.round(e.offsetY)); });
  a9.addEventListener('mousedown', (e) => { if (e.button) log(9, 'down b=' + e.button + ' bs=' + e.buttons); });
  let w10 = 0, wlog = 0;
  a9.addEventListener('wheel', (e) => {
    e.preventDefault(); w10 += e.deltaY; $('w10').textContent = Math.round(w10);
    if (wlog++ % 10 === 0) log(9, 'wheel dy=' + e.deltaY.toFixed(1) + ' mode=' + e.deltaMode);
  }, { passive: false });
  const list = $('list10');
  for (let i = 1; i <= 40; i++) { const d = document.createElement('div'); d.textContent = '목록 ' + i; list.appendChild(d); }
  let st = 0;
  list.addEventListener('scroll', () => { if (Math.abs(list.scrollTop - st) > 30) { st = list.scrollTop; log(9, 'scrollTop=' + Math.round(st)); } });

  // 10 양손 번갈아 빨리 누르기 (§2.1 두 번째 손가락): 누른 수와 click 수가 같아야 한다
  let l10 = 0, r10 = 0, d10 = 0;
  const show10 = () => { $('n10').textContent = l10 + ' / ' + r10; $('d10').textContent = d10; };
  for (const [id, side] of [['l10', 'L'], ['r10', 'R']]) {
    const b = $(id);
    b.addEventListener('pointerdown', () => { d10++; show10(); });
    b.addEventListener('click', (e) => {
      if (side === 'L') l10++; else r10++;
      show10();
      log(10, side + ' click' + (e.isTrusted ? '' : '*') + ' 합 ' + (l10 + r10) + '/' + d10);
    });
  }
  $('clear').addEventListener('click', () => { l10 = r10 = d10 = 0; show10(); });

  // 11 키보드
  $('open11').addEventListener('click', () => { $('win11').style.display = 'block'; log(11, 'open'); });
  document.addEventListener('keydown', (e) => {
    $('k11').textContent = e.key + ' / ' + e.code + (e.repeat ? ' (repeat)' : '');
    if (!e.repeat) log(11, 'down ' + e.key + ' ' + e.code + ' kc=' + e.keyCode);
    if (e.key === 'Escape') { $('win11').style.display = 'none'; }
    switch (e.code) {
      case 'ArrowLeft': log(11, '← 이전'); break;
      case 'ArrowRight': log(11, '→ 다음'); break;
    }
    if (e.code === 'Enter' || e.keyCode === 32) log(11, 'enter/space');
  });
  document.addEventListener('keyup', (e) => { if (e.key === 'Escape') log(11, 'up Esc'); });

  // 12 입력 칸 (checkbox·label 이 두 번 바뀌지 않는지)
  $('in12').addEventListener('focus', () => log(12, 'focus input vv=' + Math.round(visualViewport.height) + ' ih=' + innerHeight));
  $('in12').addEventListener('input', () => log(12, 'input "' + $('in12').value + '"'));
  $('in12').addEventListener('blur', () => log(12, 'blur input ih=' + innerHeight));
  $('sel12').addEventListener('change', () => log(12, 'select ' + $('sel12').value));
  $('ta12').addEventListener('focus', () => log(12, 'focus textarea'));
  let cbn = 0;
  $('cb12').addEventListener('click', () => log(12, 'cb click #' + (++cbn) + ' checked=' + $('cb12').checked));
  $('cb12').addEventListener('change', () => log(12, 'cb change ' + $('cb12').checked));
  for (const r of document.querySelectorAll('input[name=r12]')) r.addEventListener('change', () => log(12, 'radio ' + r.value));
  $('a12').addEventListener('click', () => log(12, 'link click'));

  // 13 draggable → 놓는 자리 (두 번째는 dragstart 를 막는다: 운빨던전 방식)
  $('drag13').addEventListener('dragstart', (e) => { e.dataTransfer.setData('text/plain', 'drag13'); e.dataTransfer.effectAllowed = 'move'; log(13, 'dragstart'); });
  $('drag13').addEventListener('dragend', (e) => log(13, 'dragend drop=' + e.dataTransfer.dropEffect));
  $('drag13b').addEventListener('dragstart', (e) => { e.preventDefault(); log(13, 'dragstart prevented'); });
  const drop = $('drop13');
  drop.addEventListener('dragenter', () => log(13, 'dragenter'));
  drop.addEventListener('dragover', (e) => { e.preventDefault(); });
  drop.addEventListener('dragleave', () => log(13, 'dragleave'));
  drop.addEventListener('drop', (e) => { e.preventDefault(); log(13, 'drop ' + e.dataTransfer.getData('text/plain')); drop.textContent = '놓음: ' + e.dataTransfer.getData('text/plain'); });

  // 14 터치를 직접 듣고 preventDefault (§2.3): 마우스 이벤트가 오면 안 된다
  const t14 = $('touch14');
  t14.addEventListener('touchstart', (e) => { e.preventDefault(); log(14, 'touchstart (막음)'); }, { passive: false });
  for (const t of ['mousedown', 'mouseup', 'click']) t14.addEventListener(t, (e) => log(14, t + (e.isTrusted ? '' : '*') + ' ← 오면 안 됨'));

  // 15 작은 글씨
  let n15 = 0;
  $('b15').addEventListener('click', () => { $('n15').textContent = ++n15; log(15, 'tiny click ' + n15); });

  // 16 사용자 동작이 필요한 일 (0단계 2번)
  const wav = (() => {
    const n = 2205, b = new ArrayBuffer(44 + n * 2), v = new DataView(b);
    const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVEfmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, 22050, true); v.setUint32(28, 44100, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true);
    for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, Math.sin(i / 8) * 8000, true);
    return URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
  })();
  $('snd16').addEventListener('click', (e) => {
    const a = new Audio(wav);
    a.play().then(() => log(16, 'audio ok' + (e.isTrusted ? '' : ' (합성)')), (err) => log(16, 'audio ' + err.name));
  });
  $('clip16').addEventListener('click', (e) => {
    if (!navigator.clipboard) return log(16, 'clipboard 없음');
    navigator.clipboard.writeText('빙수').then(() => log(16, 'clip ok' + (e.isTrusted ? '' : ' (합성)')), (err) => log(16, 'clip ' + err.name));
  });
  $('file16').addEventListener('click', () => { $('fi16').click(); log(16, 'file click 보냄'); });
  $('fi16').addEventListener('change', () => log(16, 'file 고름 ' + $('fi16').files.length));
  $('ext16').addEventListener('click', () => log(16, 'link click'));

  // 처리되지 않은 오류도 기록
  addEventListener('error', (e) => console.warn('[fixture] error ' + e.message));
  console.warn('[fixture] lab ready');
})();
