(() => {
  'use strict';
  const i18n = window.MarketI18n;
  const t = (message, values) => i18n ? i18n.t(message, values) : typeof message !== 'string' ? '' : message.replace(/\{(\w+)\}/g, (_, key) => String(values?.[key] ?? `{${key}}`));
  const base = new URL('./', document.baseURI);
  const $ = selector => document.querySelector(selector);
  const dialog = $('#tool-dialog');
  const state = { data: null, tools: [], loading: false, pendingTab: null, activeSlug: null, returnFocus: null, activeTab: 'overview' };
  const strings = value => Array.isArray(value) ? value.filter(item => typeof item === 'string') : [];
  const h = (tag, attrs = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) if (value !== null && value !== undefined) node.setAttribute(key, String(value));
    for (const child of children.flat(Infinity)) if (child !== null && child !== undefined) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    return node;
  };
  const external = { target: '_blank', rel: 'noopener noreferrer' };
  function url(value) {
    if (typeof value !== 'string' || !value.trim()) return null;
    try {
      // Older metadata used /assets or /packages. Keep those within a mounted
      // marketplace prefix while allowing explicit absolute HTTPS source links.
      const path = value.startsWith('/') && !value.startsWith('//') ? value.slice(1) : value;
      const resolved = new URL(path, base);
      return ['http:', 'https:'].includes(resolved.protocol) ? resolved.href : null;
    } catch { return null; }
  }
  const sourceURL = () => url(state.data?.macHelper?.sourceUrl) || 'https://github.com/bosstwobread/LocalAIBaseTools';
  const helperURL = () => url(state.data?.macHelper?.downloadUrl);
  const image = (src, alt, attrs = {}) => h('img', { src: url(i18n?.previewSource(src) || src) || new URL('assets/mac-helper.png', base).href, alt: i18n?.previewAlt(src, alt) || alt, loading: 'lazy', ...attrs });
  const textLink = (label, href, extra = {}) => h('a', { class: 'text-link', href, ...extra }, label, h('span', { 'aria-hidden': 'true' }, '↗'));
  function normalize(tool) {
    if (!tool || typeof tool.id !== 'string' || typeof tool.slug !== 'string' || typeof tool.name !== 'string' || !['mac-source', 'browser'].includes(tool.kind)) return null;
    if (tool.kind === 'mac-source' && tool.runtime !== undefined && !['javascript', 'native'].includes(tool.runtime)) return null;
    return { ...tool, runtime: tool.kind === 'mac-source' ? (tool.runtime === 'native' ? 'native' : 'javascript') : 'browser', summary: String(tool.summary || ''), description: String(tool.description || tool.summary || ''), category: String(tool.category || 'Other'), platforms: strings(tool.platforms), features: strings(tool.features), permissions: strings(tool.permissions), installSteps: strings(tool.installSteps), keywords: strings(tool.keywords), exampleQueries: strings(tool.exampleQueries), limitations: strings(tool.limitations), translations: tool.translations && typeof tool.translations === 'object' ? tool.translations : {}, screenshots: Array.isArray(tool.screenshots) ? tool.screenshots.filter(item => item && typeof item.src === 'string') : [] };
  }
  const LOCAL_SERVICE = 'http://127.0.0.1:43827';
  const discovery = { mode: 'keywords', running: null, token: null, expiresAt: 0, showConnectionHelp: false, matches: null, message: '', emptyReason: '' };
  const toolText = (tool, text) => tool.translations?.[i18n?.locale || 'en']?.[text] || t(text);
  const queryValue = () => $('#need-query').value.trim();
  const validQuery = value => Boolean(value) && !value.includes('\0') && value.length <= 2000 && new TextEncoder().encode(value).length <= 8000;
  const connected = () => Boolean(discovery.token) && Date.now() < discovery.expiresAt;
  const connectionMessage = code => ({
    permission: 'Allow local or loopback network access for this website in your browser’s site settings, then try Find with AI again.',
    incompatible: 'Update MacHelper to version 6.5 or later, then try Find with AI again.',
    unauthorized: 'Could not renew the MacHelper connection. Try Find with AI again.',
    timeout: 'Connection timed out. Check that MacHelper is running, then try Find with AI again.'
  })[code] || 'Install or open MacHelper, then try Find with AI again.';
  function localError(code, status) { const error = new Error(code); error.code = code; error.status = status; return error; }
  function requireCurrent(pending) {
    if (discovery.running !== pending || pending.controller.signal.aborted) throw localError('cancelled');
  }
  async function localPermission() {
    // Permission names differ between browser versions. The explicit fetch is
    // authoritative when a browser cannot report its local-access permission.
    for (const name of ['loopback-network', 'local-network-access']) {
      try { const result = await navigator.permissions.query({ name }); return result.state; }
      catch { /* Older browsers expose neither name. */ }
    }
    return 'unknown';
  }
  async function localRequest(path, { body, token, signal, timeout = 10000, keepalive = false } = {}) {
    const controller = new AbortController();
    let timedOut = false;
    const abort = () => controller.abort();
    if (signal?.aborted) abort();
    signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeout);
    try {
      const headers = { 'X-MacHelper-Client': 'extension-market' };
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      if (token) headers.Authorization = `Bearer ${token}`;
      const response = await fetch(`${LOCAL_SERVICE}${path}`, {
        method: body === undefined ? 'GET' : 'POST', headers,
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        cache: 'no-store', credentials: 'omit', mode: 'cors', redirect: 'error', referrerPolicy: 'no-referrer',
        signal: controller.signal, keepalive
      });
      const result = await response.json();
      if (!response.ok || result?.ok !== true) throw localError(typeof result?.code === 'string' ? result.code : 'search_failed', response.status);
      return result;
    } catch (error) {
      if (timedOut) throw localError('timeout');
      if (signal?.aborted) throw localError('cancelled');
      if (error?.code) throw error;
      if (await localPermission() === 'denied') throw localError('permission');
      throw localError('unavailable');
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
    }
  }
  function renderDiscovery() {
    const isAI = discovery.mode === 'description';
    $('#keyword-mode').setAttribute('aria-pressed', String(!isAI));
    $('#description-mode').setAttribute('aria-pressed', String(isAI));
    $('#description-search').hidden = !isAI;
    $('#filters').classList.toggle('description-mode',isAI);
    $('#search').closest('label').hidden = isAI;
    $('#find-with-ai').disabled = Boolean(discovery.running) || !state.data;
    $('#cancel-ai-search').hidden = !discovery.running;
    $('#local-connection-help').hidden = !discovery.showConnectionHelp;
    $('#need-query').disabled = Boolean(discovery.running);
    $('#discovery-status').textContent = discovery.message ? t(discovery.message) : discovery.emptyReason;
    $('#discovery-status').setAttribute('aria-busy', String(Boolean(discovery.running)));

  }
  async function establishSession(pending) {
    requireCurrent(pending);
    pending.searchSent = false; pending.token = null;
    clearTimeout(pending.timeout); pending.timeout = null;
    discovery.token = null; discovery.expiresAt = 0;
    discovery.message = 'Connecting to MacHelper…'; renderDiscovery();
    const permission = await localPermission();
    requireCurrent(pending);
    if (permission === 'denied') throw localError('permission');
    const status = await localRequest('/v1/status', { signal: pending.controller.signal, timeout: 30000 });
    requireCurrent(pending);
    const version = typeof status.version === 'string' && status.version.match(/^(\d+)\.(\d+)\.(\d+)$/);
    if (status.protocolVersion !== 1 || !version || version[0] !== status.version || Number(version[1]) < 6 || (Number(version[1]) === 6 && Number(version[2]) < 5)) throw localError('incompatible');
    const session = await localRequest('/v1/session', { body: {}, signal: pending.controller.signal });
    requireCurrent(pending);
    if (typeof session.token !== 'string' || session.token.length !== 64 || !/^[a-f0-9]{64}$/.test(session.token) || !Number.isInteger(session.expiresIn) || session.expiresIn < 1 || session.expiresIn > 1800) throw localError('unavailable');
    discovery.token = session.token; discovery.expiresAt = Date.now() + session.expiresIn * 1000;
  }
  async function requestSearch(pending) {
    requireCurrent(pending);
    pending.token = discovery.token; pending.searchSent = true;
    discovery.message = 'Finding extensions with your AI…';
    pending.timeout = setTimeout(()=>{
      if (discovery.running !== pending) return;
      cancelDiscovery(false); discovery.message = 'Search timed out. Please try again.'; renderDiscovery();
    }, 180000);
    renderDiscovery();
    return localRequest('/v1/search', {
      body: { requestId:pending.id, query:pending.query, language:pending.language },
      token:pending.token, signal:pending.controller.signal, timeout:185000
    });
  }
  function updateNeed() {
    if (!discovery.running && discovery.matches !== null) {
      discovery.matches=null; discovery.message=''; discovery.emptyReason='';
      if(state.data) renderCards();
    }
    renderDiscovery();
  }
  function chooseSearchMode(mode) {
    if (mode !== discovery.mode) cancelDiscovery(false);
    discovery.mode=mode;
    renderDiscovery();
    if (state.data) renderCards();
  }
  function cancelDiscovery(showMessage = true) {
    const pending=discovery.running;
    discovery.running=null;
    if(pending) {
      clearTimeout(pending.timeout);
      pending.controller.abort();
      if (pending.searchSent && pending.token) localRequest('/v1/cancel', {
        body: { requestId:pending.id }, token:pending.token, timeout:5000, keepalive:true
      }).catch(()=>{});
      if(showMessage) discovery.message='Search cancelled.';
    }
    renderDiscovery();
  }
  async function searchWithAI() {
    if(discovery.running || !state.data) return;
    const query=queryValue();
    if(!validQuery(query)) {
      discovery.emptyReason='';
      discovery.message='Describe your need in 1–2,000 characters.'; renderDiscovery(); return;
    }
    // Capture the intended data once. Interface changes while connecting must
    // not change the query or answer language sent for this explicit click.
    const id=window.crypto?.randomUUID?.() || `search_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const pending={ id, query, language:i18n?.locale || 'en', token:null, controller:new AbortController(), timeout:null, searchSent:false };
    discovery.running=pending; discovery.matches=null; discovery.emptyReason=''; discovery.showConnectionHelp=false;
    renderDiscovery();renderCards();
    try {
      if (!connected()) await establishSession(pending);
      let response;
      try { response = await requestSearch(pending); }
      catch (error) {
        requireCurrent(pending);
        // HTTP 401 is returned by MacHelper before invoking inference. Renew
        // once for a restarted app/evicted session; never repeat other failures.
        if (error.code !== 'unauthorized' || error.status !== 401) throw error;
        await establishSession(pending);
        response = await requestSearch(pending);
      }
      requireCurrent(pending);
      const result=response.search;
      if(!result || !Array.isArray(result.matches) || result.matches.length > 5) throw localError('search_failed');
      const known=new Set(state.tools.map(tool=>tool.id)), seen=new Set();
      discovery.matches=result.matches.filter(match => match && known.has(match.id) && !seen.has(match.id) && ['good','partial'].includes(match.fit) && typeof match.reason==='string' && match.reason.length <= 4000 && seen.add(match.id));
      discovery.emptyReason=!discovery.matches.length && typeof result.noMatchReason==='string' ? result.noMatchReason.slice(0,4000) : '';
      discovery.message=discovery.matches.length || discovery.emptyReason ? '' : 'No matching extensions found. Try describing your need differently.';
    } catch (error) {
      if(discovery.running!==pending) return;
      if (['unauthorized','unavailable','permission','incompatible','timeout'].includes(error.code)) {
        discovery.token=null; discovery.expiresAt=0; discovery.showConnectionHelp=true; discovery.message=connectionMessage(error.code);
      } else discovery.message = error.code === 'busy' ? 'MacHelper is busy. Wait for its current search to finish, then try again.' : 'Search failed. Check AI Connection in MacHelper and try again.';
    } finally {
      if(discovery.running===pending) { clearTimeout(pending.timeout); discovery.running=null; renderDiscovery();renderCards(); }
    }
  }
  async function loadCatalog() {
    if (state.loading) return;
    state.loading = true;
    $('#catalog-error').hidden = true;
    $('#catalog-empty').hidden = true;
    $('#extension-grid').hidden = false;
    $('#extension-grid').setAttribute('aria-busy', 'true');
    $('#extension-grid').replaceChildren(h('div', { class: 'loading-note' }, h('span', { class: 'loading-dot', 'aria-hidden': 'true' }), t("Gathering the tools…")));
    $('#result-count').textContent = t("Loading the collection…");
    try {
      const response = await fetch(new URL('data/extensions.json', document.baseURI), { cache: 'no-cache' });
      if (!response.ok) throw new Error('Catalog unavailable');
      const data = await response.json();
      if (data.schemaVersion !== 1 || !Array.isArray(data.extensions)) throw new Error('Unsupported catalog');
      const tools = data.extensions.map(normalize).filter(Boolean);
      if (tools.length !== data.extensions.length) throw new Error('Invalid extension metadata');
      state.data = data;
      state.tools = tools;
      populateFilters();
      renderDiscovery();
      renderCards();
      updateHelperLinks();
      $('#spotlight').hidden = !tools.some(tool => tool.slug === 'translation');
      route();
    } catch {
      $('#extension-grid').hidden = true;
      $('#catalog-error').hidden = false;
      $('#result-count').textContent = t("Collection unavailable");
    } finally {
      state.loading = false;
      $('#extension-grid').setAttribute('aria-busy', 'false');
    }
  }
  function populateFilters() {
    for (const [selector, values, all] of [
      ['#category', [...new Set(state.tools.map(tool => tool.category))].sort(), t("All categories")],
      ['#platform', [...new Set(state.tools.flatMap(tool => tool.platforms))].sort(), t("All platforms")]
    ]) {
      const select = $(selector);
      const previous = select.value;
      select.replaceChildren(h('option', { value: 'all' }, all), ...values.map(value => h('option', { value }, t(value))));
      if (values.includes(previous)) select.value = previous;
    }
  }
  function renderCards() {
    const query = discovery.mode === 'keywords' ? $('#search').value.trim().toLocaleLowerCase() : '';
    const category = $('#category').value;
    const platform = $('#platform').value;
    const matched = discovery.mode === 'description' && discovery.matches !== null ? discovery.matches.map(match=>state.tools.find(tool=>tool.id===match.id)).filter(Boolean) : state.tools;
    const filtered = matched.filter(tool => {
      const searchable = [tool.name, tool.summary, tool.description, tool.category, ...tool.features, ...tool.platforms, ...tool.keywords, ...tool.exampleQueries, toolText(tool,tool.summary), toolText(tool,tool.description), t(tool.category), ...tool.features.map(feature => toolText(tool,feature)), ...tool.exampleQueries.map(value=>toolText(tool,value))].join(' ').toLocaleLowerCase();
      return (!query || searchable.includes(query)) && (category === 'all' || tool.category === category) && (platform === 'all' || tool.platforms.includes(platform));
    });
    $('#extension-grid').replaceChildren(...filtered.map(tool=>card(tool, discovery.mode === 'description' ? discovery.matches?.find(match=>match.id===tool.id) : null)));
    translationDemos.prune();
    translationDemos.refresh();
    $('#catalog-empty').hidden = filtered.length !== 0;
    $('#result-count').textContent = filtered.length === state.tools.length ? t('Extensions: {count}', { count: filtered.length }) : t('Extensions: {count} / {total}', { count: filtered.length, total: state.tools.length });
    $('#clear-filters').hidden = !query && category === 'all' && platform === 'all';
  }
  function card(tool, match = null) {
    const details = `#extension/${encodeURIComponent(tool.slug)}`;
    const shot = tool.screenshots[0];
    const visual = tool.id === 'com.localaibasetools.translation'
      ? h('div', { class: 'card-visual' }, translationDemos.create('card'))
      : h('a', { class: 'card-visual', href: details, 'aria-label': t('Explore {name}', { name: tool.name }) }, image(shot?.src || tool.icon, t(shot?.alt) || t('{name} interface preview', { name: tool.name }), { width: '1160', height: '720' }), h('span', { class: 'preview-label' }, t("Interface preview")));
    const install = h('button', { type: 'button', class: 'card-install', 'aria-label': t('Installation options for {name}', { name: tool.name }) }, tool.kind === 'mac-source' ? t("Add to MacHelper ↗") : t("Get extension ↗"));
    install.addEventListener('click', () => navigate(tool.slug, 'install'));
    return h('article', { class: 'extension-card' }, visual,
      h('div', { class: 'card-content' },
        h('div', { class: 'card-kicker' }, h('span', {}, tool.kind === 'mac-source' ? (tool.runtime === 'native' ? t("NATIVE MACOS TOOL") : t("MACOS SOURCE TOOL")) : t("BROWSER COMPANION")), h('span', { class: 'card-version' }, `v${tool.version || '—'}`)),
        h('div', { class: 'card-heading' }, image(tool.icon, '', { class: 'card-icon', width: '42', height: '42' }), h('div', {}, h('h3', {}, h('a', { href: details }, tool.name)), h('p', {}, t(tool.category)))),
        h('p', { class: 'card-summary' }, toolText(tool,tool.summary)),
        match && h('div', { class:'discovery-match' }, h('strong',{},t(match.fit==='good' ? 'Good fit' : 'Partial fit')),h('p',{},match.reason)),
        h('ul', { class: 'card-features' }, tool.features.slice(0, 2).map(feature => h('li', {}, toolText(tool,feature)))),
        h('div', { class: 'card-bottom' }, h('div', { class: 'platform-labels', 'aria-label': t("Platforms") }, tool.platforms.map(label => h('span', {}, label))), h('div', { class: 'card-links' }, textLink(t("Details"), details, { 'aria-label': t('Details for {name}', { name: tool.name }) }), install))));
  }
  function resetFilters() {
    cancelDiscovery(false); discovery.matches=null; discovery.mode='keywords'; discovery.message=''; discovery.emptyReason='';
    $('#need-query').value=''; renderDiscovery();
    $('#search').value = '';
    $('#category').value = 'all';
    $('#platform').value = 'all';
    if (state.data) renderCards();
    $('#search').focus();
  }
  function updateHelperLinks() {
    const helper = state.data?.macHelper || {};
    const download = helperURL();
    document.querySelectorAll('[data-helper-download]').forEach(link => {
      link.href = download || sourceURL();
      if (download) {
        link.setAttribute('download', '');
        link.removeAttribute('target'); link.removeAttribute('rel');
        const header = link.classList.contains('header-download');
        link.replaceChildren(document.createTextNode(header ? t("Get MacHelper ") : t("Download for Mac ")), h('span', { 'aria-hidden': 'true' }, header ? '↗' : '↓'));
      }
      else {
        link.textContent = t("MacHelper source ↗");
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
      }
    });
    document.querySelectorAll('[data-helper-source]').forEach(link => { link.href = sourceURL(); });
    $('#helper-meta').textContent = [helper.version && `v${helper.version}`, helper.minimumOS || 'macOS 14+', helper.architecture || 'Apple Silicon', t(helper.releaseChannel || 'Developer preview')].filter(Boolean).join(' · ');
  }
  function navigate(slug, tab = 'overview') {
    state.pendingTab = tab;
    const hash = `#extension/${encodeURIComponent(slug)}`;
    if (location.hash === hash) openTool(slug, tab);
    else location.hash = hash;
  }
  function route() {
    const match = location.hash.match(/^#extension\/([^/?]+)/);
    if (match && state.data) {
      let slug;
      try { slug = decodeURIComponent(match[1]); } catch { slug = ''; }
      openTool(slug, state.pendingTab || 'overview');
      state.pendingTab = null;
    } else if (dialog.open) dialog.close();
  }
  function openTool(slug, tab) {
    const tool = state.tools.find(item => item.slug === slug);
    if (!dialog.open) {
      state.returnFocus = document.activeElement;
    }
    state.activeSlug = slug;
    const close = h('button', { class: 'dialog-close', type: 'button', 'aria-label': t("Close details") }, '×');
    close.addEventListener('click', () => dialog.close());
    const content = $('#dialog-content');
    if (!tool) {
      content.replaceChildren(h('div', { class: 'dialog-topbar' }, h('p', { class: 'eyebrow' }, t("THE COLLECTION")), close), h('div', { class: 'dialog-body' }, h('h2', { id: 'dialog-title' }, t("Tool not found.")), h('p', { class: 'detail-description' }, t("This link may have changed. Close this window to browse the current collection."))));
    } else {
      const overviewTab = h('button', { type: 'button', role: 'tab', id: 'overview-tab', 'aria-controls': 'overview-panel', 'aria-selected': 'false' }, t("Overview"));
      const installTab = h('button', { type: 'button', role: 'tab', id: 'install-tab', 'aria-controls': 'install-panel', 'aria-selected': 'false' }, t("Installation"));
      const overview = h('section', { id: 'overview-panel', role: 'tabpanel', 'aria-labelledby': 'overview-tab', class: 'dialog-body' }, overviewContent(tool));
      const installation = h('section', { id: 'install-panel', role: 'tabpanel', 'aria-labelledby': 'install-tab', class: 'dialog-body' }, installContent(tool));
      const selectTab = (name, focus = false) => {
        const isOverview = name === 'overview';
        state.activeTab = isOverview ? 'overview' : 'install';
        overviewTab.setAttribute('aria-selected', String(isOverview));
        installTab.setAttribute('aria-selected', String(!isOverview));
        overviewTab.tabIndex = isOverview ? 0 : -1;
        installTab.tabIndex = isOverview ? -1 : 0;
        overview.hidden = !isOverview;
        installation.hidden = isOverview;
        translationDemos.refresh();
        if (focus) (isOverview ? overviewTab : installTab).focus();
      };
      overviewTab.addEventListener('click', () => selectTab('overview'));
      installTab.addEventListener('click', () => selectTab('install'));
      const tablist = h('div', { class: 'dialog-tabs', role: 'tablist', 'aria-label': t("Extension details") }, overviewTab, installTab);
      tablist.addEventListener('keydown', event => {
        if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
          event.preventDefault();
          selectTab(event.key === 'Home' ? 'overview' : event.key === 'End' ? 'install' : overview.hidden ? 'overview' : 'install', true);
        }
      });
      content.replaceChildren(h('div', { class: 'dialog-topbar' }, h('p', { class: 'eyebrow' }, `${tool.kind === 'mac-source' ? t("MACOS TOOL") : t("BROWSER COMPANION")} / ${t(tool.category)}`), close), h('div', { class: 'dialog-heading' }, image(tool.icon, '', { width: '60', height: '60' }), h('div', {}, h('h2', { id: 'dialog-title' }, tool.name), h('p', {}, `v${tool.version || '—'} · ${t('Free & open source')}`))), tablist, overview, installation);
      selectTab(tab === 'install' ? 'install' : 'overview');
    }
    if (!dialog.open) { dialog.showModal(); document.body.classList.add('modal-open'); }
    translationDemos.prune();
    translationDemos.refresh();
    dialog.scrollTop = 0;
    close.focus({ preventScroll: true });
  }
  function overviewContent(tool) {
    const main = h('div', {}, h('p', { class: 'detail-description' }, toolText(tool,tool.description)));
    if (tool.features.length) main.append(h('h3', { class: 'detail-subheading' }, t("What it does")), h('ul', { class: 'detail-list' }, tool.features.map(feature => h('li', {}, toolText(tool,feature)))));
    if(tool.limitations.length) main.append(h('h3',{class:'detail-subheading'},t('Limitations')),h('ul',{class:'detail-list'},tool.limitations.map(value=>h('li',{},toolText(tool,value)))));
    if (tool.id === 'com.localaibasetools.translation') main.append(translationDemos.create('detail'));
    else for (const shot of tool.screenshots) main.append(h('figure', { class: 'detail-preview' }, image(shot.src, t(shot.alt) || t('{name} interface preview', { name: tool.name }), { width: '1160', height: '720' }), h('figcaption', {}, t(shot.caption) || t("Interface preview · Example content"))));
    if (tool.permissions.length) main.append(h('h3', { class: 'detail-subheading' }, t("Access this tool uses")), h('ul', { class: 'detail-list' }, tool.permissions.map(permission => h('li', {}, permissionLabel(permission)))));
    const facts = h('dl', {}, h('dt', {}, t("Platforms")), h('dd', {}, tool.platforms.join(' · ')), h('dt', {}, t("Package")), h('dd', {}, tool.kind === 'mac-source' ? (tool.runtime === 'native' ? t("Editable native Swift source") : t("Editable JavaScript source")) : t("Browser extension ZIP")), h('dt', {}, t("Version")), h('dd', {}, tool.version || '—'));
    if (tool.updatedAt) {
      const date = new Date(`${String(tool.updatedAt).slice(0, 10)}T00:00:00`);
      if (!Number.isNaN(date.valueOf())) facts.append(h('dt', {}, t("Updated")), h('dd', {}, new Intl.DateTimeFormat(i18n?.locale || 'en', { dateStyle: 'medium' }).format(date)));
    }
    const share = h('button', { type: 'button', class: 'link-button' }, t("Copy details link ↗"));
    share.addEventListener('click', () => copy(new URL(`#extension/${encodeURIComponent(tool.slug)}`, base).href, share));
    const side = h('aside', { class: 'detail-facts' }, facts, textLink(t("View complete source"), url(tool.sourceUrl) || sourceURL(), external), share);
    if (tool.kind === 'mac-source') {
      main.append(h('h3', { class: 'detail-subheading' }, t("Make it yours")),
        h('p', { class: 'detail-description' }, t("In MacHelper → Extensions, choose this installed tool → Edit Source. Change its code, prompts, or settings, then save. MacHelper chooses the runtime from the manifest; a valid saved edit replaces only that extension’s worker.")),
        textLink(t("Create or customize with your AI assistant"), new URL('developer-guide.html', base).href));
      side.append(textLink(t("Download the AI extension guide"), new URL('AI_EXTENSION_GUIDE.md', base).href, { download: 'AI_EXTENSION_GUIDE.md' }));
    }
    return h('div', { class: 'detail-grid' }, main, side);
  }
  function permissionLabel(value) {
    return ({ 'selection.read': t("Read selected text through macOS Accessibility, with automatic temporary copying and clipboard restoration when safe."), 'selection.replace': t("Replace unchanged selected text in a supported editable field only when you click Apply."), 'selection.paste': t("Apply can paste into a verified selection. Paste uses the current selection in the original window when its position is unavailable. Both clipboard actions leave the result on the clipboard."), 'clipboard.read': t("Legacy clipboard declaration (no shared clipboard reader)"), 'ai.transform': t("Send text to your shared AI connection for an explicit action."), 'ui.panel': t("Display a nearby floating result panel."), 'native.execute': t("Compile and run trusted native Swift code as your Mac user; a worker process is not an OS sandbox."), nativeMessaging: t("Connect the browser extension to MacHelper on your Mac."), storage: t("Save extension preferences in browser storage.") })[value] || value;
  }
  function installContent(tool) {
    const sourceTool = tool.kind === 'mac-source';
    const container = h('div');
    const callout = h('div', { class: 'install-callout' });
    const packageURL = url(tool.packageUrl);
    if (sourceTool) {
      const catalog = url(tool.catalogUrl || 'catalog.json');
      const scheme = new URL('machelper://install');
      scheme.searchParams.set('catalog', catalog);
      scheme.searchParams.set('extension', tool.id);
      const open = h('a', { class: 'button button-blue', href: scheme.href }, t("Open MacHelper"), h('span', { 'aria-hidden': 'true' }, '↗'));
      const installStatus = h('p', { class: 'install-status', role: 'status' });
      open.addEventListener('click', () => { installStatus.textContent = t("If MacHelper didn’t open, install it below, then try again. Your browser may ask permission to open the app."); });
      callout.append(h('h3', {}, t('Add {name} to MacHelper', { name: tool.name })), h('p', {}, t("Open the MacHelper app to install the complete editable tool package and review its requested access.")), open, h('p', { class: 'install-help' }, t("This website cannot check whether MacHelper is installed on your Mac.")), installStatus);
      const fallbacks = h('div', { class: 'install-fallbacks' });
      fallbacks.append(textLink(helperURL() ? t("Download MacHelper first") : t("Build MacHelper from source"), helperURL() || sourceURL(), helperURL() ? { download: '' } : external));
      if (packageURL) fallbacks.append(textLink(t("Download complete tool source"), packageURL, { download: '' }));
      const catalogCopy = h('button', { type: 'button', class: 'link-button' }, t("Copy catalog URL"));
      catalogCopy.addEventListener('click', () => copy(catalog, catalogCopy));
      fallbacks.append(catalogCopy);
      container.append(callout, fallbacks);
      if (tool.runtime === 'native') container.append(h('p', { class: 'install-help' }, t("Native Swift source requires MacHelper 6 and Xcode Command Line Tools. Review native.execute before enabling. Saved code is compiled locally and its worker is replaced without restarting MacHelper.")));
    } else {
      callout.append(h('h3', {}, t("Add the browser companion")), h('p', {}, t("For Chrome or Edge on your Mac. Install and open MacHelper first so the extension can use your shared AI connection.")));
      if (packageURL) callout.append(h('a', { class: 'button button-blue', href: packageURL, download: '' }, t("Download extension ZIP"), h('span', { 'aria-hidden': 'true' }, '↓')));
      callout.append(h('p', { class: 'install-help' }, t("Install from the ZIP with Developer mode → Load unpacked. Chrome Web Store and Edge Add-ons listings are not available yet.")));
      container.append(callout);
      const pages = h('div', { class: 'browser-pages' });
      for (const address of ['chrome://extensions', 'edge://extensions']) {
        const button = h('button', { type: 'button', 'aria-label': t('Copy {address}', { address }) }, t("Copy"));
        button.addEventListener('click', () => copy(address, button));
        pages.append(h('div', { class: 'browser-page' }, h('code', {}, address), button));
      }
      container.append(pages);
    }
    if (tool.installSteps.length) container.append(h('h3', { class: 'detail-subheading' }, t("Installation, step by step")), h('ol', { class: 'install-steps' }, tool.installSteps.map(step => h('li', {}, toolText(tool,step)))));
    const preview = /preview/i.test(state.data?.macHelper?.releaseChannel || t("Developer preview"));
    container.append(h('p', { class: 'install-footnote' }, t('MacHelper supports {architecture}, {minimumOS}. Unzip the app, move it to Applications, and open it.', { architecture: state.data?.macHelper?.architecture || 'Apple Silicon', minimumOS: state.data?.macHelper?.minimumOS || 'macOS 14+' }) + ' ' + (preview ? t('This developer preview is not notarized; macOS may require you to review it in Privacy & Security.') + ' ' : '') + t('Prefer to build it yourself? The full source is available below.')),
      h('p', { class: 'install-footnote' }, t('Optional, off by default: MacHelper → General → Improve compatibility with Electron apps requests full Accessibility in supporting apps. It may change VS Code folding/minimap behavior. Reselect text after enabling.')),
      h('p', { class: 'install-footnote' }, t("If Accessibility cannot read a selection, MacHelper temporarily copies it and restores the clipboard when safe.")),
      h('p', { class: 'install-footnote' }, t("Clipboard snapshots stay in memory for the capture attempt. They are never saved to files, logged, or sent to AI.")),
      textLink(t("Review the project source"), sourceURL(), external));
    return container;
  }
  async function copy(value, sender) {
    if (!value) return;
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(value);
      toast(t("Copied to clipboard."));
    } catch {
      let input = sender.parentElement.querySelector('.copy-fallback');
      if (!input) {
        input = h('input', { class: 'copy-fallback', type: 'text', readonly: '', 'aria-label': t("Copy this link manually") });
        sender.parentElement.append(input);
      }
      input.value = value;
      input.focus(); input.select();
      toast(t("Select and copy the link manually."));
    }
  }
  let toastTimer;
  function toast(message) {
    const node = $('#toast');
    node.textContent = message; node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.hidden = true; }, 3500);
  }
  function setupTranslationDemos() {
    const original = $('#translation-demo');
    const template = original.cloneNode(true);
    const reducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)');
    const demos = new Map();
    let sequence = 0;
    function localize(demo) {
      demo.querySelectorAll('[data-preview-key]').forEach(node => {
        const text = i18n?.previewText(node.dataset.previewKey);
        if (text) node.textContent = text;
        node.lang = i18n?.locale || 'en';
      });
    }
    function update(demo, entry) {
      const insideDialog = demo.closest('dialog');
      const playing = demo.isConnected && entry.visible && !entry.stopped && !document.hidden && !reducedMotion?.matches
        && !demo.closest('[hidden]') && (!insideDialog || insideDialog.open) && (!dialog.open || insideDialog === dialog);
      demo.classList.toggle('demo-playing', Boolean(playing));
      const control = demo.querySelector('.demo-control');
      const key = playing ? 'demo.stop' : 'demo.replay';
      control.dataset.previewKey = key;
      control.textContent = i18n?.previewText(key) || (playing ? 'Stop demo' : 'Replay demo');
    }
    const observer = typeof IntersectionObserver === 'function' ? new IntersectionObserver(entries => {
      for (const item of entries) {
        const entry = demos.get(item.target);
        if (!entry) continue;
        entry.visible = item.isIntersecting && item.intersectionRatio >= 0.2;
        update(item.target, entry);
      }
    }, { threshold: [0, 0.2] }) : null;
    function refresh() { for (const [demo, entry] of demos) update(demo, entry); }
    function register(demo) {
      const entry = { visible: !observer, stopped: false };
      demos.set(demo, entry);
      localize(demo);
      const control = demo.querySelector('.demo-control');
      control.hidden = false;
      control.addEventListener('click', () => {
        entry.stopped = demo.classList.contains('demo-playing');
        update(demo, entry);
      });
      observer?.observe(demo);
      update(demo, entry);
      return demo;
    }
    function create(placement) {
      const demo = template.cloneNode(true);
      const id = `translation-demo-${++sequence}`;
      demo.id = id;
      demo.classList.add(`demo-${placement}`);
      demo.querySelector('#demo-title').id = `${id}-title`;
      demo.querySelector('#demo-summary').id = `${id}-summary`;
      demo.setAttribute('aria-labelledby', `${id}-title`);
      demo.setAttribute('aria-describedby', `${id}-summary`);
      return register(demo);
    }
    function prune() {
      for (const [demo] of demos) if (!demo.isConnected) {
        observer?.unobserve(demo);
        demo.classList.remove('demo-playing');
        demos.delete(demo);
      }
    }
    register(original);
    $('#translation-spotlight').append(create('spotlight'));
    refresh();
    document.addEventListener('visibilitychange', refresh);
    window.addEventListener('market-language-change', () => {
      for (const [demo] of demos) localize(demo);
      refresh();
    });
    reducedMotion?.addEventListener('change', refresh);
    window.addEventListener('pagehide', () => {
      for (const [demo] of demos) demo.classList.remove('demo-playing');
      observer?.disconnect();
    });
    window.addEventListener('pageshow', () => {
      for (const [demo] of demos) observer?.observe(demo);
      refresh();
    });
    return { create, prune, refresh };
  }
  const translationDemos = setupTranslationDemos();
  $('#keyword-mode').addEventListener('click',()=>chooseSearchMode('keywords'));
  $('#description-mode').addEventListener('click',()=>chooseSearchMode('description'));
  $('#need-query').addEventListener('input',updateNeed);
  $('#find-with-ai').addEventListener('click',searchWithAI);
  $('#cancel-ai-search').addEventListener('click',()=>cancelDiscovery());
  window.addEventListener('pagehide',()=>{
    cancelDiscovery(false);
    discovery.token=null; discovery.expiresAt=0;
  });
  window.addEventListener('pageshow',renderDiscovery);
  $('#filters').addEventListener('submit', event => event.preventDefault());
  $('#search').addEventListener('input', () => { if (state.data) renderCards(); });
  $('#category').addEventListener('change', () => { if (state.data) renderCards(); });
  $('#platform').addEventListener('change', () => { if (state.data) renderCards(); });
  $('#clear-filters').addEventListener('click', resetFilters);
  $('#reset-empty').addEventListener('click', resetFilters);
  $('#retry-catalog').addEventListener('click', loadCatalog);
  window.addEventListener('hashchange', route);
  dialog.addEventListener('close', () => {
    document.body.classList.remove('modal-open');
    translationDemos.refresh();
    state.activeSlug = null;
    if (location.hash.startsWith('#extension/')) history.replaceState(null, '', '#browse');
    if (state.returnFocus?.isConnected) state.returnFocus.focus({ preventScroll: true });
  });
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
  });
  window.addEventListener('market-language-change', () => {
    if (state.data) {
      const returnHref = state.returnFocus?.getAttribute('href') || state.returnFocus?.closest('.extension-card')?.querySelector('a')?.getAttribute('href');
      populateFilters(); renderDiscovery(); renderCards(); updateHelperLinks();
      if (dialog.open && returnHref) state.returnFocus = [...document.querySelectorAll('.extension-card a')].find(link => link.getAttribute('href') === returnHref) || $('#search');
      if (dialog.open && state.activeSlug) openTool(state.activeSlug, state.activeTab);
    } else {
      $('#result-count').textContent = t(state.loading ? 'Loading the collection…' : 'Collection unavailable');
      const loading = $('#extension-grid .loading-note');
      if (loading) loading.replaceChildren(h('span', { class: 'loading-dot', 'aria-hidden': 'true' }), t('Gathering the tools…'));
    }
    $('#toast').hidden = true;
  });
  loadCatalog();
})();
