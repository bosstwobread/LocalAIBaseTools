const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { trustedSender, validRequest, compatible, createBridge } = require('../Extensions/MacHelper-Connector/background.js');
const TYPE = 'machelper.discovery';
const sender = (changes = {}) => ({ url: 'https://local-ai-extension.nelson007.com/', origin: 'https://local-ai-extension.nelson007.com', tab: { id: 5 }, frameId: 0, documentId: 'document-1', ...changes });
const search = (changes = {}) => ({ type: TYPE, action: 'search', requestId: 'request_1', query: 'Translate selected words', language: 'en', ...changes });
function event() {
  const listeners = new Set();
  return { addListener(fn) { listeners.add(fn); }, removeListener(fn) { listeners.delete(fn); }, emit(...args) { for (const fn of [...listeners]) fn(...args); } };
}
function fixture() {
  const ports = [], timers = new Map(), opened = [];
  let timerID = 0;
  const api = {
    runtime: { onMessageExternal: event(), getManifest: () => ({ version: '1.0.0' }), connectNative(host) {
      const port = { host, sent: [], disconnected: false, onMessage: event(), onDisconnect: event(),
        postMessage(value) { this.sent.push(value); }, disconnect() { this.disconnected = true; this.onDisconnect.emit(); } };
      ports.push(port); return port;
    } }, tabs: { onRemoved: event(), create: value => opened.push(value) }, action: { onClicked: event() }
  };
  createBridge(api, { setTimeout(fn, delay) { timers.set(++timerID, { fn, delay }); return timerID; }, clearTimeout(id) { timers.delete(id); } });
  function request(message, source = sender()) {
    const replies = [];
    api.runtime.onMessageExternal.emit(message, source, value => replies.push(value));
    return replies;
  }
  function ping(port = ports.at(-1), version = '6.3.0') {
    port.onMessage.emit({ id: port.sent[0].id, ok: true, version });
  }
  return { api, ports, timers, opened, request, ping };
}
const result = () => ({ revision: 'abcdef', updatedAt: '2026-11-17T00:00:00Z', stale: false, model: 'test-model', matches: [{ id: 'com.example.translation', reason: 'Translates selected text.', fit: 'good' }] });

test('manifest uses only native messaging, an exact origin, and the registered stable public key', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../Extensions/MacHelper-Connector/manifest.json')));
  assert.deepEqual(manifest.permissions, ['nativeMessaging']);
  assert.deepEqual(manifest.externally_connectable.matches, ['https://local-ai-extension.nelson007.com/*']);
  assert.equal(manifest.content_scripts, undefined);
  const id = crypto.createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32).replace(/[0-9a-f]/g, character => String.fromCharCode(97 + parseInt(character, 16)));
  assert.equal(id, 'kkmffpbghoojlnldpdolonpjmkhdenkh');
});

test('only official HTTPS top-level website messages are accepted', () => {
  assert.ok(trustedSender(sender()));
  assert.ok(trustedSender(sender({ origin: undefined })));
  for (const change of [{ url: 'http://local-ai-extension.nelson007.com/' }, { url: 'https://local-ai-extension.nelson007.com.evil.test/' },
    { url: 'https://user:password@local-ai-extension.nelson007.com/' }, { origin: 'null' }, { origin: 'https://evil.test' },
    { frameId: 1 }, { frameId: undefined }, { tab: undefined }, { tab: { id: -1 } }, { id: 'another-extension' }]) {
    const f = fixture();
    assert.equal(trustedSender(sender(change)), false, JSON.stringify(change));
    assert.equal(f.request(search(), sender(change))[0].ok, false);
    assert.equal(f.ports.length, 0);
  }
});

test('schema rejects arbitrary native actions and bounded input violations', () => {
  assert.ok(validRequest(search()));
  assert.ok(validRequest(search({ query: 'a'.repeat(2000) })));
  assert.ok(validRequest(search({ query: '日'.repeat(2000) })));
  assert.ok(validRequest(search({ language: undefined })));
  for (const message of [null, [], {}, { type: TYPE, action: 'translate' }, search({ query: '' }), search({ query: ' \n ' }),
    search({ query: 'a'.repeat(2001) }), search({ query: 5 }), search({ query: "a\0b" }), search({ language: 'invalid' }), search({ requestId: '../file' }),
    search({ requestId: 'a'.repeat(81) }), search({ prompt: 'ignored?' }), { type: TYPE, action: 'status', text: 'not allowed' },
    { type: TYPE, action: 'cancel', requestId: 'id', actionName: 'delete' }]) {
    const f = fixture();
    assert.equal(validRequest(message), false, JSON.stringify(message));
    assert.equal(f.request(message)[0].ok, false);
    assert.equal(f.ports.length, 0);
  }
  assert.ok(compatible('6.3.0'));
  assert.ok(compatible('7.0.0'));
  assert.equal(compatible('6.2.99'), false);
  assert.equal(compatible('unknown'), false);
});

test('status checks native host without running AI and reports old host compatibility', () => {
  const f = fixture(), replies = f.request({ type: TYPE, action: 'status' });
  assert.equal(f.ports[0].host, 'com.localaibasetools.mac_helper');
  assert.equal(f.ports[0].sent[0].action, 'ping');
  f.ping(f.ports[0], '6.2.0');
  assert.deepEqual(replies, [{ ok: true, version: '6.2.0', connectorVersion: '1.0.0', compatible: false }]);
  assert.equal(f.ports[0].sent.length, 1);
  assert.ok(f.ports[0].disconnected);
  assert.equal(f.timers.size, 0);
});

test('search preserves query, checks host version first, and returns only discovery fields', () => {
  const f = fixture(), query = '  Explain “crane” in a sentence.\n';
  const replies = f.request(search({ query, language: 'zh-Hans' }));
  const port = f.ports[0];
  assert.equal(port.sent.length, 1);
  port.onMessage.emit({ id: 'another-id', ok: true, version: '6.3.0' });
  assert.equal(port.sent.length, 1);
  f.ping();
  assert.deepEqual(port.sent[1], { id: 'discovery-request_1', action: 'searchExtensions', text: query, interfaceLanguage: 'zh-Hans' });
  const searchResult = result();
  port.onMessage.emit({ id: port.sent[1].id, ok: true, search: { ...searchResult, prompt: 'never expose' }, settings: 'never expose' });
  assert.deepEqual(replies, [{ ok: true, version: '6.3.0', search: searchResult }]);
  assert.ok(port.disconnected);
  assert.equal(f.timers.size, 0);
});

test('old MacHelper and malformed results fail without exposing general host responses', () => {
  const old = fixture(), replies = old.request(search());
  old.ping(old.ports[0], '6.2.0');
  assert.equal(replies[0].ok, false);
  assert.match(replies[0].error, /6\.3/);
  assert.equal(old.ports[0].sent.length, 1);
  const f = fixture(), response = f.request(search());
  f.ping();
  f.ports[0].onMessage.emit({ id: 'discovery-request_1', ok: true, text: 'not a discovery response', search: { ...result(), matches: [{ id: '../../invalid', reason: 'bad', fit: 'good' }] } });
  assert.equal(response[0].ok, false);
  assert.equal(response[0].text, undefined);
});

test('one search runs per tab, with cancellation restricted to its owner and request ID', () => {
  const f = fixture(), first = f.request(search());
  f.ping();
  assert.equal(f.request(search({ requestId: 'overlap' }))[0].ok, false);
  assert.equal(f.ports.length, 1);
  const cancel = { type: TYPE, action: 'cancel', requestId: 'request_1' };
  assert.deepEqual(f.request(cancel, sender({ documentId: 'different' })), [{ ok: true, cancelled: false }]);
  assert.equal(f.ports[0].disconnected, false);
  assert.deepEqual(f.request({ ...cancel, requestId: 'wrong' }), [{ ok: true, cancelled: false }]);
  assert.deepEqual(f.request(cancel), [{ ok: true, cancelled: true }]);
  assert.equal(first.length, 1);
  assert.equal(first[0].ok, false);
  assert.ok(f.ports[0].disconnected);
  assert.equal(f.timers.size, 0);
  f.request(search({ requestId: 'next' }));
  assert.equal(f.ports.length, 2);
});

test('status is independent of search; tab close and document replacement release their ports', () => {
  const f = fixture(), first = f.request(search());
  const status = f.request({ type: TYPE, action: 'status' });
  f.ping(f.ports[1]);
  assert.equal(status[0].ok, true);
  assert.equal(f.ports[0].disconnected, false);
  f.request(search({ requestId: 'new-document' }), sender({ documentId: 'document-2' }));
  assert.equal(first[0].ok, false);
  assert.ok(f.ports[0].disconnected);
  assert.equal(f.ports[2].disconnected, false);
  f.api.tabs.onRemoved.emit(5);
  assert.ok(f.ports[2].disconnected);
  assert.equal(f.timers.size, 0);
});

test('timeouts and disconnects settle once, release resources, and permit retry', () => {
  for (const duringSearch of [false, true]) {
    const f = fixture(), replies = f.request(search());
    if (duringSearch) f.ping();
    const timer = [...f.timers.values()][0];
    assert.equal(timer.delay, duringSearch ? 240000 : 10000);
    timer.fn();
    assert.equal(replies.length, 1);
    assert.equal(replies[0].ok, false);
    assert.ok(f.ports[0].disconnected);
    f.ports[0].onDisconnect.emit();
    assert.equal(replies.length, 1);
    f.request(search());
    assert.equal(f.ports.length, 2);
  }
  const f = fixture(), replies = f.request(search());
  f.ports[0].onDisconnect.emit();
  assert.equal(replies[0].ok, false);
  assert.equal(f.timers.size, 0);
});

test('toolbar action opens only the canonical marketplace', () => {
  const f = fixture();
  f.api.action.onClicked.emit();
  assert.deepEqual(f.opened, [{ url: 'https://local-ai-extension.nelson007.com/' }]);
});

test('native failures cannot expose provider error details or local paths to the marketplace',()=>{
  for(const duringSearch of [false,true]){
    const f=fixture(),reply=f.request(search());
    if(duringSearch) f.ping();
    const port=f.ports[0];
    port.onMessage.emit({id:port.sent.at(-1).id,ok:false,error:'SECRET query and /Users/private/key.json'});
    assert.equal(reply[0].ok,false);
    assert.equal(reply[0].error,'MacHelper could not complete this discovery request. Open MacHelper and check its AI connection, then try again.');
    assert.doesNotMatch(JSON.stringify(reply),/SECRET|private|key\.json/);
    assert.equal(port.disconnected,true);
  }
});

test('discovery accepts the shared 200-byte model ID bound and rejects larger model fields',()=>{
  for(const [model,accepted] of [['m'.repeat(200),true],['m'.repeat(201),false],['模'.repeat(66),true],['模'.repeat(67),false]]){
    const f=fixture(),reply=f.request(search());f.ping();
    f.ports[0].onMessage.emit({id:'discovery-request_1',ok:true,search:{...result(),model}});
    assert.equal(reply[0].ok,accepted,`${model.length} UTF-16 units`);
    if(accepted)assert.equal(reply[0].search.model,model);
  }
});
