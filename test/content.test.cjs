const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');

const extension = path.join(__dirname, '../legacy/MessageHelper-Upwork');
const scripts = ['shared.js', 'content.js'].map(file => fs.readFileSync(path.join(extension, file), 'utf8'));
const tick = async () => { for (let n = 0; n < 3; n++) await new Promise(resolve => setImmediate(resolve)); };
const initialDraft = 'Hi Morgan Test, I has updated the draft.';
const polished = 'Hi Morgan Test, I have updated the draft.';

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
}

function fixture(t, response = async request => ({ok: true, text: request.action === 'translate' ? '谢谢你的更新。' : polished}), storedSettings = {}) {
  const dom = new JSDOM(`<!doctype html><body>
    <section><div class="client-name">Synthetic Client</div><div data-mh-message><p>Thanks for the update.</p><p>Please keep Friday's deadline.</p><span class="end-of-message">NOT MESSAGE TEXT</span></div></section>
    <form data-mh-composer><div data-mh-editor contenteditable="true" role="textbox">${initialDraft}</div><div class="toolbar"><button data-mh-send type="submit">Send</button></div></form>
  </body>`, {url: 'https://www.upwork.com/ab/messages/rooms/synthetic', runScripts: 'outside-only', pretendToBeVisual: true});
  const {window} = dom;
  const requests = [];
  const events = {send: 0, submit: 0, keyboard: 0};
  const document = window.document;
  const editor = document.querySelector('[data-mh-editor]');
  document.querySelector('[data-mh-send]').addEventListener('click', event => { events.send++; event.preventDefault(); });
  document.querySelector('form').addEventListener('submit', event => { events.submit++; event.preventDefault(); });
  for (const name of ['keydown', 'keyup', 'keypress']) document.addEventListener(name, () => { events.keyboard++; });
  // Model the browser's insertion command without replacing it with a Send/Enter event.
  document.execCommand = (command, _ui, text) => {
    assert.equal(command, 'insertText');
    assert.equal(document.activeElement, editor);
    editor.textContent = text;
    editor.dispatchEvent(new window.Event('input', {bubbles: true}));
    return true;
  };
  window.TextEncoder = TextEncoder;
  window.chrome = {
    storage: {local: {get: async defaults => ({...defaults, ...storedSettings})}},
    runtime: {sendMessage: async request => { requests.push({...request}); return response(request); }}
  };
  for (const script of scripts) window.eval(script);
  t.after(() => window.close());
  return {window, document, editor, requests, events, storedSettings,
    click: selector => {
      const node = document.querySelector(selector);
      assert.ok(node, `Missing control: ${selector}`);
      node.click();
    },
    edit: text => {
      editor.textContent = text;
      editor.dispatchEvent(new window.Event('input', {bubbles: true}));
    },
    scan: () => window.MessageHelperContent.scan()
  };
}

function assertNoDelivery(f) {
  assert.deepEqual(f.events, {send: 0, submit: 0, keyboard: 0});
  assert.ok(f.requests.every(request => ['translate', 'polish'].includes(request.action)));
}

test('translation reads only source text and repeated scans/cache toggles do not duplicate controls', async t => {
  const f = fixture(t);
  f.scan(); f.scan();
  assert.equal(f.document.querySelectorAll('.mh-translate').length, 1);
  assert.equal(f.document.querySelectorAll('.mh-polish').length, 1);
  assert.equal(f.document.querySelector('.mh-polish').nextElementSibling, f.document.querySelector('[data-mh-send]'));
  f.click('.mh-translate'); await tick();
  assert.equal(f.requests[0].text, "Thanks for the update.\nPlease keep Friday's deadline.");
  assert.equal(f.document.querySelector('.mh-translation .mh-result').textContent, '谢谢你的更新。');
  f.scan(); f.click('.mh-translate'); await tick();
  assert.equal(f.document.querySelector('.mh-translation').hidden, true);
  f.click('.mh-translate'); await tick();
  assert.equal(f.requests.length, 1);
  assert.equal(f.document.querySelectorAll('.mh-translation').length, 1);
  assertNoDelivery(f);
});

test('recycled message nodes discard stale translation and request new source without translation contamination', async t => {
  const pending = deferred();
  const f = fixture(t, async request => f.requests.length === 1 ? pending.promise : ({ok: true, text: '<img src=x onerror=alert(1)> 新译文'}));
  f.click('.mh-translate'); await tick();
  f.document.querySelector('[data-mh-message]').textContent = 'Second synthetic message.';
  f.scan();
  pending.resolve({ok: true, text: 'STALE TRANSLATION'}); await tick();
  assert.doesNotMatch(f.document.querySelector('.mh-translation').textContent, /STALE/);
  f.click('.mh-translate'); await tick();
  assert.equal(f.requests[1].text, 'Second synthetic message.');
  assert.equal(f.document.querySelectorAll('.mh-translate').length, 1);
  assert.equal(f.document.querySelector('.mh-translation img'), null);
  assert.match(f.document.querySelector('.mh-translation').textContent, /<img/);
  assertNoDelivery(f);
});

test('model choice is forwarded to both operations and isolates the translation cache', async t => {
  const stored = {model: 'future-translation-model-A'};
  const f = fixture(t, async request => ({ok: true, text: request.action === 'translate' ? `译文 ${request.model}` : polished}), stored);
  f.click('.mh-translate'); await tick();
  assert.equal(f.requests[0].model, stored.model);
  f.click('.mh-translate'); await tick();
  f.click('.mh-translate'); await tick();
  assert.equal(f.requests.length, 1);
  stored.model = 'future-translation-model-B';
  f.click('.mh-translate'); await tick();
  assert.equal(f.requests.length, 2);
  assert.equal(f.requests[1].model, stored.model);
  assert.match(f.document.querySelector('.mh-translation .mh-result').textContent, /model-B/);
  f.click('.mh-polish'); await tick();
  assert.equal(f.requests[2].action, 'polish');
  assert.equal(f.requests[2].model, stored.model);
  assertNoDelivery(f);
});

test('Cancel keeps the original draft and Apply/Undo only insert text', async t => {
  const f = fixture(t);
  f.click('.mh-polish'); await tick();
  assert.equal(f.editor.textContent, initialDraft);
  assert.equal(f.document.querySelector('.mh-polished-text').textContent, polished);
  f.click('.mh-cancel');
  assert.equal(f.editor.textContent, initialDraft);
  assert.equal(f.document.querySelector('.mh-preview').textContent, '');
  f.click('.mh-polish'); await tick();
  f.click('.mh-apply');
  assert.equal(f.editor.textContent, polished);
  f.click('.mh-undo');
  assert.equal(f.editor.textContent, initialDraft);
  assertNoDelivery(f);
});

test('Apply refuses a draft edited while GPT is responding, even if text is changed back', async t => {
  const pending = deferred();
  const f = fixture(t, () => pending.promise);
  f.click('.mh-polish'); await tick();
  f.edit('A newer synthetic draft.');
  f.edit(initialDraft);
  pending.resolve({ok: true, text: polished}); await tick();
  f.click('.mh-apply');
  assert.equal(f.editor.textContent, initialDraft);
  assert.equal(f.document.querySelector('.mh-apply').disabled, true);
  assert.match(f.document.querySelector('.mh-preview').textContent, /draft or conversation changed/);
  assertNoDelivery(f);
});

test('Apply refuses a preview after navigating to a different conversation', async t => {
  const f = fixture(t);
  f.click('.mh-polish'); await tick();
  f.window.history.pushState({}, '', '/ab/messages/rooms/another-synthetic');
  f.click('.mh-apply');
  assert.equal(f.editor.textContent, initialDraft);
  assert.equal(f.document.querySelector('.mh-apply').disabled, true);
  assertNoDelivery(f);
});

test('Undo cannot replace an edit made after Apply', async t => {
  const f = fixture(t);
  f.click('.mh-polish'); await tick();
  f.click('.mh-apply');
  const newer = 'My newer draft must be retained.';
  f.edit(newer);
  f.click('.mh-undo');
  assert.equal(f.editor.textContent, newer);
  assert.equal(f.document.querySelector('.mh-undo').disabled, true);
  assert.match(f.document.querySelector('.mh-preview').textContent, /cannot replace your newer text/);
  assertNoDelivery(f);
});

test('partial editor failure retains the original and guards recovery against later edits', async t => {
  const f = fixture(t);
  f.document.execCommand = command => {
    assert.equal(command, 'insertText');
    f.editor.textContent = 'Partial editor insertion';
    f.editor.dispatchEvent(new f.window.Event('input', {bubbles: true}));
    return false;
  };
  f.click('.mh-polish'); await tick();
  f.click('.mh-apply');
  assert.equal(f.document.querySelector('.mh-original').open, true);
  assert.equal(f.document.querySelector('.mh-original .mh-result').textContent, initialDraft);
  assert.match(f.document.querySelector('.mh-status').textContent, /could not apply/);
  f.edit('A newer edit after the failed insertion.');
  f.click('.mh-undo');
  assert.equal(f.editor.textContent, 'A newer edit after the failed insertion.');
  assert.equal(f.document.querySelector('.mh-undo').disabled, true);
  assertNoDelivery(f);
});

test('injected controls have button type and manifest access is limited to intended routes', t => {
  const f = fixture(t);
  for (const control of f.document.querySelectorAll('[data-messagehelper="true"]button, button[data-messagehelper="true"]')) {
    assert.equal(control.type, 'button');
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(extension, 'manifest.json')));
  assert.deepEqual(manifest.permissions.slice().sort(), ['nativeMessaging', 'storage']);
  assert.deepEqual(manifest.content_scripts[0].matches, ['https://www.upwork.com/ab/messages/*', 'https://www.upwork.com/nx/proposals/*', 'https://www.upwork.com/ab/feedbacks/f/contract/*']);
  assert.equal(manifest.host_permissions, undefined);
  assertNoDelivery(f);
});
