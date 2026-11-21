const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const localesScript = fs.readFileSync(path.join(__dirname, 'locales.js'), 'utf8');
const i18nScript = fs.readFileSync(path.join(__dirname, 'i18n.js'), 'utf8');
const localeContext = { window: {} };
require('node:vm').runInNewContext(localesScript, localeContext);
const interfaceLocales = ['en', ...Object.keys(localeContext.window.MARKET_TRANSLATIONS)];
const script = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');
const catalogPath = path.join(__dirname, 'dist/data/extensions.json');
if (!fs.existsSync(catalogPath)) throw new Error('Build the static fixture first: python3 ExtensionMarket-website/build.py --without-app');
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
const lookupCopy = catalog.extensions.find(tool => tool.slug === 'translation').preview?.strings;
const revisionCopy = catalog.extensions.find(tool => tool.slug === 'polish-input').preview?.strings;
const clone = value => JSON.parse(JSON.stringify(value));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function page({ base = 'https://market.example/extension-market/', data = clone(catalog), failFirst = false, languages = ['en-US'], storedLanguage = null, storageDisabled = false, service = null, beforeApp = null } = {}) {
  const dom = new JSDOM(html, { url: base, runScripts: 'outside-only', pretendToBeVisual: true });
  const { window } = dom;
  Object.defineProperty(window.navigator, 'languages', { value: languages });
  if (storedLanguage) window.localStorage.setItem('localaibasetools.website.language', storedLanguage);
  if (storageDisabled) Object.defineProperty(window, 'localStorage', { get() { throw new Error('Storage disabled fixture'); } });
  const requests = [], localRequests = [];
  window.TextEncoder = global.TextEncoder;
  window.HTMLDialogElement.prototype.showModal = function () { this.setAttribute('open', ''); };
  window.HTMLDialogElement.prototype.close = function () {
    this.removeAttribute('open');
    this.dispatchEvent(new window.Event('close'));
  };
  window.fetch = async (input, options = {}) => {
    requests.push(String(input));
    if (String(input).startsWith('http://127.0.0.1:43827/')) {
      const call = { path: new URL(input).pathname, options, body: options.body ? JSON.parse(options.body) : undefined };
      localRequests.push(call);
      if (!service) throw new TypeError('Local service unavailable fixture');
      const reply = await new Promise((resolve, reject) => {
        const abort = () => reject(new window.DOMException('Aborted fixture', 'AbortError'));
        if (options.signal?.aborted) { abort(); return; }
        options.signal?.addEventListener('abort', abort, { once:true });
        Promise.resolve().then(()=>service(call)).then(resolve,reject).finally(()=>options.signal?.removeEventListener('abort',abort));
      });
      return { ok: (reply.status || 200) < 400, status: reply.status || 200, json: async () => clone(reply.body || reply) };
    }
    if (failFirst && requests.length === 1) throw new Error('Offline fixture');
    return { ok: true, json: async () => data };
  };
  window.eval(localesScript);
  window.eval(i18nScript);
  beforeApp?.(window);
  window.eval(script);
  await delay(0);
  return { dom, window, document: window.document, requests, localRequests, close: () => window.close() };
}
function input(view, selector, value, type = 'input') {
  const element = view.document.querySelector(selector);
  element.value = value;
  element.dispatchEvent(new view.window.Event(type, { bubbles: true }));
}
async function until(condition) {
  for (let i = 0; i < 20; i++) { if (condition()) return; await delay(5); }
  assert.ok(condition(), 'Expected DOM update did not arrive');
}

test('search, direct DOM reset click, category and platform filters stay consistent', async () => {
  const view = await page();
  try {
    const count = () => view.document.querySelectorAll('.extension-card').length;
    assert.equal(count(), catalog.extensions.length);
    input(view, '#search', 'polish');
    assert.equal(count(), 1);
    assert.match(view.document.querySelector('.card-heading').textContent, /Polish-input/);
    input(view, '#search', 'a-search-that-cannot-match');
    assert.equal(count(), 0);
    assert.equal(view.document.querySelector('#catalog-empty').hidden, false);
    view.document.querySelector('#reset-empty').click();
    assert.equal(view.document.querySelector('#search').value, '');
    assert.equal(view.document.querySelector('#category').value, 'all');
    assert.equal(view.document.querySelector('#platform').value, 'all');
    assert.equal(count(), catalog.extensions.length);
    input(view, '#category', 'Translation', 'change');
    assert.equal(count(), 1);
    input(view, '#platform', 'Chrome', 'change');
    assert.equal(count(), 0);
    view.document.querySelector('#clear-filters').click();
    assert.equal(count(), catalog.extensions.length);
    input(view, '#platform', 'macOS', 'change');
    assert.equal(count(), catalog.extensions.length);
    assert.deepEqual(catalog.extensions.map(tool=>tool.slug).sort(), ['polish-input','translation']);
    assert.ok(catalog.extensions.every(tool=>tool.kind==='mac-source'));
  } finally { view.close(); }
});

test('details links, accessible tab controls, custom install URL and close restore focus', async () => {
  const view = await page();
  try {
    const link = [...view.document.querySelectorAll('.card-links a')].find(node => /Translation/.test(node.getAttribute('aria-label')));
    link.focus(); link.click();
    const dialog = view.document.querySelector('#tool-dialog');
    await until(() => dialog.open);
    assert.equal(view.window.location.hash, '#extension/translation');
    assert.equal(view.document.querySelector('#dialog-title').textContent, 'Translation');
    assert.equal(view.document.querySelector('#overview-panel').hidden, false);
    const tabs = view.document.querySelector('[role=tablist]');
    tabs.dispatchEvent(new view.window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
    assert.equal(view.document.querySelector('#overview-panel').hidden, true);
    assert.equal(view.document.querySelector('#install-tab').getAttribute('aria-selected'), 'true');
    assert.equal(view.document.activeElement, view.document.querySelector('#install-tab'));
    const open = view.document.querySelector('#install-panel a[href^="machelper:"]');
    const install = new URL(open.href);
    assert.equal(install.host, 'install');
    assert.equal(install.searchParams.get('extension'), 'com.localaibasetools.translation');
    assert.equal(install.searchParams.get('catalog'), 'https://market.example/extension-market/catalog.json');
    assert.match(view.document.querySelector('#install-panel').textContent, /cannot check whether MacHelper is installed/);
    tabs.dispatchEvent(new view.window.KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }));
    assert.equal(view.document.querySelector('#overview-panel').hidden, false);
    view.document.querySelector('.dialog-close').click();
    assert.equal(dialog.open, false);
    assert.equal(view.window.location.hash, '#browse');
    assert.equal(view.document.body.classList.contains('modal-open'), false);
    assert.equal(view.document.activeElement, link);
  } finally { view.close(); }
});

test('Polish-input installs as editable MacHelper source and explains explicit Apply access', async () => {
  const view = await page();
  try {
    [...view.document.querySelectorAll('.extension-card')].find(node => node.querySelector('h3').textContent.includes('Polish-input')).querySelector('.card-install').click();
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.match(view.window.location.hash, /polish-input/);
    assert.equal(view.document.querySelector('#install-panel').hidden, false);
    const open = new URL(view.document.querySelector('#install-panel a[href^="machelper:"]').href);
    assert.equal(open.searchParams.get('extension'), 'com.localaibasetools.polish-input');
    const tool = catalog.extensions.find(item => item.slug === 'polish-input');
    const completeSource = tool.packageUrl || tool.sourceUrl;
    assert.ok([...view.document.querySelectorAll('#install-panel a')].some(link => link.href === new URL(completeSource, view.window.location.href).href));
    assert.doesNotMatch(view.document.querySelector('#install-panel').textContent, /Load unpacked/);
    view.document.querySelector('#overview-tab').click();
    assert.match(view.document.querySelector('#overview-panel').textContent, /only when you click Apply/);
  } finally { view.close(); }
});

test('clipboard-assisted Apply access is explained in every language without touching the clipboard', async () => {
  const data = clone(catalog);
  const tool = data.extensions.find(item => item.slug === 'polish-input');
  if (!tool.permissions.includes('selection.paste')) tool.permissions.push('selection.paste');
  let clipboardReads = 0, clipboardWrites = 0;
  const view = await page({ data, beforeApp(window) {
    Object.defineProperty(window.navigator, 'clipboard', { value: {
      readText: async () => { clipboardReads++; return 'private clipboard fixture'; },
      writeText: async () => { clipboardWrites++; }
    } });
  } });
  const label = 'When you click Apply, MacHelper can paste into the current selection in the original window, even if the editor does not report its position. Pasting leaves the result on the clipboard.';
  try {
    view.window.location.hash = '#extension/polish-input';
    await until(() => view.document.querySelector('#tool-dialog').open);
    for (const code of interfaceLocales) {
      input(view, '#site-language', code, 'change');
      const expected = code === 'en' ? label : view.window.MARKET_TRANSLATIONS[code][label];
      assert.ok(expected, `${code}: clipboard Apply permission is translated`);
      assert.ok([...view.document.querySelectorAll('#overview-panel .detail-list li')].some(node => node.textContent === expected), `${code}: clipboard behavior is visible during permission review`);
    }
    assert.equal(clipboardReads, 0);
    assert.equal(clipboardWrites, 0);
    assert.equal(view.localRequests.length, 0);
  } finally { view.close(); }
});

test('fetch failure shows a retry state and a successful retry recovers the catalog', async () => {
  const view = await page({ failFirst: true });
  try {
    assert.equal(view.document.querySelector('#catalog-error').hidden, false);
    assert.equal(view.document.querySelector('#extension-grid').hidden, true);
    view.document.querySelector('#retry-catalog').click();
    await until(() => view.document.querySelectorAll('.extension-card').length === catalog.extensions.length);
    assert.equal(view.document.querySelector('#catalog-error').hidden, true);
    assert.equal(view.requests.length, 2);
    assert.ok(view.requests.every(url => url === 'https://market.example/extension-market/data/extensions.json'));
  } finally { view.close(); }
});

test('root and mounted-prefix assets, fetches and downloads resolve at their own base', async () => {
  for (const suffix of ['/', '/extension-market/']) {
    const view = await page({ base: `https://market.example${suffix}` });
    try {
      assert.equal(view.requests[0], `https://market.example${suffix}data/extensions.json`);
      for (const [index, icon] of [...view.document.querySelectorAll('.card-icon')].entries()) {
        const expected = new URL(catalog.extensions[index].icon || 'assets/mac-helper.png', `https://market.example${suffix}`);
        assert.equal(icon.src, expected.href);
      }
      const tool = catalog.extensions.find(item => item.kind === 'mac-source');
      view.window.location.hash = `#extension/${tool.slug}`;
      await until(() => view.document.querySelector('#tool-dialog').open);
      assert.ok([...view.document.querySelectorAll('.detail-preview img')].every(node => new URL(node.src).pathname.startsWith(`${suffix}assets/`)));
      view.document.querySelector('#install-tab').click();
      assert.ok([...view.document.querySelectorAll('#install-panel a[download]')].every(node => new URL(node.href).pathname.startsWith(suffix)));
    } finally { view.close(); }
  }
});

test('create and customize entry offers a local readable guide and a Markdown AI download', async () => {
  for (const suffix of ['/', '/extension-market/']) {
    const view = await page({ base: `https://market.example${suffix}` });
    try {
      const navigation = view.document.querySelector('.main-nav a[href="#developers"]');
      assert.match(navigation.textContent, /Create & customize/);
      const section = view.document.querySelector('#developers');
      assert.match(section.textContent, /Edit Source/);
      assert.match(section.textContent, /Install Source/);
      assert.match(section.textContent, /enabled tool reloads automatically/);
      const read = section.querySelector('a[href="./developer-guide.html"]');
      const download = section.querySelector('a[download="AI_EXTENSION_GUIDE.md"]');
      assert.equal(read.href, `https://market.example${suffix}developer-guide.html`);
      assert.equal(download.href, `https://market.example${suffix}AI_EXTENSION_GUIDE.md`);
      view.window.location.hash = '#extension/translation';
      await until(() => view.document.querySelector('#tool-dialog').open);
      assert.match(view.document.querySelector('#overview-panel').textContent, /Make it yours/);
      assert.equal(view.document.querySelector('#overview-panel a[download="AI_EXTENSION_GUIDE.md"]').href, download.href);
      const guide = view.document.querySelector('#overview-panel a[href$="developer-guide.html"]');
      assert.equal(guide.href, read.href);
      view.document.querySelector('.dialog-close').click();
      view.window.location.hash = '#extension/polish-input';
      await until(() => view.document.querySelector('#tool-dialog').open);
      assert.ok(view.document.querySelector('#overview-panel a[download="AI_EXTENSION_GUIDE.md"]'), 'Polish-input shares the independent source-worker editing flow');
    } finally { view.close(); }
  }
});

test('published AI guide preserves original text and exposes only allowlisted public documents', () => {
  const root = path.resolve(__dirname, '..');
  const guide = fs.readFileSync(path.join(root, 'AI_EXTENSION_GUIDE.md'), 'utf8');
  assert.equal(fs.readFileSync(path.join(__dirname, 'dist/AI_EXTENSION_GUIDE.md'), 'utf8'), guide);
  const rendered = new JSDOM(fs.readFileSync(path.join(__dirname, 'dist/developer-guide.html'), 'utf8'));
  try {
    assert.equal(rendered.window.document.querySelector('.guide-document pre').textContent, guide);
    assert.equal(rendered.window.document.querySelectorAll('script').length, 0);
    assert.equal(rendered.window.document.querySelector('a[download="AI_EXTENSION_GUIDE.md"]').getAttribute('href'), './AI_EXTENSION_GUIDE.md');
  } finally { rendered.window.close(); }
  assert.deepEqual(fs.readdirSync(path.join(__dirname, 'dist/docs')).sort(), ['Extension-Development.md', 'MacHelper-Protocol.md', 'Native-Extensions.md', 'Source-Extensions.md']);
  assert.equal(fs.existsSync(path.join(__dirname, 'dist/AI_DEPLOYMENT.md')), false);
  assert.equal(fs.readFileSync(path.join(__dirname, 'dist/NativeExtensionSDK/MacHelperNativeSDK.swift'), 'utf8'), fs.readFileSync(path.join(root, 'MacHelper/NativeExtensionSDK/MacHelperNativeSDK.swift'), 'utf8'));
});

test('metadata is rendered as text and unsafe links never become executable DOM', async () => {
  const unsafe = clone(catalog);
  const tool = unsafe.extensions.find(item => item.kind === 'mac-source');
  tool.name = '<img id="injected" src=x onerror="window.pwned=1">';
  tool.description = '<script>window.pwned=2</script>';
  tool.features = ['<svg onload="window.pwned=3">'];
  tool.sourceUrl = 'javascript:window.pwned=4';
  tool.icon = 'javascript:window.pwned=5';
  const view = await page({ data: unsafe });
  try {
    assert.equal(view.document.querySelector('#injected'), null);
    assert.equal(view.window.pwned, undefined);
    assert.match(view.document.querySelector('.extension-grid').textContent, /<img id=/);
    view.window.location.hash = `#extension/${tool.slug}`;
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.deepEqual([...view.document.querySelectorAll('script')].map(node => node.getAttribute('src')), ['./locales.js', './i18n.js', './app.js'], 'Only the allowlisted static localization and application scripts should exist');
    assert.match(view.document.querySelector('.detail-description').textContent, /<script>/);
    assert.ok([...view.document.querySelectorAll('a')].every(node => !node.href.startsWith('javascript:')));
    assert.ok([...view.document.querySelectorAll('img')].every(node => !node.src.startsWith('javascript:')));
    assert.equal(view.window.pwned, undefined);
  } finally { view.close(); }
});


test('native source tools share installation and customization with runtime-specific requirements', async () => {
  const data = clone(catalog);
  const tool = data.extensions.find(item => item.kind === 'mac-source');
  tool.runtime = 'native';
  tool.permissions = ['native.execute', 'selection.read', 'ui.panel'];
  const view = await page({ data });
  try {
    assert.match(view.document.querySelector('.extension-grid').textContent, /NATIVE MACOS TOOL/);
    view.window.location.hash = `#extension/${tool.slug}`;
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.match(view.document.querySelector('#overview-panel').textContent, /Editable native Swift source/);
    assert.match(view.document.querySelector('#overview-panel').textContent, /trusted native Swift code/);
    assert.match(view.document.querySelector('#overview-panel').textContent, /Edit Source/);
    view.document.querySelector('#install-tab').click();
    assert.ok(view.document.querySelector('#install-panel a[href^="machelper://install"]'));
    assert.match(view.document.querySelector('#install-panel').textContent, /Xcode Command Line Tools/);
    assert.match(view.document.querySelector('#install-panel').textContent, /without restarting MacHelper/);
  } finally { view.close(); }
});


test('unknown declared source runtimes fail catalog validation', async () => {
  const data = clone(catalog);
  data.extensions.find(item => item.kind === 'mac-source').runtime = 'shell';
  const view = await page({ data });
  try {
    assert.equal(view.document.querySelector('#catalog-error').hidden, false);
    assert.equal(view.document.querySelector('#extension-grid').hidden, true);
  } finally { view.close(); }
});

test('browser language detection, explicit choice and storage failures have predictable fallbacks', async () => {
  for (const [languages, storedLanguage, expected] of [
    [['fr-CA', 'en-US'], null, 'fr'], [['zh-HK'], null, 'zh-Hant'],
    [['zh-Hans-TW'], null, 'zh-Hans'], [['zh-Hant-CN'], null, 'zh-Hant'],
    [['zz-ZZ', 'pt-BR'], null, 'pt'], [['zz-ZZ'], null, 'en'],
    [['ja-JP'], 'de-DE', 'de'], [['ja-JP'], 'not-a-language', 'ja']
  ]) {
    const view = await page({ languages, storedLanguage });
    try {
      assert.equal(view.document.documentElement.lang, expected);
      assert.equal(view.document.querySelector('#site-language').value, expected);
      assert.equal(view.document.querySelectorAll('#site-language option').length, 13);
      assert.equal(view.document.querySelector('#site-language option[value=ja]').textContent, '日本語');
    } finally { view.close(); }
  }
  const view = await page({ languages: ['es-MX'], storageDisabled: true });
  try {
    assert.equal(view.document.documentElement.lang, 'es');
    input(view, '#site-language', 'ko', 'change');
    assert.equal(view.document.documentElement.lang, 'ko');
    assert.equal(view.window.MarketI18n.setLocale('unavailable'), false);
    assert.equal(view.document.documentElement.lang, 'ko');
  } finally { view.close(); }
});

test('switching language updates marketing, filters, metadata and an open installation dialog without new fetches', async () => {
  const view = await page();
  try {
    input(view, '#category', 'Translation', 'change');
    view.document.querySelector('.card-install').click();
    await until(() => view.document.querySelector('#tool-dialog').open);
    const catalogURL = view.document.querySelector('#install-panel a[href^="machelper:"]').href;
    input(view, '#site-language', 'zh-Hans', 'change');
    assert.equal(view.document.documentElement.lang, 'zh-Hans');
    assert.equal(view.document.querySelector('#site-language').getAttribute('aria-label'), '网站语言');
    assert.equal(view.document.querySelector('#search').placeholder, '搜索工具、功能、平台…');
    assert.equal(view.document.querySelector('#category').value, 'Translation');
    assert.equal(view.document.querySelector('#category option[value=Translation]').textContent, '翻译');
    assert.equal(view.document.querySelectorAll('.extension-card').length, 1);
    assert.equal(view.document.querySelector('#install-panel').hidden, false);
    assert.equal(view.document.querySelector('#install-tab').textContent, '安装');
    assert.match(view.document.querySelector('.card-summary').textContent, /可编辑/);
    assert.match(view.document.querySelector('#install-panel').textContent, /审核/);
    assert.equal(view.document.querySelector('#install-panel a[href^="machelper:"]').href, catalogURL);
    assert.equal(view.document.querySelector('#dialog-title').textContent, 'Translation');
    assert.equal(view.window.localStorage.getItem('localaibasetools.website.language'), 'zh-Hans');
    assert.equal(view.requests.length, 1);
    view.document.querySelector('.dialog-close').click();
    input(view, '#search', '上下文');
    // Search uses translated metadata as well as the canonical English source.
    assert.equal(view.document.querySelectorAll('.extension-card').length, 0);
    input(view, '#search', '单词');
    assert.equal(view.document.querySelectorAll('.extension-card').length, 1);
    input(view, '#site-language', 'en', 'change');
    assert.equal(view.document.querySelector('#search').placeholder, 'Search tools, features, platforms…');
    assert.match(view.document.querySelector('#hero-title').textContent, /Your AI/);
  } finally { view.close(); }
});

test('Arabic mirrors reading direction and localizes accessibility, tool permissions and clipboard status', async () => {
  const data = clone(catalog);
  data.extensions.find(tool => tool.slug === 'translation').permissions.push('native.execute');
  const view = await page({ languages: ['ar-EG'], data });
  try {
    assert.equal(view.document.documentElement.dir, 'rtl');
    assert.equal(view.document.querySelector('.main-nav').getAttribute('aria-label'), 'التنقل الرئيسي');
    assert.equal(view.document.querySelector('.get-identity img').alt, 'أيقونة تطبيق MacHelper');
    const polish = view.document.querySelector('.card-visual .revision-demo');
    assert.equal(view.document.getElementById(polish.getAttribute('aria-describedby')).textContent, revisionCopy.ar.description);
    view.window.location.hash = '#extension/translation';
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.match(view.document.querySelector('#overview-panel').textContent, /ليست بيئة عزل/);
    const sourceLink = view.document.querySelector('#overview-panel a[download="AI_EXTENSION_GUIDE.md"]');
    assert.match(sourceLink.textContent, /دليل/);
    const copy = view.document.querySelector('.detail-facts button');
    copy.click();
    await until(() => !view.document.querySelector('#toast').hidden);
    assert.equal(view.document.querySelector('.copy-fallback').getAttribute('aria-label'), 'انسخ هذا الرابط يدويًا');
    assert.equal(view.document.querySelector('.copy-fallback').value, 'https://market.example/extension-market/#extension/translation');
    input(view, '#site-language', 'fr', 'change');
    assert.equal(view.document.documentElement.dir, 'ltr');
    assert.equal(view.document.querySelector('#overview-tab').textContent, 'Présentation');
    assert.equal(view.document.querySelector('#toast').hidden, true);
  } finally { view.close(); }
});

test('every supported locale renders the main site, first-party details and install text with complete placeholders', async () => {
  const baseline = await page();
  let expectedKeys;
  try {
    const catalogs = baseline.window.MARKET_TRANSLATIONS;
    const localeKeys = Object.keys(catalogs);
    assert.equal(localeKeys.length, 12);
    expectedKeys = Object.keys(catalogs['zh-Hans']).sort();
    for (const code of localeKeys) {
      assert.deepEqual(Object.keys(catalogs[code]).sort(), expectedKeys, `${code}: complete authored catalog`);
      for (const [key, value] of Object.entries(catalogs[code])) {
        assert.equal(typeof value, 'string'); assert.ok(value.trim(), `${code}: ${key}`);
        const placeholders = text => [...text.matchAll(/\{(\w+)\}/g)].map(match => match[1]).sort();
        assert.deepEqual(placeholders(value), placeholders(key), `${code}: ${key} placeholders`);
      }
    }
  } finally { baseline.close(); }
  for (const code of ['en', 'zh-Hans', 'zh-Hant', 'es', 'fr', 'de', 'ja', 'ko', 'pt', 'ar', 'hi', 'ru', 'it']) {
    const view = await page({ storedLanguage: code });
    try {
      assert.equal(view.document.documentElement.lang, code);
      const tr = message => view.window.MarketI18n.t(message);
      assert.equal(view.document.querySelector('.hero-description').textContent, tr('A collection of useful little extensions, built around the AI connection you already have. Open source. Yours to make your own.'));
      assert.equal(view.document.querySelector('#search').getAttribute('placeholder'), tr('Search tools, features, platforms…'));
      for (const tool of catalog.extensions) {
        view.window.location.hash = `#extension/${tool.slug}`;
        await until(() => view.document.querySelector('#dialog-title')?.textContent === tool.name);
        const tt=message=>tool.translations?.[code]?.[message] || tr(message);
        assert.equal(view.document.querySelector('.detail-description').textContent, tt(tool.description));
        assert.ok([...view.document.querySelectorAll('#overview-panel .detail-list li')].some(node => node.textContent === tt(tool.features[0])));
        view.document.querySelector('#install-tab').click();
        assert.ok([...view.document.querySelectorAll('.install-steps li')].some(node => node.textContent === tt(tool.installSteps[0])));
        assert.doesNotMatch(view.document.querySelector('#install-panel').textContent, /\{(?:name|count|total|architecture|minimumOS)\}/);
        view.document.querySelector('.dialog-close').click();
      }
    } finally { view.close(); }
  }
});

test('localized errors, unknown tool text and untrusted metadata remain safe text', async () => {
  const data = clone(catalog);
  const tool = data.extensions[0];
  tool.description = '<img id="locale-injected" src=x onerror=alert(1)>';
  const view = await page({ storedLanguage: 'zh-Hant', failFirst: true, data });
  try {
    assert.equal(view.document.querySelector('#catalog-error').hidden, false);
    assert.equal(view.document.querySelector('#result-count').textContent, '工具集合無法使用');
    view.document.querySelector('#retry-catalog').click();
    await until(() => view.document.querySelectorAll('.extension-card').length === catalog.extensions.length);
    view.window.location.hash = `#extension/${tool.slug}`;
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.equal(view.document.querySelector('.detail-description').textContent, tool.description);
    assert.equal(view.document.querySelector('#locale-injected'), null);
    view.document.querySelector('.dialog-close').click();
    view.window.location.hash = '#extension/not-an-installed-tool';
    await until(() => view.document.querySelector('#dialog-title')?.textContent === '找不到工具。');
    assert.equal(view.document.querySelector('#dialog-content .detail-description').textContent, '連結可能已變更。關閉視窗後可瀏覽目前工具集合。');
  } finally { view.close(); }
});

test('authored interface copy and first-party catalog text have translations in every non-English locale', () => {
  const dom = new JSDOM(html);
  try {
    const { document, NodeFilter } = dom.window;
    const keys = new Set();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (!node.textContent.trim() || node.parentElement.closest('script,style,code,noscript,[aria-hidden="true"]')) continue;
      keys.add(node.textContent.replace(/\s+/g, ' ').trim());
    }
    for (const element of document.querySelectorAll('[aria-label],[placeholder],[title],[alt],meta[name="description"]')) {
      for (const attribute of ['aria-label', 'placeholder', 'title', 'alt', 'content']) {
        const text = element.getAttribute(attribute);
        if (text) keys.add(text);
      }
    }
    keys.add(document.title);
    // Extract only literal first arguments from authored t() calls. Interpolated
    // technical IDs and unknown third-party metadata intentionally use fallback.
    for (const match of script.matchAll(/\bt\(((?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'))/g)) {
      keys.add(Function(`return ${match[1]}`)().trim());
    }
    for (const tool of catalog.extensions) {
      keys.add(tool.category);
    }
    const unchanged = new Set(['LocalAI', 'BaseTools', 'GitHub', 'Translation/', '01', '02', '03', 'macOS 14+ · Apple Silicon', '{ }', 'JS', 'Aa']);
    const translations = {};
    // The translation asset is trusted application source, never remote data.
    require('node:vm').runInNewContext(localesScript, { window: translations });
    for (const [locale, table] of Object.entries(translations.MARKET_TRANSLATIONS)) {
      for (const key of keys) if (!unchanged.has(key)) assert.ok(Object.hasOwn(table, key), `${locale}: missing ${key}`);
      for(const tool of catalog.extensions) {
        for(const key of [tool.summary,tool.description,...tool.features,...tool.installSteps,...tool.limitations,...tool.exampleQueries]) assert.ok(Object.hasOwn(tool.translations?.[locale] || {},key), `${locale}: missing owned ${tool.id}: ${key}`);
      }
    }
  } finally { dom.window.close(); }
});

const fixtureToken = 'a'.repeat(64);
function localService(handler = () => ({ok:true,search:{matches:[],noMatchReason:'No matching tool.'}})) {
  return call => {
    if (call.path === '/v1/status') return {ok:true,version:'6.5.0',protocolVersion:1};
    if (call.path === '/v1/session') return {ok:true,token:fixtureToken,expiresIn:1800};
    if (call.path === '/v1/cancel') return {ok:true,cancelled:true};
    return handler(call);
  };
}
function find(view, query = 'Explain a selected word') {
  input(view,'#need-query',query);
  view.document.querySelector('#find-with-ai').click();
}
async function finished(view) {
  await until(()=>!view.document.querySelector('#find-with-ai').disabled);
}

test('the normal description form exposes only its accessible text box and Find with AI action',async()=>{
  const view=await page();
  try{
    view.document.querySelector('#description-mode').click();
    const form=view.document.querySelector('#description-search');
    const visibleControls=[...form.querySelectorAll('input,textarea,button,a')].filter(node=>!node.closest('[hidden]'));
    assert.deepEqual(visibleControls.map(node=>node.id),['need-query','find-with-ai']);
    const label=form.querySelector('label[for="need-query"]');
    assert.equal(label.classList.contains('sr-only'),true,'Keep an accessible name without another visible heading.');
    assert.ok(label.textContent.trim());
    for(const selector of ['#discovery-examples','.example-query','.discovery-note','#discovery-model','#no-match-reason','#connect-machelper']){
      assert.equal(form.querySelector(selector),null,selector);
    }
    assert.equal(form.querySelector('#discovery-status').textContent,'');
    assert.equal(form.querySelector('#local-connection-help').hidden,true);
    assert.equal(view.localRequests.length,0);
  }finally{view.close();}
});

test('one Find with AI click connects and searches once with captured input while other interactions never contact MacHelper', async () => {
  let complete, releaseStatus;
  const normal=localService(()=>new Promise(resolve=>{complete=resolve;}));
  const view = await page({service:call=>call.path==='/v1/status'?new Promise(resolve=>{releaseStatus=resolve;}):normal(call)});
  try {
    assert.equal(view.localRequests.length,0);
    assert.equal(view.document.querySelector('#connect-machelper'),null);
    assert.equal(view.document.querySelector('#local-connection-help').hidden,true);
    view.document.querySelector('#description-mode').click();
    input(view,'#need-query','Help me understand words while reading.');
    input(view,'#site-language','es','change');input(view,'#site-language','en','change');
    assert.equal(view.localRequests.length,0,'Modes, typing, languages and demos must not contact MacHelper.');
    assert.equal(view.document.querySelector('#find-with-ai').disabled,false);
    const query='Explain this word.\nKeep this second sentence.';
    find(view,query);
    await until(()=>releaseStatus);
    assert.equal(view.document.querySelector('#need-query').disabled,true);
    assert.equal(view.document.querySelector('#cancel-ai-search').hidden,false);
    assert.match(view.document.querySelector('#discovery-status').textContent,/Connecting/);
    view.document.querySelector('#find-with-ai').dispatchEvent(new view.window.Event('click'));
    input(view,'#need-query','Programmatic change while the field is disabled');
    input(view,'#site-language','es','change');
    assert.equal(view.localRequests.length,1);
    releaseStatus({ok:true,version:'6.5.0',protocolVersion:1});
    await until(()=>typeof complete==='function');
    assert.deepEqual(view.localRequests.map(call=>call.path),['/v1/status','/v1/session','/v1/search']);
    const call=view.localRequests.at(-1);
    assert.equal(call.body.query,query);assert.equal(call.body.language,'en');
    assert.equal(call.options.headers.Authorization,`Bearer ${fixtureToken}`);
    assert.deepEqual(Object.keys(call.body).sort(),['language','query','requestId']);
    assert.match(call.body.requestId,/^[A-Za-z0-9_-]{1,80}$/);
    for (const request of view.localRequests) {
      assert.equal(request.options.headers['X-MacHelper-Client'],'extension-market');
      assert.equal(request.options.credentials,'omit');assert.equal(request.options.referrerPolicy,'no-referrer');
      assert.equal(request.options.cache,'no-store');assert.equal(request.options.redirect,'error');
    }
    complete({ok:true,search:{model:'fixture-model',stale:true,matches:[
      {id:'invented.tool',fit:'good',reason:'Made up'},
      {id:'com.localaibasetools.translation',fit:'good',reason:'<img id="discovery-injection" src=x onerror=alert(1)>'},
      {id:'com.localaibasetools.translation',fit:'good',reason:'Duplicate'}
    ]}});
    await finished(view);
    assert.equal(view.document.querySelectorAll('.extension-card').length,1);
    assert.match(view.document.querySelector('.discovery-match p').textContent,/<img/);
    assert.equal(view.document.querySelector('#discovery-injection'),null);
    assert.equal(view.document.querySelector('#discovery-status').textContent,'');
    assert.equal(view.document.querySelector('#discovery-model'),null);
    assert.equal(view.document.body.textContent.includes('fixture-model'),false);
    assert.equal(view.document.body.textContent.includes('AI suggestions'),false);
    assert.equal(view.window.location.hash,'','Search must not install or open a tool.');
    assert.equal(view.window.localStorage.length,1);
    assert.equal(view.window.localStorage.getItem('localaibasetools.website.language'),'es');
  }finally{view.close();}
});

test('valid memory sessions are reused, expired sessions renew under the same click, and fresh browsers need no installation setup',async()=>{
  let now=1700000000000,sessions=0,searches=0;
  const service=call=>{
    if(call.path==='/v1/session')return {ok:true,token:String(++sessions).repeat(64),expiresIn:1800};
    if(call.path==='/v1/search'){searches++;return {ok:true,search:{matches:[],noMatchReason:'No matching tool.'}};}
    return {ok:true,version:'6.5.0',protocolVersion:1};
  };
  const first=await page({service,beforeApp:window=>{window.Date.now=()=>now;}});
  try{
    first.document.querySelector('#description-mode').click();
    find(first);await finished(first);
    assert.equal(sessions,1);assert.equal(searches,1);
    find(first);await finished(first);
    assert.equal(sessions,1);assert.equal(searches,2);
    assert.equal(first.localRequests.at(-1).path,'/v1/search');
    now+=1800001;
    find(first);await finished(first);
    assert.equal(sessions,2);assert.equal(searches,3);
    assert.deepEqual(first.localRequests.slice(-3).map(call=>call.path),['/v1/status','/v1/session','/v1/search']);
    assert.equal(first.window.localStorage.length,0);
  }finally{first.close();}
  const fresh=await page({service});
  try{
    fresh.document.querySelector('#description-mode').click();assert.equal(fresh.localRequests.length,0);
    find(fresh);await finished(fresh);
    assert.equal(sessions,3);assert.equal(searches,4);
    assert.equal(fresh.window.localStorage.length,0);
  }finally{fresh.close();}
});

test('missing service shows accurate install-or-open help only after an explicit valid search and remains retryable',async()=>{
  const view=await page();
  try{
    input(view,'#search','Explain a selected word');assert.equal(view.document.querySelectorAll('.extension-card').length,1);
    view.document.querySelector('#description-mode').click();
    const help=view.document.querySelector('#local-connection-help');
    assert.equal(help.hidden,true);
    assert.ok(help.querySelector('a[href="machelper://open"]'));
    assert.ok(help.querySelector('a[href="#get-machelper"]'));
    assert.equal(view.document.querySelector('a[href="#extension/machelper-connector"]'),null);
    assert.equal(view.document.querySelector('a[href^="machelper://search"]'),null);
    assert.equal(view.localRequests.length,0);
    find(view,'A & B? 翻译');await finished(view);
    assert.equal(help.hidden,false);
    assert.match(view.document.querySelector('#discovery-status').textContent,/Install or open MacHelper/);
    assert.equal(view.document.body.textContent.match(/Install or open MacHelper, then try Find with AI again\./g)?.length,1,'Recovery text should appear only once.');
    assert.equal(view.window.location.hash,'');assert.equal(view.localRequests.length,1);
    find(view,'A & B? 翻译');await finished(view);
    assert.equal(view.localRequests.length,2,'A second explicit click retries connection without a separate control.');
  }finally{view.close();}
});

test('blank, overlong and NUL needs never connect or infer',async()=>{
  const view=await page({service:localService()});
  try{
    view.document.querySelector('#description-mode').click();
    for(const query of ['', '  \n ', 'a'.repeat(2001),'word\0private']){
      find(view,query);await delay(0);
      assert.match(view.document.querySelector('#discovery-status').textContent,/1–2,000/);
      assert.equal(view.localRequests.length,0);
      assert.equal(view.document.querySelector('#local-connection-help').hidden,true);
    }
    find(view,'Explain a selected word');await finished(view);
    assert.equal(view.localRequests.filter(call=>call.path==='/v1/search').length,1);
    assert.equal(view.document.querySelector('#discovery-status').textContent,'No matching tool.');
  }finally{view.close();}
});

test('empty-result explanations use one safe conditional status and remain unchanged when the interface language changes',async()=>{
  const reason='<img id="empty-reason-injection" src=x onerror=alert(1)> No current tool matches.';
  const view=await page({service:localService(()=>({ok:true,search:{matches:[],noMatchReason:reason}}))});
  try{
    view.document.querySelector('#description-mode').click();find(view);await finished(view);
    assert.equal(view.document.querySelector('#discovery-status').textContent,reason);
    assert.equal(view.document.querySelector('#empty-reason-injection'),null);
    assert.equal(view.document.querySelector('#no-match-reason'),null);
    input(view,'#site-language','es','change');
    assert.equal(view.document.querySelector('#discovery-status').textContent,reason,'Provider output is not an interface translation.');
    input(view,'#need-query','A different need');
    assert.equal(view.document.querySelector('#discovery-status').textContent,'');
    assert.equal(view.document.querySelectorAll('.extension-card').length,catalog.extensions.length);
  }finally{view.close();}
});

test('permission denial, incompatible host and connection timeout explain recovery without invoking AI',async()=>{
  for (const scenario of ['permission','version','timeout']) {
    let fireTimeout;
    const view=await page({service:scenario==='timeout'?()=>new Promise(()=>{}):()=>({ok:true,version:'6.4.0',protocolVersion:1}),beforeApp:window=>{
      if(scenario==='permission')Object.defineProperty(window.navigator,'permissions',{value:{query:async()=>({state:'denied'})}});
      if(scenario==='timeout'){
        const original=window.setTimeout.bind(window);
        window.setTimeout=(callback,ms,...args)=>{if(ms===30000){fireTimeout=callback;return original(()=>{},100000);}return original(callback,ms,...args);};
      }
    }});
    try{
      view.document.querySelector('#description-mode').click();find(view);
      if(scenario==='timeout'){await until(()=>fireTimeout);fireTimeout();}
      await finished(view);
      assert.match(view.document.querySelector('#discovery-status').textContent,scenario==='permission'?/site settings/:scenario==='version'?/version 6.5/:/timed out/);
      assert.equal(view.document.querySelector('#local-connection-help').hidden,false);
      assert.equal(view.localRequests.some(call=>call.path==='/v1/search'),false);
      if(scenario==='permission')assert.equal(view.localRequests.length,0);
    }finally{view.close();}
  }
});

test('only a pre-inference HTTP401 renews and retries once, preserving request identity, query and language',async()=>{
  for(const scenario of ['renewed','repeat401','code_without_401','provider_failure','busy','network_failure']){
    let attempts=0,inference=0;
    const service=localService(()=>{
      attempts++;
      if(scenario==='network_failure')throw new TypeError('Unreachable fixture');
      if(scenario==='provider_failure'){inference++;return {status:502,body:{ok:false,code:'search_failed'}};}
      if(scenario==='busy')return {status:429,body:{ok:false,code:'busy'}};
      if(scenario==='code_without_401')return {status:502,body:{ok:false,code:'unauthorized'}};
      if(attempts===1 || scenario==='repeat401')return {status:401,body:{ok:false,code:'unauthorized'}};
      inference++;return {ok:true,search:{matches:[],noMatchReason:'No matching tool.'}};
    });
    const view=await page({service});
    try{
      view.document.querySelector('#description-mode').click();find(view);await finished(view);
      const retried=['renewed','repeat401'].includes(scenario);
      assert.equal(attempts,retried?2:1);
      assert.equal(view.localRequests.filter(call=>call.path==='/v1/session').length,retried?2:1);
      const requests=view.localRequests.filter(call=>call.path==='/v1/search');
      if(retried)assert.deepEqual(requests[0].body,requests[1].body);
      assert.equal(inference,['renewed','provider_failure'].includes(scenario)?1:0);
      if(scenario==='repeat401')assert.match(view.document.querySelector('#discovery-status').textContent,/Could not renew/);
      if(scenario==='provider_failure')assert.match(view.document.querySelector('#discovery-status').textContent,/AI Connection/);
      if(scenario==='busy')assert.match(view.document.querySelector('#discovery-status').textContent,/busy/);
    }finally{view.close();}
  }
});

test('cancel during inference aborts only the owned search, ignores late responses and permits a later click',async()=>{
  const searches=[];
  const view=await page({service:localService(()=>new Promise(resolve=>searches.push(resolve)))});
  try{
    view.document.querySelector('#description-mode').click();find(view,'record my voice');await until(()=>searches.length===1);
    const request=view.localRequests.find(call=>call.path==='/v1/search');
    view.document.querySelector('#cancel-ai-search').click();
    const cancel=view.localRequests.at(-1);
    assert.equal(cancel.path,'/v1/cancel');assert.equal(cancel.body.requestId,request.body.requestId);
    assert.equal(cancel.options.headers.Authorization,request.options.headers.Authorization);
    assert.equal(request.options.signal.aborted,true);
    searches[0]({ok:true,search:{matches:[{id:catalog.extensions[0].id,fit:'good',reason:'Late'}]}});await delay(0);
    assert.equal(view.document.querySelector('.discovery-match'),null);
    assert.match(view.document.querySelector('#discovery-status').textContent,/cancelled/);
    find(view);await until(()=>searches.length===2);
    searches[1]({ok:true,search:{matches:[],noMatchReason:'No current tool records audio.'}});await finished(view);
    assert.equal(view.document.querySelectorAll('.extension-card').length,0);
    input(view,'#need-query','translate a word');
    assert.equal(view.document.querySelector('#discovery-status').textContent,'');
    assert.equal(view.document.querySelectorAll('.extension-card').length,catalog.extensions.length);
  }finally{view.close();}
});

test('cancel, mode change and page hide stop every unfinished handshake and prevent delayed inference',async()=>{
  for(const phase of ['permission','status','session'])for(const action of ['cancel','mode','pagehide']){
    let release;
    const normal=localService();
    const view=await page({service:call=>call.path===`/v1/${phase}`?new Promise(resolve=>{release=resolve;}):normal(call),beforeApp:window=>{
      if(phase==='permission')Object.defineProperty(window.navigator,'permissions',{value:{query:()=>new Promise(resolve=>{release=()=>resolve({state:'prompt'});})}});
    }});
    try{
      view.document.querySelector('#description-mode').click();find(view);await until(()=>release);
      const pending=view.localRequests.at(-1);
      if(action==='cancel')view.document.querySelector('#cancel-ai-search').click();
      if(action==='mode')view.document.querySelector('#keyword-mode').click();
      if(action==='pagehide')view.window.dispatchEvent(new view.window.Event('pagehide'));
      if(pending)assert.equal(pending.options.signal.aborted,true);
      release(phase==='session'?{ok:true,token:fixtureToken,expiresIn:1800}:{ok:true,version:'6.5.0',protocolVersion:1});await delay(0);
      assert.equal(view.localRequests.some(call=>call.path==='/v1/search'),false,`${phase}/${action} must not start late AI.`);
      assert.equal(view.localRequests.some(call=>call.path==='/v1/cancel'),false,'A handshake has no inference to cancel.');
      if(action==='pagehide')view.window.dispatchEvent(new view.window.Event('pageshow'));
      assert.equal(view.document.querySelector('#find-with-ai').disabled,false);
    }finally{view.close();}
  }
});

test('malformed handshakes never start inference and offer retry without a Connect button',async()=>{
  for(const reply of [{ok:true,token:'unsafe',expiresIn:1800},{ok:true,token:fixtureToken+'\n',expiresIn:1800},{ok:true,token:fixtureToken,expiresIn:0},{ok:true,token:fixtureToken,expiresIn:1801}]){
    const view=await page({service:call=>call.path==='/v1/status'?{ok:true,version:'6.5.0',protocolVersion:1}:reply});
    try{
      view.document.querySelector('#description-mode').click();find(view);await finished(view);
      assert.match(view.document.querySelector('#discovery-status').textContent,/Install or open/);
      assert.equal(view.document.querySelector('#local-connection-help').hidden,false);
      assert.equal(view.localRequests.some(call=>call.path==='/v1/search'),false);
    }finally{view.close();}
  }
  const badVersion=await page({service:()=>({ok:true,version:'6.5.0\n',protocolVersion:1})});
  try{
    badVersion.document.querySelector('#description-mode').click();find(badVersion);await finished(badVersion);
    assert.match(badVersion.document.querySelector('#discovery-status').textContent,/version 6.5/);
    assert.deepEqual(badVersion.localRequests.map(call=>call.path),['/v1/status']);
  }finally{badVersion.close();}
});

test('minimal search and conditional recovery messages follow every interface language',async()=>{
  const messages=[
    'Install or open MacHelper, then try Find with AI again.',
    'Allow local or loopback network access for this website in your browser’s site settings, then try Find with AI again.',
    'Update MacHelper to version 6.5 or later, then try Find with AI again.',
    'Connection timed out. Check that MacHelper is running, then try Find with AI again.',
    'Could not renew the MacHelper connection. Try Find with AI again.'
  ];
  const translations={};require('node:vm').runInNewContext(localesScript,{window:translations});
  for(const code of interfaceLocales){
    if(code!=='en')for(const message of messages)assert.ok(Object.hasOwn(translations.MARKET_TRANSLATIONS[code],message),`${code}: ${message}`);
    const view=await page({storedLanguage:code});
    try{
      view.document.querySelector('#description-mode').click();
      assert.equal(view.document.querySelector('#discovery-status').textContent,'',`${code}: normal search has no explanatory footer`);
      assert.equal(view.document.querySelectorAll('#description-search .discovery-note').length,0);
      find(view);await finished(view);
      assert.equal(view.document.querySelector('#discovery-status').textContent,view.window.MarketI18n.t(messages[0]));
      assert.equal(view.document.querySelector('#local-connection-help').hidden,false);
      assert.equal(view.document.querySelector('#connect-machelper'),null);
    }finally{view.close();}
  }
});

test('illustration copy and every preview location follow all interface languages without AI or changing a query', async () => {
  const data = clone(catalog);
  const staticTool = clone(data.extensions.find(tool => tool.slug === 'polish-input'));
  const artworkRoot = 'https://raw.githubusercontent.com/independent/example/' + 'a'.repeat(40) + '/marketplace/';
  const fallbackImage = Object.fromEntries(interfaceLocales.map(locale => [locale, `${artworkRoot}preview-${locale}.svg`]));
  Object.assign(staticTool, { id: 'example.static', slug: 'static-example', name: 'Static example',
    preview: { ...staticTool.preview, layout: 'future-layout', fallbackImage } });
  data.extensions.push(staticTool);
  let inferenceCalls = 0;
  const view = await page({ data, service: localService(() => { inferenceCalls++; return {ok:true,search:{matches:[],noMatchReason:'No match'}}; }) });
  try {
    view.document.querySelector('#description-mode').click();
    const draft = 'Keep this request exactly as I typed it.';
    input(view, '#need-query', draft);
    view.window.location.hash = '#extension/translation';
    await until(() => view.document.querySelector('#tool-dialog').open);
    for (const code of interfaceLocales) {
      input(view, '#site-language', code, 'change');
      for (const element of view.document.querySelectorAll('[data-preview-field]')) {
        const table = element.closest('.lookup-demo') ? lookupCopy : revisionCopy;
        assert.equal(element.textContent, table[code][element.dataset.previewField], `${code}: decorative illustration copy`);
      }
      assert.equal(view.document.querySelector('.popover-header strong').textContent, 'Translation');
      const staticPreview = view.document.querySelector('a.card-visual[href="#extension/static-example"] img');
      assert.equal(staticPreview.src, fallbackImage[code]);
      assert.equal(staticPreview.alt, revisionCopy[code].description);
      assert.equal(staticPreview.lang, code);
      assert.equal(view.document.querySelector('#need-query').value, draft);
      assert.equal(inferenceCalls, 0);
      assert.equal(view.requests.length, 1);
    }
  } finally { view.close(); }
});

test('a browser without CSS animation uses the extension image for hero, card and details', async () => {
  const data = clone(catalog);
  const translation = data.extensions.find(tool => tool.slug === 'translation');
  const base = 'https://raw.githubusercontent.com/independent/example/' + 'a'.repeat(40) + '/marketplace/';
  translation.preview.fallbackImage = { en: base + 'en.svg', es: base + 'es.svg' };
  const polish = data.extensions.find(tool => tool.slug === 'polish-input');
  polish.preview.fallbackImage = base + 'polish.svg';
  const view = await page({ data, storedLanguage: 'es', beforeApp(window) {
    window.CSS = { supports: () => false };
  } });
  try {
    const selectors = ['#hero-preview img', 'a.card-visual[href="#extension/translation"] img', '#overview-panel figure img'];
    view.window.location.hash = '#extension/translation';
    await until(() => view.document.querySelector('#tool-dialog').open);
    for (const selector of selectors) {
      const node = view.document.querySelector(selector);
      assert.equal(node.src, translation.preview.fallbackImage.es);
      assert.equal(node.alt, lookupCopy.es.description);
      assert.equal(node.lang, 'es');
    }
    assert.equal(view.document.querySelector('a.card-visual[href="#extension/polish-input"] img').src, polish.preview.fallbackImage);
    input(view, '#site-language', 'ar', 'change');
    for (const selector of selectors) {
      const node = view.document.querySelector(selector);
      assert.equal(node.src, translation.preview.fallbackImage.en);
      assert.equal(node.alt, lookupCopy.en.description);
      assert.equal(node.lang, 'en');
    }
    assert.equal(view.requests.length, 1);
    assert.deepEqual(view.localRequests, []);
  } finally { view.close(); }
});

test('third-party lookup, image and icon-only previews render from catalog data', async () => {
  const data = clone(catalog);
  const malicious = '<img id="preview-injection" src=x onerror=alert(1)> & synthetic';
  const sampleTool = clone(data.extensions.find(tool => tool.slug === 'translation'));
  const imageURL = 'https://raw.githubusercontent.com/example/tools/' + 'a'.repeat(40) + '/marketplace/example.webp';
  const lookup = { id: 'example.lookup', slug: 'example-lookup', name: 'Independent lookup',
    preview: { schemaVersion: 1, layout: 'lookup', strings: { en: { ...sampleTool.preview.strings.en }, es: { copy: malicious } } },
    screenshots: [] };
  const imageTool = { id: 'example.image', slug: 'example-image', name: 'Independent image',
    preview: { schemaVersion: 1, layout: 'image', image: imageURL, strings: {
      en: { description: 'A screenshot of the extension', caption: 'Example workflow' },
      es: { description: 'Captura de la extensión' }
    } }, screenshots: [] };
  const iconTool = { id: 'example.icon', slug: 'example-icon', name: 'Icon only',
    preview: { ...imageTool.preview, image: 'https://unapproved.example/preview.webp' }, screenshots: [] };
  data.extensions.push(...[lookup, imageTool, iconTool].map(tool => ({ ...sampleTool, ...tool })));
  data.featuredExtension = lookup.id;
  const view = await page({ data, storedLanguage: 'es' });
  try {
    const hero = view.document.querySelector('#hero-preview .lookup-demo');
    assert.equal(hero.querySelector('.stage-topline').textContent, lookup.name);
    assert.equal(hero.querySelector('[data-preview-field="copy"]').textContent, malicious);
    assert.equal(hero.querySelector('[data-preview-field="copy"]').lang, 'es');
    assert.equal(hero.querySelector('[data-preview-field="word"]').lang, 'en');
    assert.equal(view.document.querySelector('#preview-injection'), null);
    const icon = view.document.querySelector('a[href="#extension/example-icon"] .card-visual-icon');
    assert.ok(icon, 'An unapproved image uses the ordinary extension icon.');
    const screenshot = view.document.querySelector('a[href="#extension/example-image"] img');
    assert.equal(screenshot.src, imageURL);
    assert.equal(screenshot.alt, 'Captura de la extensión');
    screenshot.dispatchEvent(new view.window.Event('error'));
    assert.ok(screenshot.src.endsWith('/assets/mac-helper.png'));
    view.window.location.hash = '#extension/example-image';
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.equal(view.document.querySelector('.detail-preview img').src, imageURL);
    assert.equal(view.document.querySelector('.detail-preview figcaption').textContent, 'Example workflow');
    assert.equal(view.document.querySelector('.detail-preview figcaption').lang, 'en');
    assert.equal(view.requests.length, 1);
    assert.deepEqual(view.localRequests, []);
  } finally { view.close(); }
});

test('extension preview copy and markup come from the catalog renderer', () => {
  const dom = new JSDOM(html);
  try {
    const { document } = dom.window;
    assert.equal(document.querySelector('#hero-preview')?.children.length, 0);
    assert.equal(document.querySelector('.hero-stage, template'), null);
    assert.doesNotMatch(html, /Could you give me a hand|I finished update/);
  } finally { dom.window.close(); }
});

function demoEnvironment({ reducedMotion = false } = {}) {
  let window, observer, hidden = false;
  const timers = new Map(), mediaListeners = new Set();
  const media = {
    matches: reducedMotion,
    addEventListener(type, callback) { if (type === 'change') mediaListeners.add(callback); }
  };
  return {
    install(browserWindow) {
      window = browserWindow;
      Object.defineProperty(window.document, 'hidden', { configurable: true, get: () => hidden });
      window.matchMedia = query => {
        assert.equal(query, '(prefers-reduced-motion: reduce)');
        return media;
      };
      window.IntersectionObserver = class {
        constructor(callback, options) { observer = { callback, options, targets: new Set(), disconnected: false }; }
        observe(target) { observer.targets.add(target); }
        unobserve(target) { observer.targets.delete(target); }
        disconnect() { observer.targets.clear(); observer.disconnected = true; }
      };
      const setTimer = window.setTimeout.bind(window), clearTimer = window.clearTimeout.bind(window);
      window.setTimeout = (callback, milliseconds, ...args) => {
        const id = setTimer(() => { timers.delete(id); callback(...args); }, milliseconds);
        timers.set(id, { milliseconds });
        return id;
      };
      window.clearTimeout = id => { timers.delete(id); clearTimer(id); };
    },
    intersect(target, ratio) {
      if (typeof target === 'string') target = window.document.querySelector(target);
      assert.ok(observer.targets.has(target), 'The demo must be observed before receiving visibility changes.');
      assert.ok(Array.from(observer.options.threshold).includes(0.2));
      observer.callback([{ target, isIntersecting: ratio > 0, intersectionRatio: ratio }]);
    },
    visibility(isHidden) {
      hidden = isHidden;
      window.document.dispatchEvent(new window.Event('visibilitychange'));
    },
    motion(reduce) {
      media.matches = reduce;
      for (const listener of mediaListeners) listener({ matches: reduce });
    },
    observed(target) { return observer.targets.has(target); },
    get pendingTimers() { return timers.size; },
    get disconnected() { return observer.disconnected; }
  };
}

test('all Translation showcases share the contextual-word demo, localized content and unique accessible identities', async () => {
  const view = await page();
  try {
    const hero = view.document.querySelector('#hero-preview .lookup-demo');
    const card = [...view.document.querySelectorAll('.extension-card')].find(node => node.querySelector('.card-heading a')?.getAttribute('href') === '#extension/translation');
    assert.ok(hero);
    assert.ok(card.querySelector('.lookup-demo'));
    assert.equal(view.document.querySelector('#spotlight'), null);
    assert.equal(view.document.querySelectorAll('.lookup-demo').length, 2);
    view.window.location.hash = '#extension/translation';
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.ok(view.document.querySelector('#overview-panel .lookup-demo'));
    assert.equal(view.document.querySelectorAll('.lookup-demo').length, 3);
    assert.equal(view.document.querySelector('#hero-preview > img, .detail-preview img'), null);
    const ids = [...view.document.querySelectorAll('[id]')].map(node => node.id);
    assert.equal(new Set(ids).size, ids.length, 'Cloning the demo must not duplicate IDs.');
    for (const code of interfaceLocales) {
      input(view, '#site-language', code, 'change');
      for (const demo of view.document.querySelectorAll('.lookup-demo')) {
        assert.equal(demo.querySelector('button, [role="button"]'), null, 'Previews play automatically without playback buttons.');
        for (const element of demo.querySelectorAll('[data-preview-field]')) {
          assert.equal(element.textContent, lookupCopy[code][element.dataset.previewField], `${code}: every demo follows the language choice`);
        }
        assert.equal(demo.querySelector('.stage-topline').textContent, 'Translation');
        const selectedWord = demo.querySelector('[data-preview-field="word"]');
        assert.equal(selectedWord.textContent, 'hand');
        assert.ok(selectedWord.closest('mark'), 'Only the contextual word should be highlighted.');
        assert.equal(['sentenceBefore', 'word', 'sentenceAfter'].map(key => demo.querySelector(`[data-preview-field="${key}"]`).textContent).join(''), 'Could you give me a hand with this report?');
        assert.ok(demo.querySelector('[data-preview-field="meaning"]').textContent);
        assert.ok(demo.querySelector('[data-preview-field="sentenceTranslation"]').textContent);
        for (const attribute of ['aria-labelledby', 'aria-describedby']) {
          const target = view.document.getElementById(demo.getAttribute(attribute));
          assert.ok(target && demo.contains(target), `${attribute} must resolve within the same demo`);
        }
      }
    }
    assert.match(lookupCopy.en.meaning, /help/);
    assert.notEqual(lookupCopy.en.meaningLabel, lookupCopy.en.sentenceLabel);
    assert.equal(view.requests.length, 1, 'Reusing or localizing a demo requires no new requests.');
  } finally { view.close(); }
});

test('Polish-input previews illustrate selection, review and Apply in the collection and overview for every language', async () => {
  const view = await page();
  try {
    assert.equal(view.document.querySelector('.hero .revision-demo'), null);
    const card = view.document.querySelector('a.card-visual[href="#extension/polish-input"]');
    assert.ok(card.querySelector('.revision-demo'));
    card.click();
    await until(() => view.document.querySelector('#tool-dialog').open);
    for (const code of interfaceLocales) {
      input(view, '#site-language', code, 'change');
      const previews = view.document.querySelectorAll('.revision-demo');
      assert.equal(previews.length, 2);
      assert.ok(view.document.querySelector('#overview-panel .revision-demo'));
      for (const demo of previews) {
        assert.equal(demo.querySelector('button, [role="button"], input, textarea, [contenteditable]'), null);
        for (const attribute of ['aria-labelledby', 'aria-describedby']) {
          const target = view.document.getElementById(demo.getAttribute(attribute));
          assert.ok(target && demo.contains(target), `${attribute} describes the correct Polish-input preview`);
        }
        for (const key of ['draft', 'result', 'apply', 'selectStep', 'reviewStep', 'resultStep']) {
          const value = demo.querySelector(`[data-preview-field="${key}"]`).textContent;
          assert.equal(value, revisionCopy[code][key], `${code}: ${key}`);
        }
      }
      assert.equal(card.querySelector('img'), null);
      assert.equal(view.document.querySelector('.detail-preview img'), null);
    }
    assert.equal(view.requests.length, 1);
    assert.deepEqual(view.localRequests, []);
  } finally { view.close(); }
});

test('visible demos autoplay and suspend outside the active view without requests or timers', async () => {
  const environment = demoEnvironment();
  const localCalls = [];
  const view = await page({ beforeApp: environment.install, service: call => localCalls.push(call) });
  try {
    const demo = view.document.querySelector('#hero-preview .lookup-demo');
    const playing = () => demo.classList.contains('demo-playing');
    environment.intersect(demo, 0.19);
    assert.equal(playing(), false);
    environment.intersect(demo, 0.2);
    assert.equal(playing(), true);
    assert.equal(environment.pendingTimers, 0, 'CSS playback must not schedule JavaScript completion or loop timers.');
    environment.intersect(demo, 0);
    assert.equal(playing(), false);
    environment.intersect(demo, 1);
    assert.equal(playing(), true, 'Returning to a visible showcase should automatically resume playback.');

    environment.visibility(true);
    assert.equal(playing(), false);
    environment.visibility(false);
    assert.equal(playing(), true);
    input(view, '#site-language', 'ar', 'change');
    assert.equal(view.document.documentElement.dir, 'rtl');
    assert.equal(playing(), true, 'Changing the language should preserve visible autoplay.');
    assert.equal(demo.querySelector('[data-preview-field="meaning"]').textContent, lookupCopy.ar.meaning);

    const cardPreviews = () => [...view.document.querySelectorAll('.extension-card .lookup-demo, .extension-card .revision-demo')];
    const oldCards = cardPreviews();
    assert.equal(oldCards.length, 2);
    assert.ok(oldCards.every(card => environment.observed(card)));
    input(view, '#search', 'no-match-for-cleanup');
    assert.ok(oldCards.every(card => !card.isConnected && !environment.observed(card)), 'Filtered-out demos must be unobserved.');
    input(view, '#search', '');
    const newCards = cardPreviews();
    assert.equal(newCards.length, 2);
    for (const card of newCards) {
      environment.intersect(card, 1);
      assert.equal(card.classList.contains('demo-playing'), true);
    }

    view.window.location.hash = '#extension/translation';
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.equal(playing(), false, 'Background showcases should suspend while a modal is open.');
    assert.ok(newCards.every(card => !card.classList.contains('demo-playing')));
    const detail = view.document.querySelector('#overview-panel .lookup-demo');
    environment.intersect(detail, 1);
    assert.equal(detail.classList.contains('demo-playing'), true);
    view.document.querySelector('#install-tab').click();
    assert.equal(detail.classList.contains('demo-playing'), false, 'A hidden overview tab must not keep animating.');
    view.document.querySelector('#overview-tab').click();
    assert.equal(detail.classList.contains('demo-playing'), true);
    view.document.querySelector('#tool-dialog').close();
    assert.equal(playing(), true);
    assert.equal(detail.classList.contains('demo-playing'), false);
    view.window.dispatchEvent(new view.window.Event('pagehide'));
    assert.equal(playing(), false);
    assert.equal(environment.disconnected, true);
    view.window.dispatchEvent(new view.window.Event('pageshow'));
    assert.equal(environment.observed(demo), true, 'A page restored from the back/forward cache must observe its demos again.');
    environment.intersect(demo, 1);
    assert.equal(playing(), true);
    assert.equal(environment.pendingTimers, 0);
    assert.equal(view.requests.length, 1);
    assert.deepEqual(localCalls, [], 'Playing or translating demo copy must not call MacHelper or AI.');
  } finally { view.close(); }
});

test('both extensions respect reduced motion and resume visible autoplay only when motion is allowed', async () => {
  const environment = demoEnvironment({ reducedMotion: true });
  const view = await page({ beforeApp: environment.install });
  try {
    const demos = [...view.document.querySelectorAll('.lookup-demo, .revision-demo')];
    assert.equal(demos.length, 3);
    for (const demo of demos) {
      environment.intersect(demo, 1);
      assert.equal(demo.classList.contains('demo-playing'), false);
      const resultKey = demo.classList.contains('revision-demo') ? 'result' : 'meaning';
      assert.equal(demo.querySelector(`[data-preview-field="${resultKey}"]`).textContent, (resultKey === 'result' ? revisionCopy : lookupCopy).en[resultKey]);
    }
    assert.equal(environment.pendingTimers, 0);
    environment.motion(false);
    for (const demo of demos) assert.equal(demo.classList.contains('demo-playing'), true);
    environment.motion(true);
    for (const demo of demos) assert.equal(demo.classList.contains('demo-playing'), false);
    view.window.location.hash = '#extension/polish-input';
    await until(() => view.document.querySelector('#tool-dialog').open);
    const detail = view.document.querySelector('#overview-panel .revision-demo');
    environment.intersect(detail, 1);
    assert.equal(detail.classList.contains('demo-playing'), false);
    environment.motion(false);
    assert.equal(detail.classList.contains('demo-playing'), true);
    view.document.querySelector('#install-tab').click();
    assert.equal(detail.classList.contains('demo-playing'), false);
    assert.equal(environment.pendingTimers, 0);
    assert.equal(view.requests.length, 1);
  } finally { view.close(); }
});
