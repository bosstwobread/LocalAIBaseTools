/* Shared by the isolated Upwork content script and the extension's private test page. */
(() => {
  'use strict';
  const languages = Object.freeze({
    'zh-CN': 'Simplified Chinese', 'zh-TW': 'Traditional Chinese', en: 'English',
    ja: 'Japanese', ko: 'Korean', fr: 'French', de: 'German', es: 'Spanish',
    pt: 'Portuguese', it: 'Italian'
  });
  const tones = Object.freeze({professional: 'Professional', friendly: 'Friendly', concise: 'Concise'});
  const defaults = Object.freeze({targetLanguage: 'zh-CN', tone: 'professional', model: ''});
  function validateModel(model) {
    if (typeof model !== 'string' || (model !== '' && !model.trim()) || new TextEncoder().encode(model).length > 200 || /[\p{Cc}\p{Cf}]/u.test(model)) {
      throw new Error('The saved model is invalid. Choose a model in MessageHelper settings.');
    }
    return model;
  }
  function validateText(text) {
    if (typeof text !== 'string' || !text.trim()) throw new Error('Please enter a message first.');
    if ([...text].length > 24000 || new TextEncoder().encode(text).length > 96000) {
      throw new Error('This message is too long. Please use fewer than 24,000 characters.');
    }
    return text;
  }
  async function settings() {
    const stored = await chrome.storage.local.get(defaults);
    return {
      targetLanguage: Object.hasOwn(languages, stored.targetLanguage) ? stored.targetLanguage : defaults.targetLanguage,
      tone: Object.hasOwn(tones, stored.tone) ? stored.tone : defaults.tone,
      model: validateModel(stored.model)
    };
  }
  async function request(action, text = '', capturedPreferences = null) {
    if (action === 'translate' || action === 'polish') validateText(text);
    const preferences = capturedPreferences || await settings();
    const response = await chrome.runtime.sendMessage({type: 'MESSAGEHELPER_REQUEST', action, text, ...preferences});
    if (!response?.ok) {
      const detail = response?.error || 'The Mac helper did not respond. Check MessageHelper settings.';
      if (action === 'listModels' && /unsupported|valid ID and supported action|invalid.*action/i.test(detail)) {
        throw new Error('Your Mac helper needs an update to list models. Rebuild and reinstall the MessageHelper helper, then click Refresh models.');
      }
      throw new Error(detail);
    }
    if ((action === 'translate' || action === 'polish') && (typeof response.text !== 'string' || !response.text.trim())) {
      throw new Error('The helper returned an empty result. Your draft has not been changed.');
    }
    return response;
  }
  globalThis.MessageHelper = Object.freeze({languages, tones, settings, request, validateText});
})();
