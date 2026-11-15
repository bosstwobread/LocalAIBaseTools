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
      (url.pathname.startsWith('/ab/messages/') || url.pathname.startsWith('/nx/proposals/') ||
        /^\/ab\/feedbacks\/f\/contract\/[^/]+\/?$/.test(url.pathname));
  } catch { return false; }
}

function validate(message) {
  if (!message || message.type !== 'MESSAGEHELPER_REQUEST') throw new Error('Unsupported request.');
  if (!['ping', 'listModels', 'translate', 'polish'].includes(message.action)) throw new Error('Unsupported action.');
  if (!LANGUAGES.has(message.targetLanguage) || !TONES.has(message.tone)) throw new Error('Unsupported language or tone.');
  const model = message.model === undefined ? '' : message.model;
  if (typeof model !== 'string' || (model !== '' && !model.trim()) || new TextEncoder().encode(model).length > 200 || /[\p{Cc}\p{Cf}]/u.test(model)) {
    throw new Error('Choose a valid model in MessageHelper settings.');
  }
  if (message.action === 'translate' || message.action === 'polish') {
    if (typeof message.text !== 'string' || !message.text.trim()) throw new Error('Please enter a message first.');
    if ([...message.text].length > 24000 || new TextEncoder().encode(message.text).length > 96000) {
      throw new Error('The message exceeds the supported length.');
    }
  }
  return {id: crypto.randomUUID(), action: message.action, text: message.action === 'translate' || message.action === 'polish' ? message.text : '',
    targetLanguage: message.targetLanguage, tone: message.tone, model};
}

function boundedString(value, bytes) {
  return typeof value === 'string' && value.trim().length > 0 && new TextEncoder().encode(value).length <= bytes &&
    !/[\p{Cc}\p{Cf}]/u.test(value);
}
function modelCatalog(response) {
  if (!Array.isArray(response.models)) {
    throw new Error('Your Mac helper needs an update to list models. Rebuild and reinstall the MessageHelper helper, then click Refresh models.');
  }
  if (response.models.length < 1 || response.models.length > 256) throw new Error('The Mac helper returned an invalid model catalog.');
  const seen = new Set();
  const models = response.models.map(entry => {
    if (!entry || typeof entry !== 'object' || !boundedString(entry.model, 200) || !boundedString(entry.displayName, 512) ||
        typeof entry.isDefault !== 'boolean' || !Array.isArray(entry.supportedReasoningEfforts) || entry.supportedReasoningEfforts.length > 16 ||
        !entry.supportedReasoningEfforts.every(effort => boundedString(effort, 64)) ||
        (entry.defaultReasoningEffort !== undefined && !boundedString(entry.defaultReasoningEffort, 64)) || seen.has(entry.model)) {
      throw new Error('The Mac helper returned an invalid model catalog.');
    }
    seen.add(entry.model);
    return {model: entry.model, displayName: entry.displayName, isDefault: entry.isDefault,
      supportedReasoningEfforts: [...entry.supportedReasoningEfforts],
      ...(entry.defaultReasoningEffort !== undefined ? {defaultReasoningEffort: entry.defaultReasoningEffort} : {})};
  });
  if (response.defaultModel !== undefined && !boundedString(response.defaultModel, 200)) {
    throw new Error('The Mac helper returned an invalid default model.');
  }
  const catalog = {models, ...(response.defaultModel !== undefined ? {defaultModel: response.defaultModel} : {})};
  if (new TextEncoder().encode(JSON.stringify(catalog)).length > 192 * 1024) {
    throw new Error('The Mac helper returned an oversized model catalog.');
  }
  return catalog;
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
    if (typeof response.ok !== 'boolean' || (response.ok && ['translate', 'polish'].includes(entry.action) && typeof response.text !== 'string')) {
      entry.resolve({ok: false, error: 'The Mac helper returned an invalid response.'});
      return;
    }
    let catalog = {};
    if (response.ok && entry.action === 'listModels') {
      try { catalog = modelCatalog(response); }
      catch (error) { entry.resolve({ok: false, error: error.message}); return; }
    }
    entry.resolve({id: response.id, ok: response.ok, text: typeof response.text === 'string' ? response.text : '', ...catalog,
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
    return Promise.resolve({ok: false, error: 'Please wait for your current request to finish, then try again.'});
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
