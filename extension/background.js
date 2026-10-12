'use strict';
const HOST = 'com.messagehelper.gpt';
const LANGUAGES = new Set(['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'pt', 'it']);
const TONES = new Set(['professional', 'friendly', 'concise']);
const pending = new Map();
let nativePort = null;

function authorized(sender) {
  if (sender.id !== chrome.runtime.id || typeof sender.url !== 'string') return false;
  try {
    const url = new URL(sender.url);
    if (url.protocol === 'chrome-extension:' && url.hostname === chrome.runtime.id) return true;
    return url.protocol === 'https:' && url.hostname === 'www.upwork.com' &&
      (url.pathname.startsWith('/ab/messages/') || url.pathname.startsWith('/nx/proposals/'));
  } catch { return false; }
}

function validate(message) {
  if (!message || message.type !== 'MESSAGEHELPER_REQUEST') throw new Error('Unsupported request.');
  if (!['ping', 'translate', 'polish'].includes(message.action)) throw new Error('Unsupported action.');
  if (!LANGUAGES.has(message.targetLanguage) || !TONES.has(message.tone)) throw new Error('Unsupported language or tone.');
  if (message.action !== 'ping') {
    if (typeof message.text !== 'string' || !message.text.trim()) throw new Error('Please enter a message first.');
    if ([...message.text].length > 24000 || new TextEncoder().encode(message.text).length > 96000) {
      throw new Error('The message exceeds the supported length.');
    }
  }
  return {id: crypto.randomUUID(), action: message.action, text: message.action === 'ping' ? '' : message.text,
    targetLanguage: message.targetLanguage, tone: message.tone};
}

function connection() {
  if (nativePort) return nativePort;
  const port = chrome.runtime.connectNative(HOST);
  nativePort = port;
  port.onMessage.addListener(response => {
    if (!response || typeof response.id !== 'string') return;
    const entry = pending.get(response.id);
    if (!entry) return;
    pending.delete(response.id);
    clearTimeout(entry.timer);
    if (typeof response.ok !== 'boolean' || (response.ok && entry.action !== 'ping' && typeof response.text !== 'string')) {
      entry.resolve({ok: false, error: 'The Mac helper returned an invalid response.'});
      return;
    }
    entry.resolve({id: response.id, ok: response.ok, text: typeof response.text === 'string' ? response.text : '',
      error: typeof response.error === 'string' ? response.error : undefined,
      model: typeof response.model === 'string' ? response.model : undefined,
      version: typeof response.version === 'string' ? response.version : undefined});
  });
  port.onDisconnect.addListener(() => {
    const message = chrome.runtime.lastError?.message || 'The Mac helper disconnected.';
    if (nativePort !== port) return;
    nativePort = null;
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.resolve({ok: false, error: message});
    }
    pending.clear();
  });
  return port;
}

function invoke(request) {
  if (pending.size >= 3 || (request.action !== 'ping' && [...pending.values()].some(entry => entry.action !== 'ping'))) {
    return Promise.resolve({ok: false, error: 'Please wait for your current AI request to finish.'});
  }
  return new Promise(resolve => {
    const timer = setTimeout(() => {
      pending.delete(request.id);
      resolve({ok: false, error: 'The AI request timed out. You can try again when the helper is ready.'});
    }, 180000);
    pending.set(request.id, {resolve, timer, action: request.action});
    try { connection().postMessage(request); }
    catch (error) {
      clearTimeout(timer);
      pending.delete(request.id);
      resolve({ok: false, error: error.message});
    }
  });
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type !== 'MESSAGEHELPER_REQUEST') return false;
  try {
    if (!authorized(sender)) throw new Error('This page is not authorized to use MessageHelper.');
    const request = validate(message);
    invoke(request).then(respond, error => respond({ok: false, error: error.message}));
    return true;
  } catch (error) { respond({ok: false, error: error.message}); return false; }
});
