const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');

const extension = path.join(__dirname, '../extension');
const tick = async () => { for (let n = 0; n < 3; n++) await new Promise(resolve => setImmediate(resolve)); };
const publicDraft = 'The client communicate clearly and pay on time.';
const privateDraft = 'I would works with this client again.';

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
}

function fixture(t, options = {}) {
  const dom = new JSDOM(`<!doctype html><body>
    <form ${options.sandbox ? 'data-mh-feedback' : ''}>
      <label>Rating <select name="rating"><option value="5" selected>5</option><option value="4">4</option></select></label>
      <div data-field="public">
        <label for="public-feedback">What would you like other freelancers to know about your experience?</label>
        <textarea id="public-feedback" ${options.publicAttributes || ''}>${publicDraft}</textarea>
      </div>
      <div data-field="private" ${options.privateHidden ? 'hidden' : ''}>
        <label for="private-feedback">Add private note</label>
        <textarea id="private-feedback">${privateDraft}</textarea>
      </div>
      <button type="submit" data-submit>Submit feedback</button>
    </form>
  </body>`, {url: options.url || 'https://www.upwork.com/ab/feedbacks/f/contract/synthetic-feedback-contract',
    runScripts: 'outside-only', pretendToBeVisual: true});
  const {window} = dom;
  const {document} = window;
  const requests = [];
  const events = {submit: 0, submitClick: 0, keyboard: 0};
  const inputValues = {public: [], private: []};
  document.querySelector('form').addEventListener('submit', event => { events.submit++; event.preventDefault(); });
  document.querySelector('[data-submit]').addEventListener('click', event => { events.submitClick++; event.preventDefault(); });
  for (const name of ['keydown', 'keyup', 'keypress']) document.addEventListener(name, () => { events.keyboard++; });
  for (const field of ['public', 'private']) {
    document.querySelector(`#${field}-feedback`).addEventListener('input', event => inputValues[field].push(event.target.value));
  }
  // Plain feedback fields should update the native value and input event, without editing commands.
  document.execCommand = () => { throw new Error('Textarea editing must not require execCommand.'); };
  window.TextEncoder = TextEncoder;
  window.chrome = {
    storage: {local: {get: async defaults => ({...defaults, model: 'feedback-model', ...options.settings})}},
    runtime: {sendMessage: async request => {
      requests.push({...request});
      return options.response ? options.response(request, requests) : ({ok: true,
        text: request.action === 'translate' ? '客户沟通清楚，并且按时付款。' : 'The client communicates clearly and pays on time.'});
    }}
  };
  for (const file of ['shared.js', 'content.js']) window.eval(fs.readFileSync(path.join(extension, file), 'utf8'));
  t.after(() => window.close());
  const field = name => document.querySelector(`[data-field="${name}"]`);
  return {window, document, requests, events, inputValues, field,
    editor: name => field(name).querySelector('textarea'),
    click: (name, selector) => {
      const control = field(name).querySelector(selector);
      assert.ok(control, `Missing ${name} feedback control: ${selector}`);
      control.click();
    },
    edit: (name, text) => {
      const editor = field(name).querySelector('textarea');
      editor.value = text;
      editor.dispatchEvent(new window.Event('input', {bubbles: true}));
    },
    scan: () => window.MessageHelperContent.scan()
  };
}

function assertNoDelivery(f) {
  assert.deepEqual(f.events, {submit: 0, submitClick: 0, keyboard: 0});
  assert.equal(f.document.querySelector('[name="rating"]').value, '5');
  assert.ok(f.requests.every(request => ['translate', 'polish'].includes(request.action)));
  for (const control of f.document.querySelectorAll('button[data-messagehelper]')) assert.equal(control.type, 'button');
}

test('public and private feedback keep independent previews, Apply and Undo without submitting', async t => {
  const f = fixture(t, {response: async request => ({ok: true, text: request.text === publicDraft
    ? 'The client communicates clearly and pays on time.' : 'I would work with this client again.'})});
  f.scan(); f.scan();
  assert.equal(f.document.querySelectorAll('.mh-feedback-tools').length, 2);
  f.click('public', '.mh-polish'); await tick();
  f.click('private', '.mh-polish'); await tick();
  assert.equal(f.editor('public').value, publicDraft);
  assert.equal(f.editor('private').value, privateDraft);
  f.click('private', '.mh-cancel');
  assert.equal(f.editor('private').value, privateDraft);
  f.click('public', '.mh-apply');
  assert.equal(f.editor('public').value, 'The client communicates clearly and pays on time.');
  assert.equal(f.editor('private').value, privateDraft);
  assert.deepEqual(f.inputValues.public, ['The client communicates clearly and pays on time.']);
  f.click('private', '.mh-polish'); await tick();
  f.click('private', '.mh-apply');
  assert.equal(f.editor('private').value, 'I would work with this client again.');
  f.click('public', '.mh-undo');
  assert.equal(f.editor('public').value, publicDraft);
  assert.equal(f.editor('private').value, 'I would work with this client again.');
  f.click('private', '.mh-undo');
  assert.equal(f.editor('private').value, privateDraft);
  assert.deepEqual(f.inputValues.private, ['I would work with this client again.', privateDraft]);
  assertNoDelivery(f);
});

test('Translate draft previews only the chosen feedback field as plain text', async t => {
  const translated = '<img src=x onerror=alert(1)> 我愿意再次合作。';
  const f = fixture(t, {response: async () => ({ok: true, text: translated, model: 'resolved-model'})});
  f.click('private', '.mh-feedback-translate'); await tick();
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].action, 'translate');
  assert.equal(f.requests[0].text, privateDraft);
  assert.equal(f.requests[0].model, 'feedback-model');
  const preview = f.field('private').querySelector('.mh-preview');
  assert.ok(preview.textContent.includes(translated));
  assert.equal(preview.querySelector('img'), null);
  assert.equal(preview.querySelector('.mh-apply'), null);
  assert.equal(f.editor('public').value, publicDraft);
  assert.equal(f.editor('private').value, privateDraft);
  assert.deepEqual(f.inputValues, {public: [], private: []});
  assertNoDelivery(f);
});

test('feedback maxlength accepts an exact UTF-16 limit and refuses oversized output without truncating', async t => {
  const exact = 'Good work. 😀';
  const f = fixture(t, {response: async (_request, requests) => ({ok: true, text: requests.length === 1 ? exact + '!' : exact})});
  const editor = f.editor('public');
  editor.maxLength = exact.length;
  f.edit('public', 'Good work');
  f.click('public', '.mh-polish'); await tick();
  f.click('public', '.mh-apply');
  assert.equal(editor.value, 'Good work');
  assert.match(f.field('public').querySelector('.mh-preview').textContent, /limit|character|max/i);
  assert.deepEqual(f.inputValues.public, ['Good work']);
  f.click('public', '.mh-polish'); await tick();
  f.click('public', '.mh-apply');
  assert.equal(editor.value, exact);
  f.click('public', '.mh-undo');
  assert.equal(editor.value, 'Good work');
  assertNoDelivery(f);
});

test('hidden, disabled and read-only feedback fields are skipped and dynamically revealed once', t => {
  const f = fixture(t, {publicAttributes: 'disabled', privateHidden: true});
  assert.equal(f.document.querySelectorAll('.mh-feedback-tools').length, 0);
  f.editor('public').disabled = false;
  f.editor('public').readOnly = true;
  f.field('private').hidden = false;
  f.field('private').style.display = 'none';
  f.scan();
  assert.equal(f.document.querySelectorAll('.mh-feedback-tools').length, 0);
  f.editor('public').readOnly = false;
  f.field('private').style.display = '';
  f.scan(); f.scan();
  assert.equal(f.field('public').querySelectorAll('.mh-feedback-tools').length, 1);
  assert.equal(f.field('private').querySelectorAll('.mh-feedback-tools').length, 1);
  assertNoDelivery(f);
});

test('Apply refuses feedback that became disabled, read-only or hidden after preview', async t => {
  for (const state of ['disabled', 'readOnly', 'hidden']) {
    const f = fixture(t);
    f.click('public', '.mh-polish'); await tick();
    if (state === 'hidden') f.field('public').style.display = 'none';
    else f.editor('public')[state] = true;
    f.click('public', '.mh-apply');
    assert.equal(f.editor('public').value, publicDraft, `Preserve ${state} feedback`);
    assert.deepEqual(f.inputValues.public, []);
    assertNoDelivery(f);
  }
});

test('feedback fields outside the feedback route are untouched, while private sandbox fixtures work', t => {
  const unrelated = fixture(t, {url: 'https://www.upwork.com/nx/search/jobs/'});
  unrelated.scan();
  assert.equal(unrelated.document.querySelectorAll('[data-messagehelper]').length, 0);
  assert.equal(unrelated.editor('public').value, publicDraft);
  assertNoDelivery(unrelated);
  const sandbox = fixture(t, {url: 'chrome-extension://messagehelper/sandbox.html', sandbox: true});
  assert.equal(sandbox.document.querySelectorAll('.mh-feedback-tools').length, 2);
  assertNoDelivery(sandbox);
});

test('retained feedback fields hide tools off-route and cannot revive stale previews or responses on return', async t => {
  const pending = deferred();
  const f = fixture(t, {response: (_request, requests) => requests.length === 2 ? pending.promise
    : Promise.resolve({ok: true, text: requests.length === 1 ? 'First polished feedback.' : 'Fresh current feedback.'})});
  f.click('public', '.mh-polish'); await tick();
  const staleApply = f.field('public').querySelector('.mh-apply');
  const retainedEditor = f.editor('public');
  f.window.history.pushState({}, '', '/nx/search/jobs/');
  // Even before the next DOM scan, a previously rendered Apply must refuse another route.
  staleApply.click();
  assert.equal(retainedEditor.value, publicDraft);
  f.scan();
  assert.equal(f.field('public').querySelector('.mh-feedback-tools').hidden, true);
  assert.equal(f.field('private').querySelector('.mh-feedback-tools').hidden, true);
  assert.equal(f.field('public').querySelector('.mh-preview').hidden, true);
  f.window.history.pushState({}, '', '/ab/feedbacks/f/contract/synthetic-feedback-contract');
  f.scan();
  assert.equal(f.editor('public'), retainedEditor);
  assert.equal(f.field('public').querySelector('.mh-feedback-tools').hidden, false);
  assert.equal(f.field('public').querySelector('.mh-preview').hidden, false);
  assert.equal(f.field('public').querySelector('.mh-apply'), null);
  staleApply.click();
  assert.equal(retainedEditor.value, publicDraft);
  f.click('public', '.mh-polish'); await tick();
  f.window.history.pushState({}, '', '/nx/search/jobs/');
  f.scan();
  f.window.history.pushState({}, '', '/ab/feedbacks/f/contract/synthetic-feedback-contract');
  f.scan();
  pending.resolve({ok: true, text: 'STALE RESPONSE FROM PREVIOUS VISIT'}); await tick();
  assert.equal(f.field('public').querySelector('.mh-preview').textContent, '');
  assert.equal(retainedEditor.value, publicDraft);
  assert.equal(f.field('public').querySelectorAll('.mh-feedback-tools').length, 1);
  f.click('public', '.mh-polish'); await tick();
  f.click('public', '.mh-apply');
  assert.equal(retainedEditor.value, 'Fresh current feedback.');
  assert.equal(f.editor('private').value, privateDraft);
  assertNoDelivery(f);
});

test('a feedback edit during a pending request cannot be overwritten, even after restoring its text', async t => {
  const pending = deferred();
  const f = fixture(t, {response: () => pending.promise});
  f.click('public', '.mh-polish'); await tick();
  f.edit('public', 'My newer feedback.');
  f.edit('public', publicDraft);
  pending.resolve({ok: true, text: 'A stale polished result.'}); await tick();
  f.click('public', '.mh-apply');
  assert.equal(f.editor('public').value, publicDraft);
  assert.equal(f.field('public').querySelector('.mh-apply').disabled, true);
  assertNoDelivery(f);
});

test('a feedback framework rejecting an insertion preserves the original and offers guarded recovery', async t => {
  const f = fixture(t);
  const editor = f.editor('public');
  editor.addEventListener('input', () => {
    if (editor.value !== publicDraft) editor.value = 'Framework rejected part of the result.';
  });
  f.click('public', '.mh-polish'); await tick();
  f.click('public', '.mh-apply');
  assert.match(f.field('public').querySelector('.mh-preview').textContent, /could not apply/i);
  assert.equal(f.field('public').querySelector('.mh-original').open, true);
  assert.equal(f.field('public').querySelector('.mh-original .mh-result').textContent, publicDraft);
  f.click('public', '.mh-undo');
  assert.equal(editor.value, publicDraft);
  assert.equal(f.editor('private').value, privateDraft);
  assertNoDelivery(f);
});

test('replacing a feedback field drops the old response and allows one fresh set of controls', async t => {
  const pending = deferred();
  const f = fixture(t, {response: (_request, requests) => requests.length === 1 ? pending.promise
    : Promise.resolve({ok: true, text: 'Fresh feedback result.'})});
  f.click('public', '.mh-polish'); await tick();
  const replacement = f.editor('public').cloneNode(true);
  replacement.value = 'New contract feedback.';
  f.editor('public').replaceWith(replacement);
  f.scan(); f.scan();
  pending.resolve({ok: true, text: 'STALE RESULT FROM REMOVED FIELD'}); await tick();
  assert.equal(f.editor('public').value, 'New contract feedback.');
  assert.doesNotMatch(f.field('public').textContent, /STALE RESULT/);
  assert.equal(f.field('public').querySelectorAll('.mh-feedback-tools').length, 1);
  f.click('public', '.mh-polish'); await tick();
  assert.equal(f.requests[1].text, 'New contract feedback.');
  f.click('public', '.mh-apply');
  assert.equal(f.editor('public').value, 'Fresh feedback result.');
  assert.equal(f.editor('private').value, privateDraft);
  assertNoDelivery(f);
});
