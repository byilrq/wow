/* WoW Realm Portal UI 2026.10.02
 * Progressive presentation only: no new API, authentication or server commands.
 * All POST actions, field names, CSRF/PIN validation and persistence stay in WowApp.
 */
(() => {
  'use strict';

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const main = $('main');
  if (!main || !$('.topbar')) return;
  let publicInfo = {};
  try { publicInfo = JSON.parse($('#wow-public-ui')?.textContent || '{}'); } catch (_) {}
  const config = {
    realmlist: typeof publicInfo.realmlist === 'string' ? publicInfo.realmlist : '',
    gameVersion: typeof publicInfo.gameVersion === 'string' ? publicInfo.gameVersion : '',
    cacheSeconds: Math.max(0, Number(publicInfo.cacheSeconds) || 0)
  };
  const isHome = !!$('.hero-with-register');
  const isAnnouncements = !!$('form input[value="add_announcement"]');
  if (!isHome && !isAnnouncements) return;
  const scope = `wow-console.v1:${location.pathname}:`;
  const state = { view: 'overview', dialogOpen: false, poller: null, guide: null };
  const dateText = (d = new Date()) => d.toLocaleString('zh-CN', {hour12: false});
  const timeText = (d = new Date()) => d.toLocaleTimeString('zh-CN', {hour12: false});
  const stamp = () => new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
  function node(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = String(text);
    return n;
  }
  function fragment(html) {
    const t = document.createElement('template');
    t.innerHTML = html; // Only static UI, or explicitly escaped text, is passed here.
    return t.content;
  }
  function button(label, cls = 'btn', iconName = '') {
    const b = node('button', cls);
    b.type = 'button';
    if (iconName) b.append(fragment(icon(iconName)));
    b.append(document.createTextNode(label));
    return b;
  }
  function readStore(kind, key, fallback = null) {
    try {
      const raw = window[kind].getItem(scope + key);
      return raw === null ? fallback : JSON.parse(raw);
    } catch (_) { return fallback; }
  }
  function writeStore(kind, key, value) {
    try { window[kind].setItem(scope + key, JSON.stringify(value)); return true; }
    catch (_) { return false; }
  }
  function removeStore(kind, key) {
    try { window[kind].removeItem(scope + key); return true; } catch (_) { return false; }
  }
  const paths = {
    grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    users: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M22 21v-2a4 4 0 0 0-3-3.87"/><circle cx="9" cy="7" r="4"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    news: '<path d="m3 11 18-6v14L3 13zM7 14l2 7h3l-2-6M21 9h1M21 15h1"/>',
    book: '<path d="M12 5v16M3 3h5a4 4 0 0 1 4 2 4 4 0 0 1 4-2h5v16h-5a4 4 0 0 0-4 2 4 4 0 0 0-4-2H3z"/>',
    refresh: '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.1 6.1a8 8 0 0 1 13.5 3M4.4 14.9a8 8 0 0 0 13.5 3"/>',
    download: '<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
    copy: '<rect x="8" y="8" width="13" height="13" rx="2"/><path d="M16 8V3H3v13h5"/>',
    search: '<circle cx="10.5" cy="10.5" r="7.5"/><path d="m16 16 5 5"/>',
    shield: '<path d="m12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6zM8 12l3 3 5-6"/>',
    x: '<path d="m6 6 12 12M6 18 18 6"/>',
    eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    arrow: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    check: '<path d="m5 12 4 4L19 6"/>',
    level: '<path d="M4 20h16M6 17v-4h3v4M11 17V9h3v8M16 17V4h3v13"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7v.2"/>',
    save: '<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h12l4 4v12a2 2 0 0 1-2 2zM7 3v6h10V3M7 21v-8h10v8"/>'
  };
  function icon(name) {
    return `<svg class="ui-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.info}</svg>`;
  }

  const toasts = node('div', 'ui-toasts');
  toasts.setAttribute('aria-live', 'polite');
  document.body.append(toasts);
  function toast(text, kind = 'info') {
    const item = node('div', `ui-toast ui-toast-${kind}`);
    item.append(fragment(icon(kind === 'success' ? 'check' : 'info')), node('span', '', text));
    const close = button('', 'ui-icon-button', 'x');
    close.setAttribute('aria-label', '关闭提示');
    close.addEventListener('click', () => item.remove());
    item.append(close);
    toasts.append(item);
    while (toasts.children.length > 3) toasts.firstElementChild.remove();
    setTimeout(() => item.remove(), kind === 'error' ? 9000 : 5000);
  }

  // Native dialog provides a focus trap, Escape handling and an inert background.
  const modal = node('dialog', 'ui-modal');
  modal.setAttribute('aria-labelledby', 'ui-dialog-title');
  modal.innerHTML = `<div class="ui-modal-head"><h2 id="ui-dialog-title"></h2><button type="button" class="ui-icon-button" data-dialog-close aria-label="关闭">${icon('x')}</button></div>
    <div class="ui-modal-body"></div><div class="ui-modal-actions"></div>`;
  document.body.append(modal);
  let finishDialog = null;
  function closeDialog(value = null) {
    if (!finishDialog) return;
    const done = finishDialog;
    finishDialog = null;
    const secret = $('input[type="password"]', modal);
    if (secret) secret.value = '';
    if (modal.open) modal.close();
    state.dialogOpen = false;
    document.body.classList.remove('ui-modal-open');
    done(value);
  }
  $('[data-dialog-close]', modal).addEventListener('click', () => closeDialog(null));
  modal.addEventListener('cancel', e => { e.preventDefault(); closeDialog(null); });
  modal.addEventListener('click', e => {
    if (e.target !== modal) return;
    const r = modal.getBoundingClientRect();
    if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) closeDialog(null);
  });
  function ask({title, description = '', body = null, pin = false, danger = false, confirm = '确定', cancel = '取消', infoOnly = false}) {
    if (finishDialog) return Promise.resolve(null);
    const previousFocus = document.activeElement;
    $('#ui-dialog-title').textContent = title;
    const area = $('.ui-modal-body', modal);
    const actions = $('.ui-modal-actions', modal);
    area.replaceChildren();
    actions.replaceChildren();
    if (description) area.append(node('p', 'ui-description', description));
    if (body) area.append(body);
    let input = null;
    if (pin) {
      const label = node('label', 'ui-field', '公告管理 PIN');
      input = node('input');
      input.type = 'password';
      input.autocomplete = 'off';
      input.placeholder = '输入现有 PIN，由后端验证';
      input.setAttribute('aria-label', '公告管理 PIN');
      label.append(input, node('small', 'ui-note', 'PIN 仅用于本次提交，不写入浏览器存储。'));
      area.append(label);
    }
    if (!infoOnly) {
      const no = button(cancel);
      no.addEventListener('click', () => closeDialog(null));
      actions.append(no);
    }
    const yes = button(infoOnly ? '关闭' : confirm, danger ? 'btn danger' : 'btn primary');
    const accept = () => {
      if (pin && !input.value) { input.setCustomValidity('请输入公告管理 PIN。'); input.reportValidity(); return; }
      closeDialog(pin ? input.value : true);
    };
    yes.addEventListener('click', accept);
    if (input) {
      input.addEventListener('input', () => input.setCustomValidity(''));
      input.addEventListener('keydown', e => {
        if (e.key === 'Enter') { e.preventDefault(); accept(); }
      });
    }
    actions.append(yes);
    return new Promise(resolve => {
      finishDialog = value => {
        if (previousFocus instanceof HTMLElement && previousFocus.isConnected) previousFocus.focus({preventScroll: true});
        resolve(value);
      };
      state.dialogOpen = true;
      document.body.classList.add('ui-modal-open');
      try {
        modal.showModal();
        (input || (danger ? actions.firstElementChild : yes)).focus({preventScroll: true});
      } catch (_) {
        // Progressive fallback; never submit a protected action without confirmation.
        const value = pin ? window.prompt(`${title}\n${description}\n请输入公告管理 PIN：`) :
          (infoOnly ? (window.alert(title + '\n' + description), true) : window.confirm(title + '\n' + description));
        closeDialog(value || null);
      }
    });
  }
  async function copyText(value, label = '内容') {
    try {
      if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(String(value));
      else {
        const input = node('textarea', 'ui-clipboard');
        input.value = String(value);
        input.setAttribute('readonly', '');
        const active = document.activeElement;
        (modal.open ? $('.ui-modal-body', modal) : document.body).append(input);
        input.select();
        const ok = document.execCommand('copy');
        input.remove();
        if (active instanceof HTMLElement) active.focus({preventScroll: true});
        if (!ok) throw new Error('Clipboard unavailable');
      }
      toast(`${label}已复制`, 'success');
    } catch (_) {
      toast('浏览器禁止自动复制，请选中文字后手动复制。', 'error');
    }
  }
  function download(text, name, type) {
    const url = URL.createObjectURL(new Blob([text], {type}));
    const a = node('a');
    a.href = url; a.download = name;
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 3000);
  }
  function busyForm(form, text) {
    form.dataset.uiBusy = 'true';
    form.setAttribute('aria-busy', 'true');
    $$('button[type="submit"]', form).forEach(b => {
      b.dataset.uiOriginalText = b.textContent;
      b.disabled = true;
      b.textContent = text;
    });
  }
  function resetForms() {
    $$('form[data-ui-busy]').forEach(form => {
      delete form.dataset.uiBusy;
      form.removeAttribute('aria-busy');
      $$('button[data-ui-original-text]', form).forEach(b => {
        b.textContent = b.dataset.uiOriginalText; b.disabled = false;
        delete b.dataset.uiOriginalText;
      });
    });
    $$('input[name="pin"]').forEach(input => { input.value = ''; });
    $$('input[name="password"], input[name="repassword"]').forEach(input => {
      input.type = 'password';
      const toggle = input.parentElement.querySelector('.ui-password-toggle');
      if (toggle) { toggle.setAttribute('aria-pressed', 'false'); toggle.setAttribute('aria-label', '显示密码'); }
    });
  }
  window.addEventListener('pageshow', resetForms);
  window.addEventListener('pagehide', () => {
    if (state.poller) state.poller.dispose();
    $$('input[name="pin"]').forEach(input => { input.value = ''; });
    if (modal.open) closeDialog(null);
  });

  function enhanceRegistration() {
    const form = $('.register-inline-form');
    if (!form) return;
    form.id = 'ui-register-form';
    form.tabIndex = -1;
    const user = $('[name="username"]', form);
    const email = $('[name="email"]', form);
    const pass = $('[name="password"]', form);
    const repeat = $('[name="repassword"]', form);
    user.autocomplete = 'username';
    user.spellcheck = false;
    user.setAttribute('autocapitalize', 'characters');
    user.setAttribute('pattern', '[A-Za-z0-9_\\-]{2,16}');
    user.placeholder = '2–16 位字母、数字、_ 或 -';
    email.autocomplete = 'email';
    email.spellcheck = false;
    [pass, repeat].forEach((input, i) => {
      input.autocomplete = 'new-password';
      input.placeholder = i ? '再次输入密码' : '4–16 字节';
      const wrap = node('span', 'ui-password');
      input.before(wrap); wrap.append(input);
      const reveal = button('', 'ui-password-toggle ui-icon-button', 'eye');
      reveal.setAttribute('aria-label', '显示密码');
      reveal.setAttribute('aria-pressed', 'false');
      reveal.addEventListener('click', () => {
        const show = input.type === 'password';
        input.type = show ? 'text' : 'password';
        reveal.setAttribute('aria-label', show ? '隐藏密码' : '显示密码');
        reveal.setAttribute('aria-pressed', String(show));
      });
      wrap.append(reveal);
    });
    const feedback = node('div', 'ui-register-feedback');
    feedback.setAttribute('aria-live', 'polite');
    feedback.id = 'ui-register-feedback';
    repeat.setAttribute('aria-describedby', feedback.id);
    repeat.parentElement.after(feedback);
    const validate = () => {
      const mismatch = repeat.value !== '' && repeat.value !== pass.value;
      repeat.setCustomValidity(mismatch ? '两次输入的密码不一致。' : '');
      const bytes = new TextEncoder().encode(pass.value).length;
      pass.setCustomValidity(pass.value && (bytes < 4 || bytes > 16) ? '密码需为 4–16 字节；中文等字符会占多个字节。' : '');
      feedback.textContent = mismatch ? '两次密码不一致' : (repeat.value && pass.value ? '两次密码一致' : '');
      feedback.classList.toggle('ui-text-error', mismatch);
      feedback.classList.toggle('ui-text-success', !mismatch && !!repeat.value);
    };
    [pass, repeat].forEach(input => input.addEventListener('input', validate));
    const capState = node('p', 'ui-caps-warning', 'Caps Lock 已开启，请注意密码大小写。');
    capState.hidden = true;
    form.append(capState);
    [pass, repeat].forEach(input => input.addEventListener('keyup', e => {
      capState.hidden = !(e.getModifierState && e.getModifierState('CapsLock'));
    }));
    // Hidden fallback captcha fields must not block a valid external captcha submission.
    const fallback = $('.captcha-fallback', form);
    if (fallback) {
      const syncFallback = () => {
        $$('input', fallback).forEach(input => {
          input.disabled = fallback.hidden;
          input.required = !fallback.hidden;
        });
      };
      syncFallback();
      new MutationObserver(syncFallback).observe(fallback, {attributes: true, attributeFilter: ['hidden']});
    }
    form.append(node('p', 'ui-form-footnote', '游戏账号注册 · 沿用现有验证规则'));
    form.addEventListener('submit', e => {
      if (form.dataset.uiBusy === 'true') { e.preventDefault(); return; }
      validate();
      if (!form.checkValidity()) { e.preventDefault(); form.reportValidity(); return; }
      busyForm(form, '正在提交…');
    });
  }

  const navItems = [
    ['overview', '首页', 'grid'], ['announcements', '公告中心', 'news'], ['guide', '入服指南', 'book']
  ];
  function homeUrl(view) {
    const url = new URL(location.href);
    url.search = '?page=home';
    url.hash = view;
    return url.pathname + url.search + url.hash;
  }
  function announcementUrl() {
    const url = new URL(location.href);
    url.search = '?page=announcements'; url.hash = '';
    return url.pathname + url.search;
  }
  function navigate(view, focusId = '') {
    if (!isHome) { location.href = homeUrl(view); return; }
    if (location.hash !== '#' + view) location.hash = view;
    else switchView(view);
    if (focusId) requestAnimationFrame(() => document.getElementById(focusId)?.focus({preventScroll: false}));
  }
  function enhanceShell() {
    document.body.classList.add('wow-console');
    main.classList.add('ui-main');
    const skip = node('a', 'ui-skip', '跳到主要内容');
    skip.href = '#ui-main-content';
    main.id = 'ui-main-content';
    main.tabIndex = -1;
    document.body.prepend(skip);
    const brand = $('.brand');
    const title = brand.textContent.trim();
    const logo = $('.wlk-logo') || node('img');
    const originalSrc = logo.getAttribute('src') || 'assets/wlk-logo.png';
    logo.className = 'ui-header-logo';
    logo.src = 'assets/wlk-logo-ui.webp?v=20261002-2';
    logo.alt = 'World of Warcraft — Wrath of the Lich King';
    logo.width = 172; logo.height = 85;
    logo.setAttribute('fetchpriority', 'high');
    logo.addEventListener('error', () => { logo.src = originalSrc; }, {once: true});
    const brandText = node('span', 'ui-brand-text', title);
    brandText.append(node('small', '', 'WLK · PLAYERBOTS'));
    brand.replaceChildren(logo, brandText);
    brand.href = homeUrl('overview');
    brand.setAttribute('aria-label', title + ' · 返回首页');
    const nav = $('.topbar nav');
    nav.setAttribute('aria-label', '主导航');
    nav.replaceChildren();
    navItems.forEach(([key, label, symbol]) => {
      const a = node('a', 'ui-nav-link');
      a.href = key === 'announcements' ? announcementUrl() : homeUrl(key);
      a.dataset.uiNav = key;
      a.append(fragment(icon(symbol)), node('span', '', label));
      if (isHome && key !== 'announcements') {
        a.addEventListener('click', e => {
          if (e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey) {
            e.preventDefault(); navigate(key);
          }
        });
      }
      nav.append(a);
    });
    $$('.flash').forEach(flash => {
      flash.setAttribute('role', flash.classList.contains('error') ? 'alert' : 'status');
      const close = button('', 'ui-icon-button', 'x');
      close.setAttribute('aria-label', '关闭消息');
      close.addEventListener('click', () => flash.remove());
      flash.append(close);
    });
    const footer = $('footer');
    if (footer) footer.append(node('span', 'ui-footer-note', 'WRATH OF THE LICH KING · PLAYERBOTS'));
  }

  function statCard(label, iconName, key, note) {
    const c = node('div', 'ui-stat');
    c.innerHTML = `<div class="ui-stat-top"><span>${escape(label)}</span>${icon(iconName)}</div>
      <strong data-stat="${escape(key)}">—</strong><small>${escape(note)}</small>`;
    return c;
  }
  function pageHeading(title, subtitle, eyebrow = 'WORLD OF WARCRAFT / WEB CONSOLE') {
    const head = node('section', 'ui-page-heading');
    head.innerHTML = `<div><p class="ui-eyebrow">${escape(eyebrow)}</p><h1 id="ui-page-title">${escape(title)}</h1>
      <p id="ui-page-subtitle">${escape(subtitle)}</p></div><div class="ui-head-actions"></div>`;
    main.prepend(head);
    return head;
  }

  function parsePlayers(source) {
    const section = $('#online-players', source);
    if (!section) throw new Error('没有收到可识别的在线状态页面');
    const label = $('.online-total', section)?.textContent || '';
    const match = label.match(/(\d+)/);
    if (!match) throw new Error('在线总数缺失，保留上次结果');
    const total = Number(match[1]);
    if (!Number.isSafeInteger(total) || total < 0) throw new Error('在线总数格式异常');
    const players = $$('tbody tr', section).filter(tr => {
      const cells = $$('td', tr);
      return cells.length === 4 && !cells.some(td => td.hasAttribute('colspan'));
    }).map(tr => {
      const td = $$('td', tr);
      const race = $('img', td[1]);
      const cls = $('img', td[2]);
      return {
        name: td[0].textContent.trim(),
        race: race?.alt || td[1].textContent.trim() || '未知',
        raceIcon: race?.getAttribute('src') || '',
        className: cls?.alt || td[2].textContent.trim() || '未知',
        classIcon: cls?.getAttribute('src') || '',
        level: Number(td[3].textContent.trim())
      };
    });
    if (players.some(p => !p.name || !Number.isInteger(p.level) || p.level < 0 || p.level > 255)) {
      throw new Error('角色列表格式异常，保留上次结果');
    }
    return {total, players};
  }

  function createPlayerPanel(initial) {
    const section = $('#online-players');
    section.dataset.uiViews = 'overview';
    section.classList.add('ui-player-card');
    section.replaceChildren(fragment(`
      <div class="ui-section-heading"><div><p class="ui-eyebrow">REALM ACTIVITY</p><h2>在线角色</h2></div>
        <div class="ui-status-chip" id="ui-query-status"><span class="ui-status-dot"></span><span>正在读取</span></div></div>
      <div class="ui-refresh-bar"><div class="ui-data-status" id="ui-data-status"></div>
        <div class="ui-refresh-controls"><label for="ui-auto-refresh">自动刷新</label>
          <select id="ui-auto-refresh"><option value="0">关闭</option><option value="30">30 秒</option><option value="60">60 秒</option><option value="120">120 秒</option></select>
          <span class="ui-countdown" id="ui-countdown"></span>
          <button type="button" class="btn ui-small-button" id="ui-refresh">${icon('refresh')}刷新</button>
        </div></div>
      <div class="ui-inline-error" id="ui-refresh-error" role="status" hidden></div>
      <div class="table-wrap status-player-panel" tabindex="0" role="region" aria-label="首页在线角色名单，可左右滚动">
        <table class="ui-player-table"><caption class="ui-sr-only">当前接口返回的在线角色列表</caption>
          <thead><tr><th scope="col">角色名称</th><th scope="col">种族</th><th scope="col">职业</th><th scope="col">等级</th></tr></thead>
          <tbody id="ui-player-rows"></tbody></table>
      </div>
      <div class="ui-table-pagination"><span id="ui-page-info" aria-live="polite"></span><div class="ui-toolbar-actions" id="ui-player-pagination">
        <button type="button" class="btn ui-small-button" id="ui-prev-page" aria-label="上一页角色">上一页</button>
        <span id="ui-page-number"></span>
        <button type="button" class="btn ui-small-button" id="ui-next-page" aria-label="下一页角色">下一页</button>
      </div></div>
      <p class="ui-footnote" id="ui-player-sample-note"></p>
    `));
    let snapshot = initial;
    let received = new Date();
    let page = 1;
    let activeController = null;
    let refreshing = false;
    let disposed = false;
    let failures = 0;
    let nextAt = 0;
    let timer = null;
    let autoSeconds = 0;
    const pageSize = 10;
    const auto = $('#ui-auto-refresh');
    const refreshButton = $('#ui-refresh');
    const status = $('#ui-query-status');
    const errorBox = $('#ui-refresh-error');

    function iconCell(src, label) {
      const cell = node('td', 'icon-cell');
      const identity = node('span', 'ui-identity');
      try {
        const url = new URL(src, location.href);
        if (src && url.origin === location.origin && /\/assets\/icons\/(race|class)\/[A-Za-z0-9_.-]+$/.test(url.pathname)) {
          const img = node('img', 'wow-icon');
          img.src = url.href; img.alt = ''; img.width = 24; img.height = 24; img.loading = 'lazy';
          img.addEventListener('error', () => { img.hidden = true; }, {once: true});
          identity.append(img);
        }
      } catch (_) {}
      identity.append(node('span', '', label));
      cell.append(identity);
      return cell;
    }
    function renderRows() {
      const count = snapshot.players.length;
      const pages = Math.max(1, Math.ceil(count / pageSize));
      page = Math.max(1, Math.min(page, pages));
      const start = (page - 1) * pageSize;
      const tbody = $('#ui-player-rows');
      tbody.replaceChildren();
      snapshot.players.slice(start, start + pageSize).forEach(p => {
        const tr = node('tr');
        const nameCell = node('td');
        nameCell.append(node('span', 'ui-player-label', p.name));
        const levelCell = node('td', 'level-cell');
        levelCell.append(node('span', 'ui-level-pill', p.level));
        tr.append(nameCell, iconCell(p.raceIcon, p.race), iconCell(p.classIcon, p.className), levelCell);
        tbody.append(tr);
      });
      if (!count) {
        const tr = node('tr');
        const td = node('td', 'empty-row');
        td.colSpan = 4;
        td.append(fragment(icon('users')), node('strong', '', '暂未返回在线角色'),
          node('p', 'ui-note', '0 人在线不代表停服，查询结果也可能受缓存或连接状态影响。'));
        tr.append(td); tbody.append(tr);
      }
      $('#ui-page-info').textContent = count ? `显示 ${start + 1}–${Math.min(start + pageSize, count)} · 共 ${count} 条` : '当前名单为空';
      $('#ui-page-number').textContent = `${page} / ${pages}`;
      $('#ui-prev-page').disabled = page <= 1;
      $('#ui-next-page').disabled = page >= pages;
      $('#ui-player-pagination').hidden = pages <= 1;
    }
    function updateStats() {
      const p = snapshot.players;
      const values = {
        online: snapshot.total,
        returned: p.length,
        average: p.length ? (p.reduce((n,x) => n + x.level, 0) / p.length).toFixed(1) : '—',
        classes: new Set(p.map(x => x.className)).size
      };
      Object.entries(values).forEach(([key,value]) => $$(`[data-stat="${key}"]`).forEach(n => { n.textContent = value; }));
      $('#ui-player-sample-note').textContent = `在线总数 ${snapshot.total}，当前返回 ${p.length} 条角色（接口最多 49 条）。名单及统计可能包含 AI 机器人，不区分真人；不代表游戏进程运行状态。`;
    }
    function renderStatus() {
      status.classList.toggle('ui-status-warning', failures > 0 || snapshot.total === 0);
      status.classList.toggle('ui-status-good', failures === 0 && snapshot.total > 0);
      $('span:last-child', status).textContent = failures ? '保留上次数据' : snapshot.total > 0 ? `${snapshot.total} 人在线` : '暂无在线角色';
      $('#ui-data-status').textContent = `最近接收 ${timeText(received)}`;
      const freshness = $('#ui-freshness');
      if (freshness) freshness.textContent = failures ? '刷新失败，显示上次数据' : `状态接收于 ${timeText(received)}`;
      section.classList.toggle('ui-stale', failures > 0);
    }
    function renderAll() { renderRows(); updateStats(); renderStatus(); }
    function intervalMs() {
      return Math.max(autoSeconds, config.cacheSeconds, 30) * 1000 * Math.min(4, 2 ** failures);
    }
    function dueLater() { nextAt = autoSeconds ? Date.now() + intervalMs() : 0; }
    async function refresh(manual = true) {
      if (refreshing || disposed) return;
      refreshing = true;
      refreshButton.disabled = true;
      refreshButton.classList.add('ui-spinning');
      section.setAttribute('aria-busy', 'true');
      const control = new AbortController();
      activeController = control;
      const timeout = setTimeout(() => control.abort(), 20000);
      try {
        const url = new URL(location.href);
        url.search = '?page=home';
        url.searchParams.set('_ui_read', String(Date.now()));
        url.hash = '';
        // Deliberately anonymous. A normal authenticated home GET regenerates the
        // session's fallback captcha. Never replace CSRF/captcha with this response.
        const response = await fetch(url, {
          method: 'GET', credentials: 'omit', cache: 'no-store',
          headers: {'Accept': 'text/html'}, signal: control.signal
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const text = await response.text();
        const doc = new DOMParser().parseFromString(text, 'text/html');
        const next = parsePlayers(doc);
        if (disposed) return;
        snapshot = next;
        received = new Date();
        failures = 0;
        errorBox.hidden = true;
        renderAll();

        if (manual) toast('在线状态已更新，注册表单和验证码保持不变。', 'success');
      } catch (err) {
        if (disposed) return;
        failures++;
        const message = err?.name === 'AbortError' ? '请求超过 20 秒' : (err?.message || '网络连接失败');
        errorBox.textContent = `刷新失败：${message}。已保留 ${timeText(received)} 接收的数据，这不等于游戏服务器停服。`;
        errorBox.hidden = false;
        renderStatus();

        if (manual) toast('刷新失败，已保留上次数据；可稍后重试。', 'error');
        if (failures >= 3 && autoSeconds) {
          autoSeconds = 0; auto.value = '0';
          writeStore('localStorage', 'refreshSeconds', 0);
          errorBox.textContent += ' 连续失败 3 次，自动刷新已暂停。';
        }
      } finally {
        clearTimeout(timeout);
        activeController = null;
        refreshing = false;
        refreshButton.disabled = false;
        refreshButton.classList.remove('ui-spinning');
        section.removeAttribute('aria-busy');
        dueLater();
      }
    }
    function tick() {
      if (disposed) return;
      const label = $('#ui-countdown');
      if (!autoSeconds) label.textContent = '手动模式';
      else if (document.hidden || state.view !== 'overview' || state.dialogOpen) {
        label.textContent = '已暂缓'; nextAt = 0;
      } else if (refreshing) label.textContent = '读取中…';
      else {
        if (!nextAt) dueLater();
        const seconds = Math.max(0, Math.ceil((nextAt - Date.now()) / 1000));
        label.textContent = `${seconds} 秒后`;
        if (seconds === 0) refresh(false);
      }
      timer = setTimeout(tick, 1000);
    }

    $('#ui-prev-page').addEventListener('click', () => { page--; renderRows(); });
    $('#ui-next-page').addEventListener('click', () => { page++; renderRows(); });
    refreshButton.addEventListener('click', () => refresh(true));
    auto.addEventListener('change', () => {
      autoSeconds = [30,60,120].includes(Number(auto.value)) ? Number(auto.value) : 0;
      writeStore('localStorage', 'refreshSeconds', autoSeconds);
      dueLater();
    });
    const stored = Number(readStore('localStorage', 'refreshSeconds', 0));
    autoSeconds = [30,60,120].includes(stored) ? stored : 0;
    auto.value = String(autoSeconds);
    renderAll(); dueLater(); tick();
    return {
      refresh, updateStats, renderStatus,
      dispose() { disposed = true; clearTimeout(timer); activeController?.abort(); },
      resume() { if (disposed) { disposed = false; dueLater(); tick(); } }
    };
  }

  function buildGuide(launcherUrl) {
    const section = node('section', 'ui-guide ui-view');
    section.dataset.uiViews = 'guide'; section.hidden = true;
    section.innerHTML = `<div class="ui-guide-toolbar">
      <span class="ui-note">入服步骤与常见问题</span>
      <button type="button" class="btn ui-small-button" id="ui-guide-reload">${icon('refresh')}刷新说明</button>
      </div><div id="ui-guide-status" class="ui-guide-status" role="status" aria-live="polite"></div>
      <div id="ui-guide-content"></div>`;
    main.append(section);
    const content = $('#ui-guide-content');
    const status = $('#ui-guide-status');
    const reload = $('#ui-guide-reload');
    let controller = null;
    let sequence = 0;

    // Public, read-only content. This file never supplies connection settings.
    // No built-in guide copy and no localStorage fallback: the JSON is the only source.
    const guidePath = new URL('content/guide.json', document.baseURI);
    function replaceTokens(value) {
      return String(value).replace(/\{\{(game_version|realmlist)\}\}/g, (_, key) =>
        key === 'game_version' ? (config.gameVersion || '请向服主确认版本') : (config.realmlist || '请向服主确认地址'));
    }
    function validate(data) {
      if (!data || Array.isArray(data) || typeof data !== 'object') throw new Error('指南配置必须是 JSON 对象。');
      const text = (obj, key, path, required = false) => {
        if (obj[key] === undefined && !required) return '';
        if (typeof obj[key] !== 'string' || (required && !obj[key].trim()))
          throw new Error(`${path}${key} 必须是${required ? '非空' : ''}文字。`);
        return replaceTokens(obj[key]);
      };
      const out = {};
      for (const key of ['page_title', 'page_subtitle', 'intro_title', 'intro_text', 'notice', 'faq_title', 'footer_note']) {
        out[key] = text(data, key, '', key === 'page_title');
      }
      for (const name of ['steps', 'faqs']) {
        if (!Array.isArray(data[name])) throw new Error(`${name} 必须是数组，可使用 [] 留空。`);
      }
      out.steps = data.steps.map((item, i) => {
        const path = `steps[${i}].`;
        if (!item || typeof item !== 'object' || Array.isArray(item)) throw new Error(`${path}格式不正确。`);
        const action = text(item, 'action', path);
        if (!['', 'register', 'download', 'copy_address', 'announcements'].includes(action))
          throw new Error(`${path}action 仅支持 register、download、copy_address、announcements 或空字符串。`);
        return {
          title: text(item, 'title', path, true), content: text(item, 'content', path),
          action, button_text: text(item, 'button_text', path, !!action)
        };
      });
      out.faqs = data.faqs.map((item, i) => {
        const path = `faqs[${i}].`;
        if (!item || typeof item !== 'object' || Array.isArray(item)) throw new Error(`${path}格式不正确。`);
        return {question: text(item, 'question', path, true), answer: text(item, 'answer', path)};
      });
      return out;
    }
    function actionButton(step) {
      if (!step.action) return null;
      if (step.action === 'download' || step.action === 'announcements') {
        if (step.action === 'download' && !launcherUrl) return null;
        const a = node('a', step.action === 'download' ? 'btn primary' : 'btn', step.button_text);
        a.href = step.action === 'download' ? launcherUrl : announcementUrl();
        if (step.action === 'download') a.setAttribute('download', '');
        a.append(fragment(icon(step.action === 'download' ? 'download' : 'arrow')));
        return a;
      }
      const b = button(step.button_text, 'btn', step.action === 'register' ? 'users' : 'copy');
      if (step.action === 'register') b.addEventListener('click', () => navigate('overview', 'ui-register-form'));
      else {
        b.disabled = !config.realmlist;
        b.addEventListener('click', () => copyText(config.realmlist, '登录地址'));
      }
      return b;
    }
    function render(data) {
      const result = document.createDocumentFragment();
      if (data.intro_title || data.intro_text) {
        const intro = node('div', 'ui-guide-intro');
        const emblem = node('span', 'ui-guide-emblem');
        emblem.append(fragment(icon('book')));
        const copy = node('div');
        copy.append(node('p', 'ui-eyebrow', 'GETTING STARTED'));
        if (data.intro_title) copy.append(node('h2', '', data.intro_title));
        if (data.intro_text) copy.append(node('p', 'ui-note ui-guide-text', data.intro_text));
        intro.append(emblem, copy); result.append(intro);
      }
      if (data.notice) {
        const note = node('div', 'ui-guide-notice');
        note.append(fragment(icon('info')), node('p', 'ui-guide-text', data.notice));
        result.append(note);
      }
      if (data.steps.length) {
        const steps = node('div', 'ui-guide-steps');
        data.steps.forEach((step, i) => {
          const card = node('section', 'card');
          card.append(node('span', 'ui-step-number', String(i + 1).padStart(2, '0')), node('h2', '', step.title),
            node('p', 'ui-guide-text', step.content));
          const action = actionButton(step);
          if (action) card.append(action);
          steps.append(card);
        });
        result.append(steps);
      }
      if (data.faqs.length) {
        const faq = node('section', 'card ui-faq');
        if (data.faq_title) {
          const heading = node('div', 'ui-card-title');
          heading.append(fragment(icon('info')), node('h2', '', data.faq_title)); faq.append(heading);
        }
        data.faqs.forEach(item => {
          const detail = node('details');
          detail.append(node('summary', '', item.question), node('p', 'ui-guide-text', item.answer));
          faq.append(detail);
        });
        result.append(faq);
      }
      if (data.footer_note) result.append(node('p', 'ui-guide-footer ui-guide-text', data.footer_note));
      content.replaceChildren(result);
      if (state.view === 'guide') {
        $('#ui-page-title').textContent = data.page_title;
        $('#ui-page-subtitle').textContent = data.page_subtitle;
      }
    }
    async function load() {
      const id = ++sequence;
      controller?.abort();
      controller = new AbortController();
      const current = controller;
      const timeout = setTimeout(() => current.abort(), 12000);
      reload.disabled = true; reload.classList.add('ui-spinning');
      content.replaceChildren();
      section.setAttribute('aria-busy', 'true');
      status.classList.remove('ui-guide-error');
      status.textContent = '正在读取入服说明…';
      try {
        const url = new URL(guidePath);
        url.searchParams.set('_read', String(Date.now()));
        const response = await fetch(url, {
          method: 'GET', cache: 'no-store', credentials: 'omit', redirect: 'error',
          headers: {'Accept': 'application/json'}, signal: current.signal
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const text = await response.text();
        if (text.length > 256 * 1024) throw new Error('指南文件过大，请保持在 256 KB 字符以内。');
        let data;
        try { data = JSON.parse(text.replace(/^\uFEFF/, '')); }
        catch (_) { throw new Error('JSON 格式错误，请检查双引号、逗号和换行。'); }
        const safe = validate(data);
        if (id !== sequence) return;
        render(safe);
        status.textContent = '';
      } catch (error) {
        if (id !== sequence) return;
        const message = error?.name === 'AbortError' ? '读取超时' : (error?.message || '网络读取失败');
        status.classList.add('ui-guide-error');
        status.textContent = `入服说明暂时无法加载：${message} 请检查本地 public/content/guide.json，修正后点击“刷新说明”。系统不会重写配置或恢复默认文案。`;
      } finally {
        clearTimeout(timeout);
        if (id === sequence) {
          reload.disabled = false; reload.classList.remove('ui-spinning');
          section.removeAttribute('aria-busy');
          controller = null;
        }
      }
    }
    reload.addEventListener('click', load);
    window.addEventListener('pagehide', () => { sequence++; controller?.abort(); });
    window.addEventListener('pageshow', e => { if (e.persisted && state.view === 'guide') load(); });
    return {load};
  }

  const viewTitles = {
    overview: ['服务器首页', ''],
    guide: ['入服指南', '']
  };
  function switchView(requested) {
    if (!isHome) return;
    const view = Object.hasOwn(viewTitles, requested) ? requested : 'overview';
    const previousView = state.view;
    state.view = view;
    if (previousView !== view) window.scrollTo({top: 0, behavior: 'instant'});
    // Old bookmarks never re-create a retired page.
    if (['players', 'operations', 'online-players'].includes(requested)) {
      history.replaceState(null, '', homeUrl('overview'));
    }
    $$('[data-ui-views]').forEach(el => { el.hidden = !el.dataset.uiViews.split(' ').includes(view); });
    $('#ui-page-title').textContent = viewTitles[view][0];
    $('#ui-page-subtitle').textContent = viewTitles[view][1];
    $('.ui-page-heading').hidden = view === 'overview';
    $$('[data-ui-nav]').forEach(a => {
      const active = a.dataset.uiNav === view;
      a.classList.toggle('active', active);
      if (active) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    });
    if (state.poller) { state.poller.updateStats(); state.poller.renderStatus(); }
    if (view === 'guide' && state.guide) state.guide.load();
  }

  function buildHome() {
    const initial = parsePlayers(document);
    const hero = $('.hero-with-register');
    const grid = $('.grid.two');
    const infoCard = grid?.children[0];
    const newsCard = grid?.children[1];
    const originalLauncher = $('.launcher-icon-link');
    const launcherUrl = originalLauncher?.getAttribute('href') || '';
    const realmText = $('p', infoCard)?.textContent.replace(/^服务器[：:]\s*/, '').trim() || '当前服务器';
    const heading = pageHeading('服务器首页', '', 'WORLD OF WARCRAFT / REALM PORTAL');
    heading.hidden = true;
    const register = button('创建账号', 'btn primary', 'users');
    register.addEventListener('click', () => navigate('overview', 'ui-register-form'));
    $('.ui-head-actions', heading).append(register);

    hero.dataset.uiViews = 'overview';
    hero.classList.add('ui-hero', 'ui-realm-hero');
    const copy = $('.wlk-logo-wrap', hero);
    copy.className = 'ui-hero-copy';
    copy.removeAttribute('aria-label');
    copy.replaceChildren(fragment(`
      <div class="ui-realm-line"><span class="ui-realm-tag"></span><span class="ui-realm-version"></span></div>
      <p class="ui-eyebrow">YOUR WORLD. YOUR COMPANIONS.</p>
      <h1 class="ui-hero-title"><span>Playerbots</span> AI 机器人</h1>
      <p class="ui-hero-lead">一个人出发，也有队友同行。</p>
      <p class="ui-hero-description">Playerbots 为艾泽拉斯带来可交互的 AI 角色：与机器人组队升级、探索世界，协作参与副本战斗，让冒险不必等待队友上线。</p>
      <div class="ui-bot-features">
        <div>${icon('users')}<span>组队协作</span></div>
        <div>${icon('book')}<span>任务探索</span></div>
        <div>${icon('shield')}<span>副本冒险</span></div>
      </div>
      <div class="ui-hero-actions"></div>
      <p class="ui-bot-note">机器人数量、行为及开放玩法以服务端配置为准。</p>
    `));
    $('.ui-realm-tag', copy).textContent = realmText;
    $('.ui-realm-version', copy).textContent = config.gameVersion || '巫妖王之怒';
    const heroActions = $('.ui-hero-actions', copy);
    if (launcherUrl) {
      const dl = node('a', 'btn primary', '下载登录器');
      dl.href = launcherUrl; dl.setAttribute('download','');
      dl.append(fragment(icon('download'))); heroActions.append(dl);
    }
    const guide = button('查看入服指南', 'btn', 'book');
    guide.addEventListener('click', () => navigate('guide'));
    heroActions.append(guide);
    const panelHead = $('h2', $('.hero-register-panel'));
    if (panelHead) {
      panelHead.innerHTML = `${icon('shield')}<span>创建游戏账号</span>`;
      panelHead.after(node('p', 'ui-note', '准备好加入了吗？从这里开启冒险。'));
    }
    enhanceRegistration();

    const homeContent = node('div', 'ui-home-content ui-home-roster-only');
    homeContent.dataset.uiViews = 'overview';
    hero.after(homeContent);
    const online = $('#online-players');
    homeContent.append(online);
    if (grid) grid.remove();
    state.guide = buildGuide(launcherUrl);
    state.poller = createPlayerPanel(initial);
    window.addEventListener('pageshow', () => state.poller?.resume());
    window.addEventListener('hashchange', () => switchView(location.hash.slice(1)));
    switchView(location.hash.slice(1));
  }

  const levelLabels = {normal:'普通', important:'重要', maintenance:'维护'};
  function announcementLevel(article) {
    return article.classList.contains('maintenance') ? 'maintenance' : article.classList.contains('important') ? 'important' : 'normal';
  }
  function paragraphText(paragraph) {
    if (!paragraph) return '';
    const copy = paragraph.cloneNode(true);
    $$('br', copy).forEach(br => {
      const next = br.nextSibling;
      // PHP nl2br preserves the source newline as well as adding <br>.
      if (next?.nodeType === Node.TEXT_NODE && /^(?:\r?\n)/.test(next.textContent)) br.remove();
      else br.replaceWith(document.createTextNode('\n'));
    });
    return copy.textContent;
  }
  function decorateAnnouncement(article, management = true) {
    const level = announcementLevel(article);
    const textBlock = $('p',article);
    if (textBlock && !textBlock.dataset.uiPlain) {
      textBlock.textContent = paragraphText(textBlock);
      textBlock.dataset.uiPlain = 'true';
    }
    if (!$('.ui-announcement-type',article)) {
      const time = $('time',article);
      const tag = node('span', `ui-announcement-type ui-type-${level}`, levelLabels[level]);
      if (time) time.before(tag);
    }
    if (management) {
      const p = $('p',article);
      if (p) p.classList.add('ui-announcement-content');
    }
  }

  function buildAnnouncements() {
    const originalHead = $('.page-head');
    if (originalHead) originalHead.remove();
    const heading = pageHeading('公告中心','发布维护、活动与版本说明；发布和删除继续使用现有管理 PIN。');
    const headingActions = $('.ui-head-actions', heading);
    const exportButton = button('导出公告','btn','download');
    exportButton.id = 'ui-announcement-export';
    headingActions.append(exportButton);
    const editor = $('form input[value="add_announcement"]').closest('.card');
    const form = $('form',editor);
    const listing = $('.card.announcements');
    const layout = node('div','ui-announcements-layout');
    editor.before(layout); layout.append(editor,listing);
    editor.classList.add('ui-announcement-editor');
    listing.classList.add('ui-announcement-list');
    const titleInput = $('[name="title"]',form);
    const contentInput = $('[name="content"]',form);
    const levelInput = $('[name="level"]',form);
    titleInput.autocomplete = 'off';
    contentInput.rows = 7;
    $('h2',editor).innerHTML = `${icon('news')}<span>撰写公告</span>`;
    $('h2',editor).after(node('p','ui-note','先预览，再输入 PIN 确认发布。'));
    const templateRow = node('div','ui-template-row');
    templateRow.append(node('span','ui-note','快速模板'));
    const templateData = {
      maintenance:{title:'服务器维护通知',level:'maintenance',content:'维护时间：请填写开始与结束时间\n维护内容：请填写本次维护事项\n温馨提示：请提前在安全区域下线，维护完成后将另行通知。'},
      event:{title:'服务器活动公告',level:'important',content:'活动时间：请填写活动时间\n活动内容：请填写规则与参与方式\n注意事项：请填写奖励说明及其他要求。'},
      update:{title:'版本更新说明',level:'normal',content:'更新时间：请填写更新时间\n更新内容：\n1. 请填写变更内容\n2. 请填写修复事项\n客户端要求：请说明是否需要更新客户端。'}
    };
    Object.entries({maintenance:'维护',event:'活动',update:'更新'}).forEach(([key,label]) => {
      const b = button(label,'btn ui-small-button');
      b.addEventListener('click',async () => {
        if ((titleInput.value.trim() || contentInput.value.trim()) &&
            !await ask({title:'使用公告模板？',description:'模板会替换当前编辑区文字；不会自动发布。',confirm:'使用模板'})) return;
        const data = templateData[key];
        titleInput.value = data.title; contentInput.value = data.content; levelInput.value = data.level;
        updatePreview();
      });
      templateRow.append(b);
    });
    form.before(templateRow);

    const titleCount = node('small','ui-input-count'); titleInput.after(titleCount);
    const contentCount = node('small','ui-input-count'); contentInput.after(contentCount);
    const preview = node('section','ui-announcement-preview');
    preview.innerHTML = `<div class="ui-preview-heading"><span>${icon('eye')}发布预览</span><span class="ui-preview-type"></span></div>
      <h3></h3><p></p>`;
    contentInput.closest('label').after(preview);
    const submit = $('button[type="submit"]',form);
    submit.textContent = '确认并发布';
    submit.classList.add('ui-publish-button');
    submit.after(node('p','ui-form-footnote','公开公告 · PIN 仅用于本次后端验证'));
    const drafts = node('div','ui-draft-toolbar');
    const saveDraft = button('保存草稿','btn ui-small-button','save');
    const restoreDraft = button('恢复草稿','btn ui-small-button');
    const clearDraft = button('清除草稿','btn ui-small-button');
    drafts.append(saveDraft,restoreDraft,clearDraft);
    form.after(drafts);
    const draftNote = node('p','ui-note ui-draft-note','草稿仅存本浏览器，不上传；不保存 PIN。');
    drafts.after(draftNote);

    const notices = node('div','ui-announcement-feedback');
    notices.setAttribute('role','status');
    layout.before(notices);
    let rows = [];
    let pending = false;
    let uncertain = false;
    let savedSignature = '';
    function formData() { return {title:titleInput.value,content:contentInput.value,level:levelInput.value}; }
    const signature = () => JSON.stringify(formData());
    function validDraft(value) {
      return value && typeof value.title === 'string' && typeof value.content === 'string' &&
        typeof value.level === 'string' && Object.hasOwn(levelLabels, value.level);
    }
    function fillDraft(value) {
      titleInput.value = value.title.slice(0,80); contentInput.value = value.content; levelInput.value = value.level; updatePreview();
    }
    function updatePreview() {
      const level = Object.hasOwn(levelLabels,levelInput.value) ? levelInput.value : 'normal';
      $('.ui-preview-type',preview).textContent = levelLabels[level];
      $('.ui-preview-type',preview).className = 'ui-preview-type ui-type-' + level;
      $('h3',preview).textContent = titleInput.value.trim() || '公告标题';
      $('p',preview).textContent = contentInput.value || '输入公告内容后，在这里查看发布效果。';
      titleCount.textContent = `${titleInput.value.length} / 80`;
      contentCount.textContent = `${contentInput.value.length} 字符`;
    }
    [titleInput,contentInput,levelInput].forEach(input => input.addEventListener('input',updatePreview));
    saveDraft.addEventListener('click',() => {
      const data = formData();
      if (!data.title.trim() && !data.content.trim()) { toast('先填写公告内容再保存草稿。'); return; }
      if (writeStore('localStorage','announcementDraft',{...data,savedAt:dateText()})) {
        savedSignature = signature();
        draftNote.textContent = `草稿已保存 · ${dateText()} · 仅本浏览器`;
        toast('公告草稿已保存到本浏览器。','success');
      } else toast('浏览器存储不可用，草稿没有保存。请手动复制文字。','error');
    });
    restoreDraft.addEventListener('click',async () => {
      const draft = readStore('localStorage','announcementDraft');
      if (!validDraft(draft)) { toast('本浏览器没有可恢复的公告草稿。'); return; }
      if ((titleInput.value.trim() || contentInput.value.trim()) &&
          !await ask({title:'恢复本地草稿？',description:'将替换当前编辑区文字，不会自动发布。',confirm:'恢复草稿'})) return;
      fillDraft(draft); savedSignature = signature();
      draftNote.textContent = `已恢复本地草稿${draft.savedAt ? ' · ' + draft.savedAt : ''}`;
    });
    clearDraft.addEventListener('click',async () => {
      if (!await ask({title:'清除本地草稿？',description:'只删除本浏览器已保存的草稿，当前编辑区和已发布公告不会被删除。',confirm:'清除草稿'})) return;
      if (removeStore('localStorage','announcementDraft')) { draftNote.textContent = '本浏览器草稿已清除。'; toast('草稿已清除。','success'); }
      else toast('浏览器存储不可用，未能清除草稿。','error');
    });
    const savedDraft = readStore('localStorage','announcementDraft');
    if (validDraft(savedDraft)) draftNote.textContent = `本浏览器有已保存草稿${savedDraft.savedAt ? ' · ' + savedDraft.savedAt : ''}，点击“恢复草稿”读取。`;

    const listHead = $('h2',listing);
    const listControls = node('div','ui-announcement-controls');
    listControls.innerHTML = `<div class="ui-announcement-tabs" role="group" aria-label="公告类型筛选">
      <button type="button" class="ui-filter-chip active" data-news-filter="all" aria-pressed="true">全部 <b>0</b></button>
      <button type="button" class="ui-filter-chip" data-news-filter="important" aria-pressed="false">重要 <b>0</b></button>
      <button type="button" class="ui-filter-chip" data-news-filter="maintenance" aria-pressed="false">维护 <b>0</b></button>
      <button type="button" class="ui-filter-chip" data-news-filter="normal" aria-pressed="false">普通 <b>0</b></button>
    </div><div class="ui-news-search-row"><label class="ui-search-input">${icon('search')}<input type="search" id="ui-news-search" placeholder="搜索标题或公告内容…" aria-label="搜索公告"></label>
      <select id="ui-news-sort" aria-label="公告排序"><option value="newest">最新在前</option><option value="oldest">最早在前</option></select></div>
      <div class="ui-news-result" id="ui-news-result" aria-live="polite"></div>`;
    listHead.after(listControls);
    const list = node('div','ui-announcements-items'); list.id = 'ui-announcements-items';
    const existing = $$('.announcement',listing);
    existing.forEach(article => list.append(article));
    $$(':scope > p',listing).forEach(p => p.remove());
    listing.append(list);
    const listEmpty = node('div','ui-empty-state');
    listEmpty.innerHTML = `${icon('news')}<strong>暂无公告</strong><p class="ui-note">发布后会出现在这里，也会显示到首页。</p>`;
    listing.append(listEmpty);
    listing.append(node('p','ui-footnote','公告时间沿用服务器显示时间；筛选和排序不会修改原始公告。'));
    let filter = 'all';
    const search = $('#ui-news-search');
    const sort = $('#ui-news-sort');
    function readRow(article) {
      const level = announcementLevel(article);
      const text = paragraphText($('p',article));
      return {element:article,title:$('h3',article)?.textContent || '',content:text,level,
        date:$('time',article)?.textContent || '',id:$('[name="id"]',article)?.value || ''};
    }
    function collectRows() {
      rows = $$('.announcement',list).map(readRow);
      rows.forEach(row => decorateAnnouncement(row.element));
    }
    function applyFilter() {
      const q = search.value.trim().toLocaleLowerCase();
      let count = 0;
      rows.sort((a,b) => (sort.value === 'oldest' ? 1 : -1) * a.date.localeCompare(b.date));
      rows.forEach(row => {
        const match = (filter === 'all' || row.level === filter) && (row.title + '\n' + row.content).toLocaleLowerCase().includes(q);
        row.element.hidden = !match;
        if (match) count++;
        list.append(row.element);
      });
      $$('[data-news-filter]').forEach(b => {
        const key = b.dataset.newsFilter;
        $('b',b).textContent = key === 'all' ? rows.length : rows.filter(row => row.level === key).length;
        b.classList.toggle('active',key === filter); b.setAttribute('aria-pressed',String(key === filter));
      });
      $('#ui-news-result').textContent = `显示 ${count} / 共 ${rows.length} 则公告`;
      listEmpty.hidden = count > 0;
      $('strong',listEmpty).textContent = rows.length ? '没有找到匹配的公告' : '暂无公告';
      $('p',listEmpty).textContent = rows.length ? '调整关键词或类型筛选后重试。' : '发布后会出现在这里，也会显示到首页。';
      exportButton.disabled = rows.length === 0;
    }
    $$('[data-news-filter]').forEach(b => b.addEventListener('click',() => { filter = b.dataset.newsFilter; applyFilter(); }));
    search.addEventListener('input',applyFilter);
    sort.addEventListener('change',applyFilter);
    exportButton.addEventListener('click',() => {
      if (!rows.length) return;
      const data = rows.map(({id,title,content,level,date}) => ({id,title,content,level,date}));
      download(JSON.stringify({exported_at:dateText(),description:'当前公告列表的只读导出，不含 PIN 或 CSRF',announcements:data},null,2),
        `wow-announcements-${stamp()}.json`, 'application/json;charset=utf-8');

    });

    function showFeedback(text, kind) {
      notices.replaceChildren();
      const item = node('div','flash ' + (kind === 'error' ? 'error' : 'success'),text);
      item.setAttribute('role',kind === 'error' ? 'alert' : 'status');
      notices.append(item);
    }
    function blockWrites(blocked) {
      $$('button[type="submit"]',layout).forEach(b => b.disabled = blocked);
      form.setAttribute('aria-busy',String(pending));
    }
    function safeArticle(item, token) {
      const article = node('article','announcement ' + item.level);
      const head = node('div','announcement-head');
      const labels = node('div');
      labels.append(node('h3','',item.title),node('time','',item.date));
      const f = node('form');
      f.method = 'post'; f.action = announcementUrl();
      for (const [key,value] of Object.entries({csrf:token,action:'delete_announcement',id:item.id,pin:''})) {
        const input = node('input'); input.type='hidden'; input.name=key; input.value=value; f.append(input);
      }
      const remove = button('删除','btn danger'); remove.type='submit'; f.append(remove);
      head.append(labels,f);
      const content = node('p','ui-announcement-content',item.content);
      article.append(head,content);
      bindProtectedForm(f);
      return article;
    }
    function replaceFromResponse(doc) {
      const incoming = $('.card.announcements',doc);
      const token = $('form input[value="add_announcement"]',doc)?.closest('form')?.querySelector('[name="csrf"]')?.value;
      if (!incoming || !token) throw new Error('没有收到可识别的公告页面');
      const data = $$('.announcement',incoming).map(readRow);
      if (data.some(row => !row.id)) throw new Error('公告标识缺失');
      const replacements = data.map(row => safeArticle(row,token));
      list.replaceChildren(...replacements);
      $('[name="csrf"]',form).value = token;
      collectRows(); applyFilter(); blockWrites(pending || uncertain);
    }
    async function readLatest() {
      if (pending) return;
      pending = true; blockWrites(true);
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(),20000);
      try {
        const url = new URL(announcementUrl(),location.href);
        url.searchParams.set('_ui_read',String(Date.now()));
        const response = await fetch(url,{method:'GET',credentials:'same-origin',cache:'no-store',signal:controller.signal});
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const doc = new DOMParser().parseFromString(await response.text(),'text/html');
        replaceFromResponse(doc);
        uncertain = false;
        showFeedback('已重新读取公告列表。请核对是否已发布或删除，再决定下一步操作。','success');

      } catch (err) {
        showUncertain('仍未能读取公告列表，请稍后再次核对。');
      } finally {
        clearTimeout(timeout); pending = false; blockWrites(uncertain);
      }
    }
    function showUncertain(text) {
      uncertain = true;
      showFeedback(text + ' 为防重复操作，写入按钮已暂停；不要直接重复提交。','error');
      const verify = button('重新读取公告列表','btn','refresh');
      verify.addEventListener('click',readLatest);
      notices.append(verify);
    }
    function bindProtectedForm(protectedForm) {
      if (protectedForm.dataset.uiBound) return;
      protectedForm.dataset.uiBound='true';
      protectedForm.addEventListener('submit',async e => {
        e.preventDefault();
        if (pending || uncertain) return;
        if (!protectedForm.reportValidity()) return;
        const action = $('[name="action"]',protectedForm).value;
        const deleting = action === 'delete_announcement';
        const articleTitle = deleting ? $('h3',protectedForm.closest('.announcement'))?.textContent || '该公告' : titleInput.value.trim();
        if (!deleting && (!articleTitle || !contentInput.value.trim())) { toast('公告标题和内容不能为空。','error'); return; }
        const confirmedSignature = signature();
        const pin = await ask({
          title:deleting ? '确认删除公告' : '确认发布公告',
          description:deleting ? `即将删除「${articleTitle}」。网页没有撤销功能，请确认后输入 PIN。` : `即将公开发布「${articleTitle}」。请核对内容后输入现有管理 PIN。`,
          pin:true,danger:deleting,confirm:deleting?'确认删除':'发布公告'
        });
        if (pin === null || pending || uncertain) return;
        pending = true; blockWrites(true);
        submit.textContent = deleting ? '正在处理…' : '正在发布…';
        const input = $('[name="pin"]',protectedForm);
        input.value = pin;
        const data = new FormData(protectedForm);
        input.value = ''; // Payload is a snapshot; no PIN is retained in form or storage.
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(),20000);
        try {
          // Original endpoint and original fields only. No automatic POST retries.
          // A hidden control named "action" shadows HTMLFormElement.action.
          // Resolve the attribute, not the named-property getter.
          const endpoint = new URL(protectedForm.getAttribute('action') || announcementUrl(), location.href);
          if (endpoint.origin !== location.origin) throw new Error('公告提交地址不是本站地址');
          const response = await fetch(endpoint.href,{
            method:'POST',body:data,credentials:'same-origin',cache:'no-store',signal:controller.signal,
            headers:{'Accept':'text/html'}
          });
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const doc = new DOMParser().parseFromString(await response.text(),'text/html');
          const error = $('.flash.error',doc);
          const success = $$('.flash.success',doc).find(el => el.textContent.includes(deleting?'公告已删除':'公告已添加'));
          if (!error && !success) throw new Error('提交结果无法确认');
          replaceFromResponse(doc);
          if (error) {
            showFeedback(error.textContent.trim(),'error');

          } else {
            showFeedback(success.textContent.trim(),'success');

            if (!deleting) {
              const local = readStore('localStorage','announcementDraft');
              const justPublished = {title:data.get('title'),content:data.get('content'),level:data.get('level')};
              if (validDraft(local) && JSON.stringify({title:local.title,content:local.content,level:local.level}) === JSON.stringify(justPublished)) {
                removeStore('localStorage','announcementDraft');
                draftNote.textContent = '已发布；对应的本地草稿已清除。';
              }
              // Do not erase any text typed while the request was in flight.
              if (signature() === confirmedSignature) {
                titleInput.value='';contentInput.value='';levelInput.value='normal';savedSignature=signature();updatePreview();
              }
            }
          }
        } catch (err) {
          const detail = err?.name === 'AbortError' ? '请求超时' : (err?.message || '连接中断');
          showUncertain(`${detail}，无法确认服务器是否已完成操作。`);

        } finally {
          clearTimeout(timeout);
          data.delete('pin');
          pending = false; submit.textContent='确认并发布'; blockWrites(uncertain);
        }
      });
      protectedForm.removeAttribute('onsubmit'); // The original inline prompt remains available if this script fails to load.
    }
    $$('form',layout).forEach(bindProtectedForm);
    window.addEventListener('beforeunload',e => {
      const dirty = signature() !== savedSignature && (titleInput.value.trim() || contentInput.value.trim());
      if (pending || dirty) { e.preventDefault(); e.returnValue=''; }
    });
    updatePreview(); savedSignature = signature(); collectRows(); applyFilter();
    $$('[data-ui-nav]').forEach(a => {
      const active = a.dataset.uiNav === 'announcements';
      a.classList.toggle('active',active);
      if(active)a.setAttribute('aria-current','page');else a.removeAttribute('aria-current');
    });

  }

  enhanceShell();
  if (isHome) buildHome();
  else buildAnnouncements();

  document.addEventListener('keydown',e => {
    const target = e.target;
    const editing = target instanceof HTMLElement && (target.matches('input,textarea,select') || target.isContentEditable);
    if (isAnnouncements && e.key === '/' && !editing && !state.dialogOpen && !e.ctrlKey && !e.altKey && !e.metaKey) {
      e.preventDefault();
      $('#ui-news-search')?.focus();
    }
  });
})();
