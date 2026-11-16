const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const localesScript = fs.readFileSync(path.join(__dirname, 'locales.js'), 'utf8');
const i18nScript = fs.readFileSync(path.join(__dirname, 'i18n.js'), 'utf8');
const script = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');
const catalogPath = path.join(__dirname, 'dist/data/extensions.json');
if (!fs.existsSync(catalogPath)) throw new Error('Build the static fixture first: python3 ExtensionMarket-website/build.py --without-app');
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
const clone = value => JSON.parse(JSON.stringify(value));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function page({ base = 'https://market.example/extension-market/', data = clone(catalog), failFirst = false, languages = ['en-US'], storedLanguage = null, storageDisabled = false, bridge = null } = {}) {
  const dom = new JSDOM(html, { url: base, runScripts: 'outside-only', pretendToBeVisual: true });
  const { window } = dom;
  Object.defineProperty(window.navigator, 'languages', { value: languages });
  if (storedLanguage) window.localStorage.setItem('localaibasetools.website.language', storedLanguage);
  if (storageDisabled) Object.defineProperty(window, 'localStorage', { get() { throw new Error('Storage disabled fixture'); } });
  const requests = [];
  window.TextEncoder = global.TextEncoder;
  if(bridge) window.chrome={runtime:{sendMessage:bridge,lastError:null}};
  window.HTMLDialogElement.prototype.showModal = function () { this.setAttribute('open', ''); };
  window.HTMLDialogElement.prototype.close = function () {
    this.removeAttribute('open');
    this.dispatchEvent(new window.Event('close'));
  };
  window.fetch = async input => {
    requests.push(String(input));
    if (failFirst && requests.length === 1) throw new Error('Offline fixture');
    return { ok: true, json: async () => data };
  };
  window.eval(localesScript);
  window.eval(i18nScript);
  window.eval(script);
  await delay(0);
  return { dom, window, document: window.document, requests, close: () => window.close() };
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
    input(view, '#search', 'upwork');
    assert.equal(count(), 1);
    assert.match(view.document.querySelector('.card-heading').textContent, /Upwork/);
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
    input(view, '#platform', 'Edge', 'change');
    assert.equal(count(), catalog.extensions.filter(tool=>tool.platforms.includes('Edge')).length);
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

test('browser installation opens on the correct tab and links the actual ZIP', async () => {
  const view = await page();
  try {
    [...view.document.querySelectorAll('.extension-card')].find(node => node.querySelector('h3').textContent.includes('Upwork')).querySelector('.card-install').click();
    await until(() => view.document.querySelector('#tool-dialog').open);
    assert.match(view.window.location.hash, /messagehelper-upwork/);
    assert.equal(view.document.querySelector('#install-panel').hidden, false);
    const download = view.document.querySelector('#install-panel a[download]');
    assert.ok(download);
    assert.match(new URL(download.href).pathname, /^\/extension-market\/packages\/.+\.zip$/);
    assert.match(view.document.querySelector('#install-panel').textContent, /Load unpacked/);
    assert.match(view.document.querySelector('#install-panel').textContent, /listings are not available yet/);
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
      assert.ok([...view.document.querySelectorAll('.card-icon')].every(node => new URL(node.src).pathname.startsWith(`${suffix}assets/`)));
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
      view.window.location.hash = '#extension/messagehelper-upwork';
      await until(() => view.document.querySelector('#tool-dialog').open);
      assert.equal(view.document.querySelector('#overview-panel a[download="AI_EXTENSION_GUIDE.md"]'), null, 'Browser tools must not claim the source-worker editing flow');
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
    assert.equal(view.document.querySelectorAll('script').length, 3, 'Only the static catalog, localization, and application scripts should exist');
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
  data.extensions.find(tool => tool.kind === 'mac-source').permissions.push('native.execute');
  const view = await page({ languages: ['ar-EG'], data });
  try {
    assert.equal(view.document.documentElement.dir, 'rtl');
    assert.equal(view.document.querySelector('.main-nav').getAttribute('aria-label'), 'التنقل الرئيسي');
    assert.equal(view.document.querySelector('.get-identity img').alt, 'أيقونة تطبيق MacHelper');
    assert.match(view.document.querySelector('.card-visual img').alt, /معاينة/);
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
      for (const value of [tool.category, ...tool.screenshots.flatMap(shot => [shot.alt, shot.caption])]) keys.add(value);
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

test('description search is explicit, uses the connector, and renders only real tool IDs as safe suggestions', async () => {
  const calls=[];let complete;
  const view=await page({bridge:(id,message,callback)=>{
    calls.push({id,message});
    if(message.action==='status')callback({ok:true,compatible:true,version:'6.3.0'});
    if(message.action==='search')complete=callback;
  }});
  try {
    view.document.querySelector('#description-mode').click();await delay(0);
    input(view,'#need-query','Help me understand words while reading.');
    assert.equal(calls.filter(call=>call.message.action==='search').length,0,'Typing must not spend AI usage');
    view.document.querySelector('.example-query').click();
    assert.equal(calls.filter(call=>call.message.action==='search').length,0,'Examples only fill the input');
    view.document.querySelector('#find-with-ai').click();
    assert.equal(calls.at(-1).id,'kkmffpbghoojlnldpdolonpjmkhdenkh');
    const request=calls.at(-1).message;
    assert.equal(request.type,'machelper.discovery'); assert.equal(request.action,'search');
    assert.match(request.requestId,/^[A-Za-z0-9_-]{1,80}$/);
    assert.equal(view.document.querySelector('#cancel-ai-search').hidden,false);
    complete({ok:true,search:{model:'fixture-model',stale:true,matches:[
      {id:'invented.tool',fit:'good',reason:'Made up'},
      {id:'com.localaibasetools.translation',fit:'good',reason:'<img id="discovery-injection" src=x onerror=alert(1)>'},
      {id:'com.localaibasetools.translation',fit:'good',reason:'Duplicate'}
    ]}});await delay(0);
    assert.equal(view.document.querySelectorAll('.extension-card').length,1);
    assert.equal(view.document.querySelector('.discovery-match strong').textContent,'Good fit');
    assert.match(view.document.querySelector('.discovery-match p').textContent,/<img/);
    assert.equal(view.document.querySelector('#discovery-injection'),null);
    assert.match(view.document.querySelector('#discovery-model').textContent,/fixture-model.*cached/);
    assert.equal(view.window.location.hash,'','Search must not install or open a tool');
  }finally{view.close();}
});

test('cancel stops the current bridge request and ignores its late response; no-match and query edits recover', async()=>{
  const calls=[];const searches=[];
  const view=await page({bridge:(id,message,callback)=>{
    calls.push(message);
    if(message.action==='status')callback({ok:true,compatible:true});
    if(message.action==='search')searches.push(callback);
    if(message.action==='cancel')callback({ok:true,cancelled:true});
  }});
  try{
    view.document.querySelector('#description-mode').click();await delay(0);
    input(view,'#need-query','record my voice');view.document.querySelector('#find-with-ai').click();
    const request=calls.find(call=>call.action==='search');
    view.document.querySelector('#cancel-ai-search').click();
    assert.equal(calls.at(-1).action,'cancel');assert.equal(calls.at(-1).requestId,request.requestId);
    searches[0]({ok:true,search:{matches:[{id:catalog.extensions[0].id,fit:'good',reason:'Late'}]}});await delay(0);
    assert.equal(view.document.querySelector('.discovery-match'),null);
    assert.match(view.document.querySelector('#discovery-status').textContent,/cancelled/);
    view.document.querySelector('#find-with-ai').click();
    searches[1]({ok:true,search:{matches:[],noMatchReason:'No current tool records audio.'}});await delay(0);
    assert.equal(view.document.querySelectorAll('.extension-card').length,0);
    assert.match(view.document.querySelector('#no-match-reason').textContent,/records audio/);
    input(view,'#need-query','translate a word');
    assert.equal(view.document.querySelector('#no-match-reason').textContent,'');
    assert.equal(view.document.querySelectorAll('.extension-card').length,catalog.extensions.length);
  }finally{view.close();}
});

test('missing connector has a safe MacHelper prefill fallback and keyword search needs no AI',async()=>{
  const view=await page({storedLanguage:'zh-Hans'});
  try{
    input(view,'#search','Explain a selected word');
    assert.equal(view.document.querySelectorAll('.extension-card').length,1);
    view.document.querySelector('#description-mode').click();await delay(0);
    input(view,'#need-query','A & B? 翻译');
    const link=new URL(view.document.querySelector('#open-search-in-machelper').href);
    assert.equal(link.protocol,'machelper:');assert.equal(link.host,'search');
    assert.equal(link.searchParams.get('query'),'A & B? 翻译');assert.equal(link.searchParams.get('language'),'zh-Hans');
    assert.equal(view.document.querySelector('#connector-help').hidden,false);
    view.document.querySelector('#find-with-ai').click();await delay(0);
    assert.equal(view.document.querySelector('#find-with-ai').disabled,false);
    assert.match(view.document.querySelector('#discovery-status').textContent,/MacHelper/);
    assert.equal(view.window.location.hash,'');
    input(view,'#need-query','x'.repeat(2001));view.document.querySelector('#find-with-ai').click();await delay(0);
    assert.match(view.document.querySelector('#discovery-status').textContent,/2,000/);
  }finally{view.close();}
});

test('native search fallback stays disabled for blank, overlong, or NUL-containing needs',async()=>{
  const view=await page();
  try{
    view.document.querySelector('#description-mode').click();await delay(0);
    const link=view.document.querySelector('#open-search-in-machelper');
    for(const query of ['', '  \n ', 'a'.repeat(2001),'word\0private']){
      input(view,'#need-query',query);
      assert.equal(link.hasAttribute('href'),false);
      assert.equal(link.getAttribute('aria-disabled'),'true');
      assert.equal(link.tabIndex,-1);
    }
    input(view,'#need-query','Explain a selected word');
    assert.equal(link.getAttribute('aria-disabled'),'false');
    assert.equal(new URL(link.href).searchParams.get('query'),'Explain a selected word');
    assert.equal(link.tabIndex,0);
  }finally{view.close();}
});
