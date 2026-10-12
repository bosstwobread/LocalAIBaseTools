const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');

const extensionID = 'fmhfobfddchbeibojepeocgfemkpcklo';
const source = fs.readFileSync(path.join(__dirname, '../extension/background.js'), 'utf8');

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

test('unsupported actions and invalid inputs never reach the helper', async () => {
  const bg = background();
  for (const invalid of [
    {action: 'send'}, {action: 'execute'}, {text: ''}, {text: ' '.repeat(2)},
    {text: 'a'.repeat(24001)}, {targetLanguage: 'not-a-language'}, {tone: 'not-a-tone'}
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
  assert.equal(bg.hosts[0], 'com.messagehelper.gpt');
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
