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
    snips: { 1: 'meet.example.com/team-standup', 2: 'Thanks! I’ll look after lunch and get back to you.', 3: null },
    story: ['A colleague sent an issue number — open it', 'Someone asks for the meeting link — send it to chat', 'Call in a minute — mute the mic'],
    ask: { av: 'M', name: 'Mark', text: 'Can you drop the meeting link?' },
    storyToast: 'PROJ-4821 — click to open the link',
    double: 'double',
    snipsBig: { 1: 'meet.example.com/team-standup', 2: 'Thanks! I’ll look after lunch and get back to you.', 3: 'billing@example.com', 4: '••••••••••••' },
    snipNote: (n) => n === 4 ? 'Pasted from Keychain. The value never shows on screen.' : 'Pasted where the cursor was.',
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
    snips: { 1: 'meet.example.com/team-standup', 2: 'Спасибо! Посмотрю после обеда и вернусь.', 3: null },
    story: ['Коллега прислал номер задачи — открыть её', 'Просят ссылку на созвон — отправить её в чат', 'Созвон через минуту — выключить микрофон'],
    ask: { av: 'М', name: 'Марк', text: 'Кинь ссылку на созвон?' },
    storyToast: 'PROJ-4821 — нажмите, чтобы открыть ссылку',
    double: 'двойной',
    snipsBig: { 1: 'meet.example.com/team-standup', 2: 'Спасибо! Посмотрю после обеда и вернусь.', 3: 'billing@example.com', 4: '••••••••••••' },
    snipNote: (n) => n === 4 ? 'Вставлено из Keychain — значение не мелькает на экране.' : 'Вставлено туда, где стоял курсор.',
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

  /* ── hero: сам проигрывающаяся история + живая палитра ──────────── */
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
    let sel = 0, toastTimer, typing = null, awake = false;

    const isOpen = () => stage.classList.contains('open');
    const select = (i) => { sel = (i + items.length) % items.length; items.forEach((el, j) => el.classList.toggle('sel', j === sel)); };
    function open() { stage.classList.add('open'); mbHop.classList.add('on'); select(0); }
    function close() { stage.classList.remove('open'); mbHop.classList.remove('on'); }
    const toggle = () => (isOpen() ? close() : open());

    function say(text, ms = 2600) {
      toast.querySelector('span').textContent = text;
      toast.classList.add('show');
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => toast.classList.remove('show'), ms);
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

    /* история: три сценария по кругу, пока посетитель сам не возьмёт управление */
    const keysOv = $('#keysOv'), capN = $('#capN'), capT = $('#capT'), capDots = $$('.cap-dots i');
    const wBrowser = $('#wBrowser'), wCall = $('#wCall');
    const callMic = $('#callMic'), callMe = $('.ct.me'), callMeMic = $('#callMeMic');
    const chatInitial = chatBody.innerHTML;
    const firstKey = () => $('#chatBody .key');
    let storyTok = 0, storyMuted = false;
    const playing = () => stage.classList.contains('story');
    // ожидание, которое обрывает сценарий, если его остановили (сменился токен)
    const wait = (ms, t) => new Promise((ok, stop) => setTimeout(() => (t === storyTok ? ok() : stop()), ms));

    function showKeys(list) {
      keysOv.innerHTML = list.map((k) => (k[0] === '~' ? `<span>${k.slice(1)}</span>` : `<b${k.length > 1 ? ' class="wide"' : ''}>${k}</b>`)).join('');
      keysOv.classList.add('show');
    }
    const hideKeys = () => keysOv.classList.remove('show');
    function caption(i) {
      capN.textContent = `${i + 1}/3`;
      capT.textContent = T.story[i];
      capT.classList.remove('swap'); void capT.offsetWidth; capT.classList.add('swap');
      capDots.forEach((d, j) => d.classList.toggle('on', j <= i));
    }
    function setCallMic(m) {
      callMic.classList.toggle('muted', m);
      callMe.classList.toggle('muted', m);
      [callMic, callMeMic].forEach((el) => el.querySelector('use').setAttribute('href', m ? '#i-micoff' : '#i-mic'));
    }
    function resetScene() {
      [wBrowser, wCall].forEach((w) => w.classList.remove('show'));
      hideKeys(); close();
      toast.classList.remove('show', 'press');
      hud.classList.remove('show');
      clearInterval(typing); resetComposer();
      chatBody.innerHTML = chatInitial;
      setCallMic(false);
      if (storyMuted) { setMic(false, false); storyMuted = false; }
    }

    async function sceneKey(t) {
      caption(0);
      chatBody.innerHTML = chatInitial;
      await wait(700, t); firstKey().classList.add('hl');
      await wait(700, t); showKeys(['⌘', 'C']);
      await wait(900, t); hideKeys();
      await wait(300, t); say(T.storyToast, 4000);
      await wait(1400, t); toast.classList.add('press');
      await wait(180, t); toast.classList.remove('show', 'press'); firstKey().classList.remove('hl'); wBrowser.classList.add('show');
      await wait(2400, t); wBrowser.classList.remove('show');
      await wait(500, t);
    }
    async function sceneLink(t) {
      caption(1);
      const m = document.createElement('div');
      m.className = 'msg new';
      m.innerHTML = '<span class="av" style="background:var(--teal)"></span><div><b></b><p></p></div>';
      m.querySelector('.av').textContent = T.ask.av;
      m.querySelector('b').textContent = T.ask.name;
      m.querySelector('p').textContent = T.ask.text;
      chatBody.appendChild(m);
      await wait(1300, t); showKeys(['⌘', '⌘', '~' + T.double]);
      await wait(800, t); hideKeys(); open(); select(items.findIndex((el) => el.dataset.code === 'Digit1'));
      await wait(1100, t); showKeys(['1']);
      await wait(450, t); close(); hideKeys(); typeInto(T.snips[1], false);
      await wait(2600, t);
    }
    async function sceneMic(t) {
      caption(2); wCall.classList.add('show');
      await wait(1300, t); showKeys(['⇧', '⌘', 'M']);
      await wait(700, t); hideKeys(); storyMuted = true; setMic(true, true); setCallMic(true);
      await wait(2400, t); wCall.classList.remove('show');
      await wait(400, t); setMic(false, false); storyMuted = false; setCallMic(false);
      await wait(300, t);
    }
    async function play() {
      const t = ++storyTok;
      resetScene();
      stage.classList.add('story');
      try { for (;;) { await sceneKey(t); await sceneLink(t); await sceneMic(t); } } catch (e) { /* сценарий остановлен */ }
    }
    function stopStory() {
      if (!playing()) return;
      storyTok++;
      stage.classList.remove('story');
      resetScene();
    }

    // любой клик по сцене во время истории — переход к живой палитре
    stage.addEventListener('click', (e) => {
      if (!playing()) return;
      e.stopPropagation();
      const wantsTry = e.target.closest('#capTry');
      stopStory();
      if (wantsTry) open();
    }, true);
    $('#replay')?.addEventListener('click', (e) => { e.stopPropagation(); play(); });

    if (reduce) stage.classList.remove('story');
    else if ('IntersectionObserver' in window) {
      // играем только пока сцена на экране: иначе мьют из истории дёргал бы секцию «Звук»
      new IntersectionObserver(([en]) => {
        if (!playing()) return;
        if (en.isIntersecting) play(); else { storyTok++; resetScene(); }
      }, { threshold: 0.25 }).observe(stage);
    } else play();

    /* живая палитра */
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
      const now = performance.now();
      if (now - lastClick < 550) { lastClick = 0; open(); } else lastClick = now;
    });

    // настоящий двойной ⌘: два отпускания без других клавиш между ними
    let metaDown = false, metaDirty = false, lastTap = 0;
    addEventListener('keydown', (e) => {
      if (e.key === 'Meta') { metaDown = true; metaDirty = false; cmdKey.classList.add('down'); return; }
      if (metaDown || e.ctrlKey || e.altKey || e.metaKey) { metaDirty = true; return; }
      if (!isOpen() || playing() || isField(e.target)) return;
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
        const r = stage.getBoundingClientRect();
        if (r.bottom < 80 || r.top > innerHeight - 80) stage.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'center' });
        if (playing()) { stopStory(); open(); } else toggle();
      } else lastTap = now;
    });
    addEventListener('blur', () => { metaDown = false; cmdKey.classList.remove('down'); });
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
