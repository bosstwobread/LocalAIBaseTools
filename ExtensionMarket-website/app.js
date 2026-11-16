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
  const CONNECTOR_ID = 'kkmffpbghoojlnldpdolonpjmkhdenkh';
  const discovery = { mode: 'keywords', running: null, matches: null, message: '', model: '', stale: false, available: false };
  const toolText = (tool, text) => tool.translations?.[i18n?.locale || 'en']?.[text] || t(text);
  const queryValue = () => $('#need-query').value.replace(/\s+/g, ' ').trim();
  const validQuery = value => Boolean(value) && !value.includes('\0') && value.length <= 2000 && new TextEncoder().encode(value).length <= 8000;
  function connectorMessage(message) {
    return new Promise((resolve, reject) => {
      if (!window.chrome?.runtime?.sendMessage) { reject(new Error('connector')); return; }
      try {
        window.chrome.runtime.sendMessage(CONNECTOR_ID, { type: 'machelper.discovery', ...message }, response => {
          if (window.chrome.runtime.lastError || !response?.ok) reject(new Error('connector'));
          else resolve(response);
        });
      } catch { reject(new Error('connector')); }
    });
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
    $('#need-query').disabled = Boolean(discovery.running);
    $('#discovery-status').textContent = t(discovery.message);
    $('#discovery-status').setAttribute('aria-busy', String(Boolean(discovery.running)));
    $('#connector-help').hidden = discovery.available;
    const open = new URL('machelper://search');
    open.searchParams.set('query', queryValue());
    open.searchParams.set('language', i18n?.locale || 'en');
    const fallback = $('#open-search-in-machelper');
    const canOpen = validQuery(queryValue());
    if(canOpen) fallback.href = open.href; else fallback.removeAttribute('href');
    fallback.setAttribute('aria-disabled',String(!canOpen));
    fallback.tabIndex=canOpen ? 0 : -1;
    $('#discovery-model').textContent = [discovery.model, discovery.stale && t('Using cached extension descriptions.')].filter(Boolean).join(' · ');
    const examples = state.tools.flatMap(tool => tool.exampleQueries.slice(0,1).map(value => ({ tool, value }))).slice(0,3);
    $('#discovery-examples').replaceChildren(...examples.map(({tool,value}) => {
      const button = h('button', { type:'button', class:'example-query', disabled:discovery.running ? '' : null }, toolText(tool,value));
      button.addEventListener('click', () => { $('#need-query').value=toolText(tool,value); updateNeed(); $('#need-query').focus(); });
      return button;
    }));
  }
  function updateNeed() {
    if (!discovery.running && discovery.matches !== null) {
      discovery.matches=null; discovery.message=''; discovery.model=''; discovery.stale=false; $('#no-match-reason').textContent='';
      if(state.data) renderCards();
    }
    renderDiscovery();
  }
  async function chooseSearchMode(mode) {
    if (mode !== discovery.mode) cancelDiscovery(false);
    discovery.mode=mode;
    renderDiscovery();
    if (state.data) renderCards();
    if (mode === 'description') {
      try { const result=await connectorMessage({action:'status'}); discovery.available=result.compatible === true; }
      catch { discovery.available=false; }
      renderDiscovery();
    }
  }
  function cancelDiscovery(showMessage = true) {
    const pending=discovery.running;
    discovery.running=null;
    if(pending) {
      clearTimeout(pending.timeout);
      connectorMessage({action:'cancel',requestId:pending.id}).catch(()=>{});
      if(showMessage) discovery.message='Search cancelled.';
    }
    renderDiscovery();
  }
  async function searchWithAI() {
    if(discovery.running || !state.data) return;
    const query=queryValue();
    if(!validQuery(query)) {
      discovery.message='Describe your need in 1–2,000 characters.'; renderDiscovery(); return;
    }
    const id=window.crypto?.randomUUID?.() || `search_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const pending={ id, timeout:null };
    discovery.running=pending; discovery.matches=null; discovery.model=''; discovery.stale=false; $('#no-match-reason').textContent='';
    discovery.message='Finding extensions with your AI…';
    pending.timeout=setTimeout(()=>{ if(discovery.running===pending) { cancelDiscovery(false); discovery.message='Search timed out. Try again or open MacHelper.';renderDiscovery(); } },180000);
    renderDiscovery();renderCards();
    try {
      const response=await connectorMessage({action:'search',requestId:id,query,language:i18n?.locale || 'en'});
      if(discovery.running!==pending) return;
      const result=response.search;
      if(!result || !Array.isArray(result.matches) || result.matches.length > 100) throw new Error('invalid');
      const known=new Set(state.tools.map(tool=>tool.id)), seen=new Set();
      discovery.matches=result.matches.filter(match => match && known.has(match.id) && !seen.has(match.id) && ['good','partial'].includes(match.fit) && typeof match.reason==='string' && match.reason.length <= 4000 && seen.add(match.id));
      discovery.available=true; discovery.model=typeof result.model==='string' ? result.model.slice(0,200) : '';
      discovery.stale=result.stale===true;
      discovery.message=discovery.matches.length ? 'AI suggestions — review each tool before installing.' : 'No matching extensions found. Try describing your need differently.';
      $('#no-match-reason').textContent=!discovery.matches.length && typeof result.noMatchReason==='string' ? result.noMatchReason.slice(0,4000) : '';
    } catch {
      if(discovery.running!==pending) return;
      discovery.available=false; discovery.message='Could not connect to MacHelper. Check the connector and AI connection, or open MacHelper.';
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
    $('#catalog-empty').hidden = filtered.length !== 0;
    $('#result-count').textContent = filtered.length === state.tools.length ? t('Extensions: {count}', { count: filtered.length }) : t('Extensions: {count} / {total}', { count: filtered.length, total: state.tools.length });
    $('#clear-filters').hidden = !query && category === 'all' && platform === 'all';
  }
  function card(tool, match = null) {
    const details = `#extension/${encodeURIComponent(tool.slug)}`;
    const shot = tool.screenshots[0];
    const visual = h('a', { class: 'card-visual', href: details, 'aria-label': t('Explore {name}', { name: tool.name }) }, image(shot?.src || tool.icon, t(shot?.alt) || t('{name} interface preview', { name: tool.name }), { width: '1160', height: '720' }), h('span', { class: 'preview-label' }, t("Interface preview")));
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
    cancelDiscovery(false); discovery.matches=null; discovery.mode='keywords'; discovery.message=''; discovery.model=''; discovery.stale=false;
    $('#need-query').value=''; $('#no-match-reason').textContent=''; renderDiscovery();
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
    dialog.scrollTop = 0;
    close.focus({ preventScroll: true });
  }
  function overviewContent(tool) {
    const main = h('div', {}, h('p', { class: 'detail-description' }, toolText(tool,tool.description)));
    if (tool.features.length) main.append(h('h3', { class: 'detail-subheading' }, t("What it does")), h('ul', { class: 'detail-list' }, tool.features.map(feature => h('li', {}, toolText(tool,feature)))));
    if(tool.limitations.length) main.append(h('h3',{class:'detail-subheading'},t('Limitations')),h('ul',{class:'detail-list'},tool.limitations.map(value=>h('li',{},toolText(tool,value)))));
    for (const shot of tool.screenshots) main.append(h('figure', { class: 'detail-preview' }, image(shot.src, t(shot.alt) || t('{name} interface preview', { name: tool.name }), { width: '1160', height: '720' }), h('figcaption', {}, t(shot.caption) || t("Interface preview · Example content"))));
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
    return ({ 'selection.read': t("Read text you select through macOS Accessibility."), 'clipboard.read': t("Legacy clipboard declaration (no shared clipboard reader)"), 'ai.transform': t("Send text to your shared AI connection for an explicit action."), 'ui.panel': t("Display a nearby floating result panel."), 'native.execute': t("Compile and run trusted native Swift code as your Mac user; a worker process is not an OS sandbox."), nativeMessaging: t("Connect the browser extension to MacHelper on your Mac."), storage: t("Save extension preferences in browser storage.") })[value] || value;
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
    container.append(h('p', { class: 'install-footnote' }, t('MacHelper supports {architecture}, {minimumOS}. Unzip the app, move it to Applications, and open it.', { architecture: state.data?.macHelper?.architecture || 'Apple Silicon', minimumOS: state.data?.macHelper?.minimumOS || 'macOS 14+' }) + ' ' + (preview ? t('This developer preview is not notarized; macOS may require you to review it in Privacy & Security.') + ' ' : '') + t('Prefer to build it yourself? The full source is available below.')), textLink(t("Review the project source"), sourceURL(), external));
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
  $('#keyword-mode').addEventListener('click',()=>chooseSearchMode('keywords'));
  $('#description-mode').addEventListener('click',()=>chooseSearchMode('description'));
  $('#need-query').addEventListener('input',updateNeed);
  $('#find-with-ai').addEventListener('click',searchWithAI);
  $('#cancel-ai-search').addEventListener('click',()=>cancelDiscovery());
  window.addEventListener('pagehide',()=>cancelDiscovery(false));
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
