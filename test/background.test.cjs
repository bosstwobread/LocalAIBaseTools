const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');

const extensionID = 'fmhfobfddchbeibojepeocgfemkpcklo';
const source = fs.readFileSync(path.join(__dirname, '../legacy/MessageHelper-Upwork/background.js'), 'utf8');

function background() {
  let requestListener;
  let nativeListener;
  let disconnectListener;
  const sent = [];
  const hosts = [];
  const chrome = {runtime: {
    id: extensionID,
    onMessage: {addListener: fn => { requestListener = fn; }},
    connectNative(host) {
      hosts.push(host);
      return {
        onMessage: {addListener: fn => { nativeListener = fn; }},
        onDisconnect: {addListener: fn => { disconnectListener = fn; }},
        postMessage: message => sent.push(message)
      };
    }
  }};
  vm.runInNewContext(source, {chrome, crypto: webcrypto, TextEncoder, URL, setTimeout, clearTimeout});
  const send = (message, sender = {id: extensionID, url: 'https://www.upwork.com/ab/messages/rooms/test'}) => {
    let keepAlive;
    const promise = new Promise(resolve => { keepAlive = requestListener(message, sender, resolve); });
    return {promise, keepAlive};
  };
  return {send, sent, hosts, reply: message => nativeListener(message), disconnect: () => disconnectListener()};
}

const request = (overrides = {}) => ({type: 'MESSAGEHELPER_REQUEST', action: 'polish',
  text: 'SYNTHETIC TEST: I will finish tomorrow.', targetLanguage: 'zh-CN', tone: 'professional', ...overrides});

test('native helper requests are restricted to this extension and supported Upwork routes', async () => {
  const bg = background();
  for (const sender of [
    {id: extensionID, url: 'https://www.upwork.com.evil.example/ab/messages/rooms/test'},
    {id: extensionID, url: 'https://www.upwork.com/nx/search/jobs/'},
    {id: extensionID, url: 'https://www.upwork.com/ab/feedbacks/'},
    {id: extensionID, url: 'https://www.upwork.com/ab/feedbacks/f/contract/test/unsupported'},
    {id: extensionID, url: 'https://www.upwork.com.evil.example/ab/feedbacks/f/contract/test'},
    {id: extensionID, url: 'http://www.upwork.com/ab/messages/rooms/test'},
    {id: 'another-extension', url: 'https://www.upwork.com/ab/messages/rooms/test'},
    {id: extensionID, url: 'chrome-extension://another-extension/popup.html'}
  ]) {
    const operation = bg.send(request(), sender);
    assert.equal(operation.keepAlive, false);
    const response = await operation.promise;
    assert.equal(response.ok, false);
    assert.match(response.error, /not authorized/);
  }
  assert.equal(bg.sent.length, 0);
  assert.equal(bg.hosts.length, 0);
});

test('feedback drafts on the supported contract form can reach the helper without any submit action', async () => {
  const bg = background();
  for (const action of ['polish', 'translate']) {
    const operation = bg.send(request({action}),
      {id: extensionID, url: 'https://www.upwork.com/ab/feedbacks/f/contract/synthetic'});
    assert.equal(operation.keepAlive, true);
    assert.equal(bg.sent.at(-1).action, action);
    bg.reply({id: bg.sent.at(-1).id, ok: true, text: 'Synthetic feedback result.'});
    assert.equal((await operation.promise).ok, true);
  }
});

test('unsupported actions and invalid inputs never reach the helper', async () => {
  const bg = background();
  for (const invalid of [
    {action: 'send'}, {action: 'execute'}, {text: ''}, {text: ' '.repeat(2)},
    {text: 'a'.repeat(24001)}, {targetLanguage: 'not-a-language'}, {tone: 'not-a-tone'},
    {model: ['invalid']}, {model: 'future\nmodel'}, {model: 'm'.repeat(201)}, {model: '   '}
  ]) {
    const response = await bg.send(request(invalid)).promise;
    assert.equal(response.ok, false);
  }
  assert.equal(bg.sent.length, 0);
});

test('concurrent answers match their request IDs and ignore unrelated responses', async () => {
  const bg = background();
  const first = bg.send(request());
  const second = bg.send(request({action: 'ping'}),
    {id: extensionID, url: `chrome-extension://${extensionID}/sandbox.html`});
  assert.equal(first.keepAlive, true);
  assert.equal(second.keepAlive, true);
  assert.equal(bg.hosts.length, 1);
  assert.equal(bg.hosts[0], 'com.localaibasetools.mac_helper');
  bg.reply({id: 'unknown', ok: true, text: 'ignore'});
  bg.reply({id: bg.sent[1].id, ok: true, text: '第二条'});
  bg.reply({id: bg.sent[0].id, ok: true, text: 'First result'});
  assert.equal((await first.promise).text, 'First result');
  assert.equal((await second.promise).text, '第二条');
});

test('disconnect resolves pending requests with an actionable failure', async () => {
  const bg = background();
  const operation = bg.send(request());
  bg.disconnect();
  const response = await operation.promise;
  assert.equal(response.ok, false);
  assert.match(response.error, /disconnected/);
});

test('a second AI request is rejected while an inference is active', async () => {
  const bg = background();
  const first = bg.send(request());
  const second = await bg.send(request({action: 'translate'})).promise;
  assert.equal(second.ok, false);
  assert.match(second.error, /wait/);
  const catalog = await bg.send(request({action: 'listModels', text: ''})).promise;
  assert.equal(catalog.ok, false);
  assert.match(catalog.error, /wait/);
  assert.equal(bg.sent.length, 1);
  bg.reply({id: bg.sent[0].id, ok: true, text: 'Completed first request.'});
  assert.equal((await first.promise).ok, true);
});

test('malformed native response fails instead of displaying non-text data', async () => {
  const bg = background();
  const operation = bg.send(request());
  bg.reply({id: bg.sent[0].id, ok: true, text: {unexpected: true}});
  const response = await operation.promise;
  assert.equal(response.ok, false);
  assert.match(response.error, /invalid response/);
});

test('future model identifiers are forwarded without a static model allowlist', async () => {
  const bg = background();
  for (const action of ['translate', 'polish']) {
    const operation = bg.send(request({action, model: 'future-model-2040-custom'}));
    assert.equal(bg.sent.at(-1).model, 'future-model-2040-custom');
    bg.reply({id: bg.sent.at(-1).id, ok: true, text: 'Synthetic answer.', model: 'future-model-2040-custom'});
    const response = await operation.promise;
    assert.equal(response.ok, true);
    assert.equal(response.model, 'future-model-2040-custom');
  }
});

test('catalog discovery needs no message text and is correlated independently of a ping', async () => {
  const bg = background();
  const ping = bg.send(request({action: 'ping', text: ''}));
  const discovery = bg.send(request({action: 'listModels', text: ''}));
  assert.equal(bg.sent.length, 2);
  const model = {model: 'future-catalog-model', displayName: 'Future catalog label', isDefault: true,
    defaultReasoningEffort: 'high', supportedReasoningEfforts: ['low', 'high'], ignoredPrivateField: 'do not forward'};
  bg.reply({id: bg.sent[1].id, ok: true, models: [model], defaultModel: model.model});
  const response = await discovery.promise;
  assert.equal(response.ok, true);
  assert.equal(response.models.length, 1);
  assert.equal(response.models[0].model, model.model);
  assert.equal(response.models[0].displayName, model.displayName);
  assert.equal(response.models[0].ignoredPrivateField, undefined);
  assert.equal(response.defaultModel, model.model);
  bg.reply({id: bg.sent[0].id, ok: true, text: 'Completed.'});
  assert.equal((await ping.promise).ok, true);
});

test('malformed model catalog does not become selectable models', async () => {
  const bg = background();
  const discovery = bg.send(request({action: 'listModels', text: ''}));
  bg.reply({id: bg.sent[0].id, ok: true, models: [{model: ['invalid'], displayName: 'Invalid', isDefault: true}]});
  const response = await discovery.promise;
  assert.equal(response.ok, false);
  assert.match(response.error, /catalog|invalid|model/i);
});

test('an empty local provider catalog remains a valid discovery response', async () => {
  const bg = background();
  const discovery = bg.send(request({action: 'listModels', text: ''}));
  bg.reply({id: bg.sent[0].id, ok: true, models: []});
  const response = await discovery.promise;
  assert.equal(response.ok, true);
  assert.equal(response.models.length, 0);
});

test('catalog size, model metadata controls and duplicate identities are bounded before forwarding', async () => {
  const bg = background();
  const entry = {model: 'future-bounded-model', displayName: 'Future model', isDefault: false, supportedReasoningEfforts: []};
  for (const models of [
    [{...entry, displayName: 'x'.repeat(513)}],
    [{...entry, model: 'future\u202emodel'}],
    [entry, {...entry}],
    Array.from({length: 257}, (_, n) => ({...entry, model: `future-${n}`})),
    Array.from({length: 256}, (_, n) => ({...entry, model: `future-${n}`, displayName: 'x'.repeat(512),
      supportedReasoningEfforts: Array.from({length: 16}, (_, effort) => `effort-${effort}-`.padEnd(64, 'x'))}))
  ]) {
    const discovery = bg.send(request({action: 'listModels', text: ''}));
    bg.reply({id: bg.sent.at(-1).id, ok: true, models});
    const response = await discovery.promise;
    assert.equal(response.ok, false);
    assert.match(response.error, /catalog|model/i);
  }
});

test('a larger future catalog remains supported within the protocol bound', async () => {
  const bg = background();
  const models = Array.from({length: 201}, (_, n) => ({model: `future-catalog-${n}`,
    displayName: `Future backend name ${n}`, isDefault: n === 0, supportedReasoningEfforts: []}));
  const discovery = bg.send(request({action: 'listModels', text: ''}));
  bg.reply({id: bg.sent[0].id, ok: true, models});
  const response = await discovery.promise;
  assert.equal(response.ok, true);
  assert.equal(response.models.length, 201);
  assert.equal(response.models[200].displayName, 'Future backend name 200');
});
