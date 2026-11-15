(async () => {
  'use strict';
  const language = document.querySelector('#language');
  const tone = document.querySelector('#tone');
  const model = document.querySelector('#model');
  const modelStatus = document.querySelector('#model-status');
  const refreshModels = document.querySelector('#refresh-models');
  const status = document.querySelector('#status');
  for (const [value, label] of Object.entries(MessageHelper.languages)) language.add(new Option(label, value));
  for (const [value, label] of Object.entries(MessageHelper.tones)) tone.add(new Option(label, value));
  const preferences = await MessageHelper.settings();
  language.value = preferences.targetLanguage;
  tone.value = preferences.tone;
  let selectedModel = preferences.model;
  async function save() {
    try {
      await chrome.storage.local.set({targetLanguage: language.value, tone: tone.value, model: selectedModel});
      status.textContent = 'Settings saved.';
      status.className = '';
    } catch (error) { status.textContent = error.message; status.className = 'mh-page-error'; }
  }
  for (const select of [language, tone]) select.addEventListener('change', save);
  model.addEventListener('change', () => {
    if (model.selectedOptions[0]?.disabled) return;
    selectedModel = model.value;
    modelStatus.textContent = selectedModel ? 'Selected model saved for translation and polishing.' : 'Using the MacHelper default model.';
    modelStatus.className = 'mh-model-status';
    save();
  });
  async function loadModels() {
    model.disabled = true;
    refreshModels.disabled = true;
    modelStatus.textContent = 'Loading available models from your Mac helper…';
    modelStatus.className = 'mh-model-status';
    try {
      const response = await MessageHelper.request('listModels');
      if (!Array.isArray(response.models)) {
        throw new Error('Your Mac helper needs an update to list models. Rebuild and reinstall MacHelper, then click Refresh models.');
      }
      const desktopModel = response.defaultModel !== undefined ? response.models.find(entry => entry.model === response.defaultModel) : response.models.find(entry => entry.isDefault);
      const desktopName = desktopModel?.displayName || response.defaultModel;
      model.replaceChildren(new Option('MacHelper default' + (desktopName ? ' — ' + desktopName : ''), ''));
      // Preserve the account's catalog order and labels. Model names are never embedded in the extension.
      for (const entry of response.models) model.add(new Option(entry.displayName, entry.model));
      const unavailable = selectedModel !== '' && !response.models.some(entry => entry.model === selectedModel);
      if (unavailable) {
        const missing = new Option('Unavailable: ' + selectedModel, selectedModel);
        missing.disabled = true;
        model.add(missing);
      }
      model.value = selectedModel;
      model.disabled = false;
      modelStatus.textContent = unavailable ? 'Your selected model is unavailable. Choose another model or MacHelper default.' : response.models.length ? 'Choose the model used for translation and polishing.' : 'No models are available. Load or download a model in your AI service, then refresh.';
      modelStatus.className = 'mh-model-status' + (unavailable ? ' mh-page-error' : '');
    } catch (error) {
      // Keep both the stored preference and the displayed selection on refresh failures.
      if (![...model.options].some(option => option.value === selectedModel)) {
        const saved = new Option(selectedModel ? 'Selected model: ' + selectedModel : 'MacHelper default', selectedModel);
        saved.disabled = true;
        model.add(saved);
      }
      model.value = selectedModel;
      modelStatus.textContent = 'Could not load models. ' + error.message;
      modelStatus.className = 'mh-model-status mh-page-error';
    } finally { refreshModels.disabled = false; }
  }
  refreshModels.addEventListener('click', loadModels);
  document.querySelector('#connection').addEventListener('click', async event => {
    event.target.disabled = true;
    status.textContent = 'Connecting to your Mac helper…';
    status.className = '';
    try {
      const response = await MessageHelper.request('ping');
      status.textContent = `Connected${response.version ? ' · helper ' + response.version : ''}${response.model ? ' · ' + response.model : ''}.`;
    } catch (error) { status.textContent = error.message; status.className = 'mh-page-error'; }
    finally { event.target.disabled = false; }
  });
  document.querySelector('#sandbox').addEventListener('click', () => {
    chrome.tabs.create({url: chrome.runtime.getURL('sandbox.html')});
  });
  await loadModels();
})().catch(error => { document.querySelector('#status').textContent = error.message; });
