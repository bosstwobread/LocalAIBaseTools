const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');

const extension = path.join(__dirname, '../Extensions/MessageHelper-Upwork');
const scripts = ['shared.js', 'popup.js'].map(file => fs.readFileSync(path.join(extension, file), 'utf8'));
const markup = fs.readFileSync(path.join(extension, 'popup.html'), 'utf8');
const tick = async () => { for (let n = 0; n < 3; n++) await new Promise(resolve => setImmediate(resolve)); };
const model = (identity, label, isDefault = false) => ({model: identity, displayName: label, isDefault,
  supportedReasoningEfforts: ['low', 'high'], defaultReasoningEffort: 'low'});

function popup(t, stored = {}, catalog = () => ({ok: true, models: [model('future-2040-a', 'Future A', true)], defaultModel: 'future-2040-a'})) {
  const dom = new JSDOM(markup, {url: 'chrome-extension://fmhfobfddchbeibojepeocgfemkpcklo/popup.html', runScripts: 'outside-only'});
  const {window} = dom;
  const requests = [];
  const writes = [];
  window.TextEncoder = TextEncoder;
  window.chrome = {
    storage: {local: {
      get: async defaults => ({...defaults, ...stored}),
      set: async values => { writes.push({...values}); Object.assign(stored, values); }
    }},
    runtime: {
      sendMessage: async request => { requests.push({...request}); return catalog(request); },
      getURL: suffix => `chrome-extension://fmhfobfddchbeibojepeocgfemkpcklo/${suffix}`
    },
    tabs: {create: () => {}}
  };
  for (const script of scripts) window.eval(script);
  t.after(() => window.close());
  return {window, document: window.document, requests, stored, writes,
    choose: identity => {
      const select = window.document.querySelector('#model');
      select.value = identity;
      select.dispatchEvent(new window.Event('change', {bubbles: true}));
    },
    refresh: () => window.document.querySelector('#refresh-models').click(),
    identities: () => [...window.document.querySelector('#model').options].map(option => option.value)
  };
}

test('model options and labels come from the current desktop catalog and refresh on every popup open', async t => {
  let catalog = {ok: true, models: [model('unknown-future-A', 'Future desktop name A', true), model('unknown-future-B', 'Future desktop name B')], defaultModel: 'unknown-future-A'};
  const stored = {model: 'unknown-future-B'};
  const first = popup(t, stored, () => catalog); await tick();
  assert.deepEqual(first.identities(), ['', 'unknown-future-A', 'unknown-future-B']);
  assert.equal(first.requests.filter(request => request.action === 'listModels').length, 1);
  assert.equal(first.requests[0].text, '');
  assert.equal(first.document.querySelector('#model').value, stored.model);
  assert.match(first.document.querySelector('#model').textContent, /Future desktop name A/);
  assert.match(first.document.querySelector('#model').textContent, /Future desktop name B/);
  assert.match(first.document.querySelector('#model option[value=""]').textContent, /MacHelper default/i);
  catalog = {ok: true, models: [model('unknown-future-C', 'New future desktop name C'), model('unknown-future-B', 'Renamed desktop B', true)], defaultModel: 'unknown-future-B'};
  const second = popup(t, stored, () => catalog); await tick();
  assert.deepEqual(second.identities(), ['', 'unknown-future-C', 'unknown-future-B']);
  assert.equal(second.requests.filter(request => request.action === 'listModels').length, 1);
  assert.match(second.document.querySelector('#model').textContent, /Renamed desktop B/);
  assert.equal(second.document.querySelector('#model').value, 'unknown-future-B');
});

test('manual catalog refresh preserves a saved model and new choices persist locally', async t => {
  let catalog = {ok: true, models: [model('future-choice-A', 'Choice A', true), model('future-choice-B', 'Choice B')], defaultModel: 'future-choice-A'};
  const f = popup(t, {}, () => catalog); await tick();
  f.choose('future-choice-B'); await tick();
  assert.equal(f.stored.model, 'future-choice-B');
  catalog = {ok: true, models: [model('future-choice-B', 'Updated choice B'), model('future-choice-C', 'Choice C', true)], defaultModel: 'future-choice-C'};
  f.refresh(); await tick();
  assert.equal(f.requests.filter(request => request.action === 'listModels').length, 2);
  assert.equal(f.document.querySelector('#model').value, 'future-choice-B');
  assert.equal(f.stored.model, 'future-choice-B');
  assert.match(f.document.querySelector('#model').textContent, /Updated choice B/);
  f.choose(''); await tick();
  assert.equal(f.stored.model, '');
  assert.ok(f.writes.some(write => write.model === 'future-choice-B'));
  assert.ok(f.requests.every(request => ['listModels', 'ping'].includes(request.action)));
});

test('retired saved model remains selected and reported unavailable without silent fallback', async t => {
  const stored = {model: 'retired-future-selection'};
  const f = popup(t, stored, () => ({ok: true, models: [model('new-backend-default', 'New backend default', true)], defaultModel: 'new-backend-default'}));
  await tick();
  const selection = f.document.querySelector('#model');
  assert.equal(selection.value, 'retired-future-selection');
  assert.equal(selection.selectedOptions[0].disabled, true);
  assert.match(f.document.querySelector('#model-status').textContent, /unavailable|no longer|not.*available/i);
  assert.equal(stored.model, 'retired-future-selection');
  assert.equal(f.writes.length, 0);
});

test('configured desktop default is labeled accurately even when excluded from the visible catalog', async t => {
  const f = popup(t, {}, () => ({ok: true,
    models: [model('backend-recommended-model', 'Recommended backend model', true)],
    defaultModel: 'configured-hidden-model'}));
  await tick();
  const desktopDefault = f.document.querySelector('#model option[value=""]');
  assert.match(desktopDefault.textContent, /configured-hidden-model/);
  assert.doesNotMatch(desktopDefault.textContent, /Recommended backend model/);
  assert.equal(f.document.querySelector('#model').value, '');
  assert.equal(f.writes.length, 0);
});

test('older helper catalog failure gives update instructions and retains the saved selection', async t => {
  const stored = {model: 'keep-this-model'};
  const f = popup(t, stored, () => ({ok: false, error: 'Unsupported action.'})); await tick();
  assert.match(f.document.querySelector('#model-status').textContent, /update|rebuild|reinstall/i);
  assert.equal(stored.model, 'keep-this-model');
  assert.equal(f.writes.length, 0);
  assert.ok(f.requests.every(request => request.action === 'listModels'));
});
