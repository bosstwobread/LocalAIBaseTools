const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
const script = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');
const catalogPath = path.join(__dirname, 'dist/data/extensions.json');
if (!fs.existsSync(catalogPath)) throw new Error('Build the static fixture first: python3 ExtensionMarket-website/build.py --without-app');
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
const clone = value => JSON.parse(JSON.stringify(value));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function page({ base = 'https://market.example/extension-market/', data = clone(catalog), failFirst = false } = {}) {
  const dom = new JSDOM(html, { url: base, runScripts: 'outside-only', pretendToBeVisual: true });
  const { window } = dom;
  const requests = [];
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
    assert.equal(count(), 2);
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
    assert.equal(count(), 2);
    input(view, '#category', 'Translation', 'change');
    assert.equal(count(), 1);
    input(view, '#platform', 'Chrome', 'change');
    assert.equal(count(), 0);
    view.document.querySelector('#clear-filters').click();
    assert.equal(count(), 2);
    input(view, '#platform', 'Edge', 'change');
    assert.equal(count(), 1);
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
    const open = view.document.querySelector('a[href^="machelper:"]');
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
    [...view.document.querySelectorAll('.card-install')].find(node => node.textContent.includes('Get extension')).click();
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
    await until(() => view.document.querySelectorAll('.extension-card').length === 2);
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
    assert.equal(view.document.querySelectorAll('script').length, 1, 'Only the static application script should exist');
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
