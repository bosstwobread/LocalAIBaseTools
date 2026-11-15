(() => {
  'use strict';
  const base = new URL('./', document.baseURI);
  const $ = selector => document.querySelector(selector);
  const dialog = $('#tool-dialog');
  const state = { data: null, tools: [], loading: false, pendingTab: null, activeSlug: null, returnFocus: null, previousHash: '#browse' };
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
  const image = (src, alt, attrs = {}) => h('img', { src: url(src) || new URL('assets/mac-helper.png', base).href, alt, loading: 'lazy', ...attrs });
  const textLink = (label, href, extra = {}) => h('a', { class: 'text-link', href, ...extra }, label, h('span', { 'aria-hidden': 'true' }, '↗'));
  function normalize(tool) {
    if (!tool || typeof tool.id !== 'string' || typeof tool.slug !== 'string' || typeof tool.name !== 'string' || !['mac-source', 'browser'].includes(tool.kind)) return null;
    return { ...tool, summary: String(tool.summary || ''), description: String(tool.description || tool.summary || ''), category: String(tool.category || 'Other'), platforms: strings(tool.platforms), features: strings(tool.features), permissions: strings(tool.permissions), installSteps: strings(tool.installSteps), screenshots: Array.isArray(tool.screenshots) ? tool.screenshots.filter(item => item && typeof item.src === 'string') : [] };
  }
  async function loadCatalog() {
    if (state.loading) return;
    state.loading = true;
    $('#catalog-error').hidden = true;
    $('#catalog-empty').hidden = true;
    $('#extension-grid').hidden = false;
    $('#extension-grid').setAttribute('aria-busy', 'true');
    $('#extension-grid').replaceChildren(h('div', { class: 'loading-note' }, h('span', { class: 'loading-dot', 'aria-hidden': 'true' }), 'Gathering the tools…'));
    $('#result-count').textContent = 'Loading the collection…';
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
      renderCards();
      updateHelperLinks();
      $('#spotlight').hidden = !tools.some(tool => tool.slug === 'translation');
      route();
    } catch {
      $('#extension-grid').hidden = true;
      $('#catalog-error').hidden = false;
      $('#result-count').textContent = 'Collection unavailable';
    } finally {
      state.loading = false;
      $('#extension-grid').setAttribute('aria-busy', 'false');
    }
  }
  function populateFilters() {
    for (const [selector, values, all] of [
      ['#category', [...new Set(state.tools.map(tool => tool.category))].sort(), 'All categories'],
      ['#platform', [...new Set(state.tools.flatMap(tool => tool.platforms))].sort(), 'All platforms']
    ]) {
      const select = $(selector);
      const previous = select.value;
      select.replaceChildren(h('option', { value: 'all' }, all), ...values.map(value => h('option', { value }, value)));
      if (values.includes(previous)) select.value = previous;
    }
  }
  function renderCards() {
    const query = $('#search').value.trim().toLocaleLowerCase();
    const category = $('#category').value;
    const platform = $('#platform').value;
    const filtered = state.tools.filter(tool => {
      const searchable = [tool.name, tool.summary, tool.description, tool.category, ...tool.features, ...tool.platforms].join(' ').toLocaleLowerCase();
      return (!query || searchable.includes(query)) && (category === 'all' || tool.category === category) && (platform === 'all' || tool.platforms.includes(platform));
    });
    $('#extension-grid').replaceChildren(...filtered.map(card));
    $('#catalog-empty').hidden = filtered.length !== 0;
    $('#result-count').textContent = `${filtered.length} ${filtered.length === 1 ? 'extension' : 'extensions'}${filtered.length === state.tools.length ? ' in the collection' : ` of ${state.tools.length}`}`;
    $('#clear-filters').hidden = !query && category === 'all' && platform === 'all';
  }
  function card(tool) {
    const details = `#extension/${encodeURIComponent(tool.slug)}`;
    const shot = tool.screenshots[0];
    const visual = h('a', { class: 'card-visual', href: details, 'aria-label': `Explore ${tool.name}` }, image(shot?.src || tool.icon, shot?.alt || `${tool.name} interface preview`, { width: '1160', height: '720' }), h('span', { class: 'preview-label' }, 'Interface preview'));
    const install = h('button', { type: 'button', class: 'card-install', 'aria-label': `Installation options for ${tool.name}` }, tool.kind === 'mac-source' ? 'Add to MacHelper ↗' : 'Get extension ↗');
    install.addEventListener('click', () => navigate(tool.slug, 'install'));
    return h('article', { class: 'extension-card' }, visual,
      h('div', { class: 'card-content' },
        h('div', { class: 'card-kicker' }, h('span', {}, tool.kind === 'mac-source' ? 'MACOS SOURCE TOOL' : 'BROWSER COMPANION'), h('span', { class: 'card-version' }, `v${tool.version || '—'}`)),
        h('div', { class: 'card-heading' }, image(tool.icon, '', { class: 'card-icon', width: '42', height: '42' }), h('div', {}, h('h3', {}, h('a', { href: details }, tool.name)), h('p', {}, tool.category))),
        h('p', { class: 'card-summary' }, tool.summary),
        h('ul', { class: 'card-features' }, tool.features.slice(0, 2).map(feature => h('li', {}, feature))),
        h('div', { class: 'card-bottom' }, h('div', { class: 'platform-labels', 'aria-label': 'Platforms' }, tool.platforms.map(label => h('span', {}, label))), h('div', { class: 'card-links' }, textLink('Details', details, { 'aria-label': `Details for ${tool.name}` }), install))));
  }
  function resetFilters() {
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
        link.replaceChildren(document.createTextNode(header ? 'Get MacHelper ' : 'Download for Mac '), h('span', { 'aria-hidden': 'true' }, header ? '↗' : '↓'));
      }
      else {
        link.textContent = 'MacHelper source ↗';
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
      }
    });
    document.querySelectorAll('[data-helper-source]').forEach(link => { link.href = sourceURL(); });
    $('#helper-meta').textContent = [helper.version && `v${helper.version}`, helper.minimumOS || 'macOS 14+', helper.architecture || 'Apple Silicon', helper.releaseChannel || 'Developer preview'].filter(Boolean).join(' · ');
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
      state.previousHash = '#browse';
    }
    state.activeSlug = slug;
    const close = h('button', { class: 'dialog-close', type: 'button', 'aria-label': 'Close details' }, '×');
    close.addEventListener('click', () => dialog.close());
    const content = $('#dialog-content');
    if (!tool) {
      content.replaceChildren(h('div', { class: 'dialog-topbar' }, h('p', { class: 'eyebrow' }, 'THE COLLECTION'), close), h('div', { class: 'dialog-body' }, h('h2', { id: 'dialog-title' }, 'Tool not found.'), h('p', { class: 'detail-description' }, 'This link may have changed. Close this window to browse the current collection.')));
    } else {
      const overviewTab = h('button', { type: 'button', role: 'tab', id: 'overview-tab', 'aria-controls': 'overview-panel', 'aria-selected': 'false' }, 'Overview');
      const installTab = h('button', { type: 'button', role: 'tab', id: 'install-tab', 'aria-controls': 'install-panel', 'aria-selected': 'false' }, 'Installation');
      const overview = h('section', { id: 'overview-panel', role: 'tabpanel', 'aria-labelledby': 'overview-tab', class: 'dialog-body' }, overviewContent(tool));
      const installation = h('section', { id: 'install-panel', role: 'tabpanel', 'aria-labelledby': 'install-tab', class: 'dialog-body' }, installContent(tool));
      const selectTab = (name, focus = false) => {
        const isOverview = name === 'overview';
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
      const tablist = h('div', { class: 'dialog-tabs', role: 'tablist', 'aria-label': 'Extension details' }, overviewTab, installTab);
      tablist.addEventListener('keydown', event => {
        if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
          event.preventDefault();
          selectTab(event.key === 'Home' ? 'overview' : event.key === 'End' ? 'install' : overview.hidden ? 'overview' : 'install', true);
        }
      });
      content.replaceChildren(h('div', { class: 'dialog-topbar' }, h('p', { class: 'eyebrow' }, `${tool.kind === 'mac-source' ? 'MACOS TOOL' : 'BROWSER COMPANION'} / ${tool.category.toUpperCase()}`), close), h('div', { class: 'dialog-heading' }, image(tool.icon, '', { width: '60', height: '60' }), h('div', {}, h('h2', { id: 'dialog-title' }, tool.name), h('p', {}, `v${tool.version || '—'} · Free & open source`))), tablist, overview, installation);
      selectTab(tab === 'install' ? 'install' : 'overview');
    }
    if (!dialog.open) { dialog.showModal(); document.body.classList.add('modal-open'); }
    dialog.scrollTop = 0;
    close.focus({ preventScroll: true });
  }
  function overviewContent(tool) {
    const main = h('div', {}, h('p', { class: 'detail-description' }, tool.description));
    if (tool.features.length) main.append(h('h3', { class: 'detail-subheading' }, 'What it does'), h('ul', { class: 'detail-list' }, tool.features.map(feature => h('li', {}, feature))));
    for (const shot of tool.screenshots) main.append(h('figure', { class: 'detail-preview' }, image(shot.src, shot.alt || `${tool.name} interface preview`, { width: '1160', height: '720' }), h('figcaption', {}, shot.caption || 'Interface preview · Example content')));
    if (tool.permissions.length) main.append(h('h3', { class: 'detail-subheading' }, 'Access this tool uses'), h('ul', { class: 'detail-list' }, tool.permissions.map(permission => h('li', {}, permissionLabel(permission)))));
    const facts = h('dl', {}, h('dt', {}, 'Platforms'), h('dd', {}, tool.platforms.join(' · ')), h('dt', {}, 'Package'), h('dd', {}, tool.kind === 'mac-source' ? 'Editable source extension' : 'Browser extension ZIP'), h('dt', {}, 'Version'), h('dd', {}, tool.version || '—'));
    if (tool.updatedAt) {
      const date = new Date(`${String(tool.updatedAt).slice(0, 10)}T00:00:00`);
      if (!Number.isNaN(date.valueOf())) facts.append(h('dt', {}, 'Updated'), h('dd', {}, new Intl.DateTimeFormat('en', { dateStyle: 'medium' }).format(date)));
    }
    const share = h('button', { type: 'button', class: 'link-button' }, 'Copy details link ↗');
    share.addEventListener('click', () => copy(new URL(`#extension/${encodeURIComponent(tool.slug)}`, base).href, share));
    const side = h('aside', { class: 'detail-facts' }, facts, textLink('View complete source', url(tool.sourceUrl) || sourceURL(), external), share);
    return h('div', { class: 'detail-grid' }, main, side);
  }
  function permissionLabel(value) {
    return ({ 'selection.read': 'Read text you select through macOS Accessibility.', 'clipboard.read': 'Read clipboard text only when you choose the clipboard action.', 'ai.transform': 'Send text to your shared AI connection for an explicit action.', 'ui.panel': 'Display a nearby floating result panel.', nativeMessaging: 'Connect the browser extension to MacHelper on your Mac.', storage: 'Save extension preferences in browser storage.' })[value] || value;
  }
  function installContent(tool) {
    const native = tool.kind === 'mac-source';
    const container = h('div');
    const callout = h('div', { class: 'install-callout' });
    const packageURL = url(tool.packageUrl);
    if (native) {
      const catalog = url(tool.catalogUrl || 'catalog.json');
      const scheme = new URL('machelper://install');
      scheme.searchParams.set('catalog', catalog);
      scheme.searchParams.set('extension', tool.id);
      const open = h('a', { class: 'button button-blue', href: scheme.href }, 'Open MacHelper', h('span', { 'aria-hidden': 'true' }, '↗'));
      const installStatus = h('p', { class: 'install-status', role: 'status' });
      open.addEventListener('click', () => { installStatus.textContent = 'If MacHelper didn’t open, install it below, then try again. Your browser may ask permission to open the app.'; });
      callout.append(h('h3', {}, `Add ${tool.name} to MacHelper`), h('p', {}, 'Open the MacHelper app to install the complete editable tool package and review its requested access.'), open, h('p', { class: 'install-help' }, 'This website cannot check whether MacHelper is installed on your Mac.'), installStatus);
      const fallbacks = h('div', { class: 'install-fallbacks' });
      fallbacks.append(textLink(helperURL() ? 'Download MacHelper first' : 'Build MacHelper from source', helperURL() || sourceURL(), helperURL() ? { download: '' } : external));
      if (packageURL) fallbacks.append(textLink('Download complete tool source', packageURL, { download: '' }));
      const catalogCopy = h('button', { type: 'button', class: 'link-button' }, 'Copy catalog URL');
      catalogCopy.addEventListener('click', () => copy(catalog, catalogCopy));
      fallbacks.append(catalogCopy);
      container.append(callout, fallbacks);
    } else {
      callout.append(h('h3', {}, 'Add the browser companion'), h('p', {}, 'For Chrome or Edge on your Mac. Install and open MacHelper first so the extension can use your shared AI connection.'));
      if (packageURL) callout.append(h('a', { class: 'button button-blue', href: packageURL, download: '' }, 'Download extension ZIP', h('span', { 'aria-hidden': 'true' }, '↓')));
      callout.append(h('p', { class: 'install-help' }, 'Install from the ZIP with Developer mode → Load unpacked. Chrome Web Store and Edge Add-ons listings are not available yet.'));
      container.append(callout);
      const pages = h('div', { class: 'browser-pages' });
      for (const address of ['chrome://extensions', 'edge://extensions']) {
        const button = h('button', { type: 'button', 'aria-label': `Copy ${address}` }, 'Copy');
        button.addEventListener('click', () => copy(address, button));
        pages.append(h('div', { class: 'browser-page' }, h('code', {}, address), button));
      }
      container.append(pages);
    }
    if (tool.installSteps.length) container.append(h('h3', { class: 'detail-subheading' }, 'Installation, step by step'), h('ol', { class: 'install-steps' }, tool.installSteps.map(step => h('li', {}, step))));
    const preview = /preview/i.test(state.data?.macHelper?.releaseChannel || 'Developer preview');
    container.append(h('p', { class: 'install-footnote' }, `MacHelper for Mac supports ${state.data?.macHelper?.architecture || 'Apple Silicon'}, ${state.data?.macHelper?.minimumOS || 'macOS 14+'}. Unzip the app, move it to Applications, and open it. ${preview ? 'This developer preview is not notarized; macOS may require you to review it in Privacy & Security. ' : ''}Prefer to build it yourself? The full source is available below.`), textLink('Review the project source', sourceURL(), external));
    return container;
  }
  async function copy(value, sender) {
    if (!value) return;
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(value);
      toast('Copied to clipboard.');
    } catch {
      let input = sender.parentElement.querySelector('.copy-fallback');
      if (!input) {
        input = h('input', { class: 'copy-fallback', type: 'text', readonly: '', 'aria-label': 'Copy this link manually' });
        sender.parentElement.append(input);
      }
      input.value = value;
      input.focus(); input.select();
      toast('Select and copy the link manually.');
    }
  }
  let toastTimer;
  function toast(message) {
    const node = $('#toast');
    node.textContent = message; node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.hidden = true; }, 3500);
  }
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
    if (location.hash.startsWith('#extension/')) history.replaceState(null, '', state.previousHash);
    if (state.returnFocus?.isConnected) state.returnFocus.focus({ preventScroll: true });
  });
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
  });
  loadCatalog();
})();
