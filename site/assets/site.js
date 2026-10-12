/* Hopkey — сайт продукта: живая палитра в hero и мини-демо по секциям. */
(() => {
  const root = document.documentElement;
  const EN = root.lang === 'en';
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  const T = EN ? {
    on: 'on', off: 'off',
    micOff: 'Microphone off', micOn: 'Microphone on',
    micBtnOff: 'Mic off', micBtnOn: 'Mic on',
    opened: (k) => `Opened: ${k}`,
    awakeOn: 'Your Mac won’t sleep until you switch it off',
    awakeOff: 'Sleep is back to normal',
    sound: 'Output AirPods Pro 62% · Input MacBook 80%. ←→ change the level',
    clip: 'Clipboard history: 24 items, stored encrypted',
    notes: 'Notes: 7 drafts, always at hand · ⌃⌥N',
    transform: 'Case, JSON, URL, Base64, JWT and lines, with a preview',
    ocr: 'Select an area and the text lands in the clipboard',
    pwd: 'Pasted from Keychain into the active field',
    snips: { 1: 'Thanks! I’ll look after lunch and get back to you.', 2: 'meet.example.com/team-standup', 3: null },
    snipsBig: { 1: '••••••••••••', 2: 'meet.example.com/team-standup', 3: 'Thanks! I’ll look after lunch and get back to you.', 4: 'billing@example.com' },
    snipNote: (n) => n === 1 ? 'Pasted from Keychain. The value never shows on screen.' : 'Pasted where the cursor was.',
    noKeys: 'No keys here, so no notification',
    open1: 'Click to open the link',
    openN: (n) => `Click to open the links (${n})`,
    me: 'Me',
    willOpen: 'will open',
  } : {
    on: 'вкл', off: 'выкл',
    micOff: 'Микрофон выключен', micOn: 'Микрофон включён',
    micBtnOff: 'Микрофон выкл', micBtnOn: 'Микрофон вкл',
    opened: (k) => `Открыто: ${k}`,
    awakeOn: 'Mac не уснёт, пока вы не выключите',
    awakeOff: 'Сон снова по расписанию',
    sound: 'Выход AirPods Pro 62% · вход MacBook 80%. ←→ меняют уровень',
    clip: 'История буфера: 24 записи, хранится зашифрованной',
    notes: 'Заметки: 7 черновиков под рукой · ⌃⌥N',
    transform: 'Регистр, JSON, URL, Base64, JWT и строки — с превью',
    ocr: 'Выделите область — текст окажется в буфере',
    pwd: 'Вставлено из Keychain в активное поле',
    snips: { 1: 'Спасибо! Посмотрю после обеда и вернусь.', 2: 'meet.example.com/team-standup', 3: null },
    snipsBig: { 1: '••••••••••••', 2: 'meet.example.com/team-standup', 3: 'Спасибо! Посмотрю после обеда и вернусь.', 4: 'billing@example.com' },
    snipNote: (n) => n === 1 ? 'Вставлено из Keychain — значение не мелькает на экране.' : 'Вставлено туда, где стоял курсор.',
    noKeys: 'Ключей нет — уведомления не будет',
    open1: 'Нажмите, чтобы открыть ссылку',
    openN: (n) => `Нажмите, чтобы открыть ссылки (${n})`,
    me: 'Я',
    willOpen: 'откроется',
  };

  /* ── тема ─────────────────────────────────────────────────────── */
  $('#themeBtn')?.addEventListener('click', () => {
    const next = root.dataset.theme === 'dark' ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('theme', next); } catch (e) {}
  });

  /* ── шапка и появление ────────────────────────────────────────── */
  const top = $('.top');
  const onScroll = () => top.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true }); onScroll();

  // hero показываем сразу, не дожидаясь наблюдателя: первый экран не должен зависеть от IO
  $$('.hero .rv').forEach((el, i) => {
    el.style.transitionDelay = i * 80 + 'ms';
    setTimeout(() => el.classList.add('in'), 30);
  });
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((es) => es.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }), { rootMargin: '0px 0px -6% 0px' });
    $$('.rv:not(.hero .rv)').forEach((el) => io.observe(el));
  } else {
    $$('.rv').forEach((el) => el.classList.add('in'));
  }

  /* ── общее состояние микрофона (hero + секция «Звук») ──────────── */
  let micMuted = false;
  const hud = $('#hud');
  let hudTimer;
  function setMic(muted, withHud) {
    micMuted = muted;
    $$('#mbMic, #sndMic').forEach((el) => {
      el.classList.toggle('muted', muted);
      el.querySelector('use').setAttribute('href', muted ? '#i-micoff' : '#i-mic');
    });
    const tile = $('.tile.mic');
    if (tile) { tile.classList.toggle('on', muted); tile.querySelector('[data-state]').textContent = muted ? T.off : T.on; }
    const btn = $('#muteBtn');
    if (btn) {
      btn.classList.toggle('muted', muted);
      btn.setAttribute('aria-pressed', String(muted));
      btn.querySelector('use').setAttribute('href', muted ? '#i-micoff' : '#i-mic');
      btn.querySelector('span').textContent = muted ? T.micBtnOff : T.micBtnOn;
    }
    if (withHud && hud) {
      hud.querySelector('use').setAttribute('href', muted ? '#i-micoff' : '#i-mic');
      hud.querySelector('span').textContent = muted ? T.micOff : T.micOn;
      hud.classList.add('show');
      clearTimeout(hudTimer);
      hudTimer = setTimeout(() => hud.classList.remove('show'), 1300);
    }
  }
  $('#muteBtn')?.addEventListener('click', () => setMic(!micMuted, false));

  /* ── hero: палитра ────────────────────────────────────────────── */
  const stage = $('#stage');
  if (stage) {
    const pal = $('#pal');
    const items = $$('[data-act]', pal);
    const toast = $('#toast');
    const composer = $('#composer');
    const chatBody = $('#chatBody');
    const cmdKey = $('#cmdKey');
    const mbHop = $('#mbHop');
    const composerHint = composer.textContent;
    let sel = 0, interacted = false, toastTimer, typing = null, awake = false;

    const isOpen = () => stage.classList.contains('open');
    const select = (i) => { sel = (i + items.length) % items.length; items.forEach((el, j) => el.classList.toggle('sel', j === sel)); };
    function open() {
      interacted = true;
      stage.classList.add('open'); mbHop.classList.add('on');
      select(0);
    }
    function close() { stage.classList.remove('open'); mbHop.classList.remove('on'); }
    const toggle = () => (isOpen() ? close() : open());

    function say(text) {
      toast.querySelector('span').textContent = text;
      toast.classList.add('show');
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => toast.classList.remove('show'), 2600);
    }

    function typeInto(text, secret) {
      clearInterval(typing);
      composer.classList.add('filled');
      composer.innerHTML = '<span></span><span class="caret"></span>';
      const out = composer.firstChild;
      const shown = secret ? '•'.repeat(12) : text;
      let i = 0;
      const done = () => {
        if (secret) { setTimeout(resetComposer, 1600); return; }
        setTimeout(() => {
          const m = document.createElement('div');
          m.className = 'msg mine new';
          m.innerHTML = `<span class="av">${T.me}</span><div><b>${T.me}</b><p></p></div>`;
          m.querySelector('p').textContent = text;
          chatBody.appendChild(m);
          while (chatBody.children.length > 3) chatBody.firstElementChild.remove();
          resetComposer();
        }, 500);
      };
      if (reduce) { out.textContent = shown; done(); return; }
      typing = setInterval(() => {
        i += secret ? 2 : 3;
        out.textContent = shown.slice(0, i);
        if (i >= shown.length) { clearInterval(typing); done(); }
      }, 24);
    }
    function resetComposer() { composer.classList.remove('filled'); composer.textContent = composerHint; }

    function run(el) {
      const act = el.dataset.act;
      if (act === 'mic') { close(); setMic(!micMuted, true); return; }
      if (act === 'awake') {
        awake = !awake;
        el.classList.toggle('on', awake);
        el.querySelector('[data-state]').textContent = awake ? T.on : T.off;
        say(awake ? T.awakeOn : T.awakeOff);
        return;
      }
      if (act === 'snip') {
        const n = +el.dataset.n;
        close();
        if (T.snips[n]) typeInto(T.snips[n], false); else { typeInto('', true); say(T.pwd); }
        return;
      }
      close();
      if (act === 'key') say(T.opened('PROJ-4821, #42'));
      else if (act === 'sound') say(T.sound);
      else if (act === 'clip') say(T.clip);
      else if (act === 'notes') say(T.notes);
      else if (act === 'transform') say(T.transform);
      else if (act === 'ocr') say(T.ocr);
    }

    items.forEach((el, i) => {
      el.addEventListener('click', (e) => { e.stopPropagation(); select(i); run(el); });
      el.addEventListener('mousemove', () => { if (sel !== i) select(i); });
    });
    stage.addEventListener('click', (e) => {
      if (isOpen() && !pal.contains(e.target) && !mbHop.contains(e.target)) close();
    });
    mbHop.addEventListener('click', (e) => { e.stopPropagation(); toggle(); });

    // два клика/тапа по нарисованной клавише ⌘
    let lastClick = 0;
    cmdKey.addEventListener('click', (e) => {
      e.stopPropagation();
      interacted = true;
      const now = performance.now();
      if (now - lastClick < 550) { lastClick = 0; open(); } else lastClick = now;
    });

    // настоящий двойной ⌘: два отпускания без других клавиш между ними
    let metaDown = false, metaDirty = false, lastTap = 0;
    addEventListener('keydown', (e) => {
      if (e.key === 'Meta') { metaDown = true; metaDirty = false; cmdKey.classList.add('down'); return; }
      if (metaDown || e.ctrlKey || e.altKey || e.metaKey) { metaDirty = true; return; }
      if (!isOpen() || isField(e.target)) return;
      const k = e.key;
      if (k === 'Escape') { close(); e.preventDefault(); return; }
      if (k === 'ArrowDown' || k === 'ArrowRight') { select(sel + 1); e.preventDefault(); return; }
      if (k === 'ArrowUp' || k === 'ArrowLeft') { select(sel - 1); e.preventDefault(); return; }
      if (k === 'Enter') { run(items[sel]); e.preventDefault(); return; }
      // как в приложении: по физической клавише (e.code), поэтому работает и в кириллице
      const hit = items.find((el) => el.dataset.code === e.code);
      if (hit) { select(items.indexOf(hit)); run(hit); e.preventDefault(); }
    });
    addEventListener('keyup', (e) => {
      if (e.key !== 'Meta') return;
      metaDown = false;
      cmdKey.classList.remove('down');
      if (metaDirty) return;
      const now = performance.now();
      if (now - lastTap < 450) {
        lastTap = 0;
        interacted = true;
        const r = stage.getBoundingClientRect();
        if (r.bottom < 80 || r.top > innerHeight - 80) stage.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'center' });
        toggle();
      } else lastTap = now;
    });
    addEventListener('blur', () => { metaDown = false; cmdKey.classList.remove('down'); });

    // если посетитель сам не открыл — один раз показываем двойной тап
    const press = (cb) => { cmdKey.classList.add('down'); setTimeout(() => { cmdKey.classList.remove('down'); cb && cb(); }, 130); };
    setTimeout(() => {
      if (interacted || reduce) return;
      press(() => setTimeout(() => press(() => { if (!interacted) open(); interacted = false; }), 140));
    }, 1700);
  }

  function isField(t) {
    return t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
  }

  /* ── ключ → ссылка ───────────────────────────────────────────── */
  const klIn = $('#klIn');
  if (klIn) {
    const TEMPLATES = [
      { name: 'Jira', re: /(?<![\w-])PROJ-(\d+)(?!\w)/gi, key: (m) => `PROJ-${m[1]}`, url: (m) => `jira.example.com/browse/PROJ-${m[1]}` },
      { name: 'GitHub', re: /(?<![\w&])#(\d+)(?!\w)/g, key: (m) => `#${m[1]}`, url: (m) => `github.com/acme/app/issues/${m[1]}` },
      { name: 'CVE', re: /(?<![\w-])CVE-(\d{4})-(\d{4,})(?!\w)/gi, key: (m) => `CVE-${m[1]}-${m[2]}`, url: (m) => `nvd.nist.gov/vuln/detail/CVE-${m[1]}-${m[2]}` },
    ];
    const out = $('#klOut');
    const bannerText = $('#klBannerText');
    const banner = $('#klBanner');
    const render = () => {
      const text = klIn.value;
      const hits = [];
      TEMPLATES.forEach((t) => {
        t.re.lastIndex = 0;
        for (const m of text.matchAll(t.re)) hits.push({ at: m.index, key: t.key(m), url: t.url(m), name: t.name });
      });
      hits.sort((a, b) => a.at - b.at);
      const seen = new Set();
      const uniq = hits.filter((h) => !seen.has(h.key) && seen.add(h.key));
      out.innerHTML = '';
      uniq.forEach((h) => {
        const row = document.createElement('div');
        row.className = 'kl-hit';
        row.innerHTML = '<span class="k"></span><span class="u"></span><span class="p"></span>';
        row.children[0].textContent = h.key;
        row.children[1].textContent = 'https://' + h.url;
        row.children[2].textContent = h.name;
        out.appendChild(row);
      });
      if (!uniq.length) {
        out.innerHTML = `<div class="kl-empty">${T.noKeys}</div>`;
        banner.style.opacity = '.45';
        bannerText.textContent = T.noKeys;
      } else {
        banner.style.opacity = '';
        const title = uniq.map((h) => h.key).join(', ');
        bannerText.innerHTML = '';
        const b = document.createElement('span');
        b.style.color = 'var(--fg)';
        b.textContent = title;
        bannerText.append(b, document.createElement('br'), uniq.length === 1 ? T.open1 : T.openN(uniq.length));
      }
    };
    klIn.addEventListener('input', render);
    render();
  }

  /* ── сниппеты ─────────────────────────────────────────────────── */
  const snipList = $('#snipList');
  if (snipList) {
    const field = $('#snipField');
    const note = $('#snipNote');
    let timer;
    const rows = $$('.snip-r', snipList);
    rows.forEach((r) => r.addEventListener('click', () => {
      rows.forEach((x) => x.classList.toggle('sel', x === r));
      const n = +r.dataset.n;
      const text = T.snipsBig[n];
      clearInterval(timer);
      field.innerHTML = '<span></span><span class="caret"></span>';
      const out = field.firstChild;
      let i = 0;
      if (reduce) { out.textContent = text; note.textContent = T.snipNote(n); return; }
      timer = setInterval(() => {
        i += 2;
        out.textContent = text.slice(0, i);
        if (i >= text.length) { clearInterval(timer); note.textContent = T.snipNote(n); }
      }, 18);
    }));
  }

  /* ── уровни громкости ─────────────────────────────────────────── */
  $$('.lvl input').forEach((inp) => {
    const o = inp.parentElement.querySelector('output');
    inp.addEventListener('input', () => { o.textContent = inp.value + '%'; });
  });

  /* ── раскладка: подсвечиваем физическую клавишу ─────────────────── */
  const krow = $('#krow');
  if (krow) {
    addEventListener('keydown', (e) => {
      if (isField(e.target) || e.metaKey || e.ctrlKey || e.altKey) return;
      const k = krow.querySelector(`[data-code="${e.code}"]`);
      if (!k) return;
      k.classList.add('press');
      setTimeout(() => k.classList.remove('press'), 160);
    });
  }
})();
