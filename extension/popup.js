(async () => {
  'use strict';
  const language = document.querySelector('#language');
  const tone = document.querySelector('#tone');
  const status = document.querySelector('#status');
  for (const [value, label] of Object.entries(MessageHelper.languages)) language.add(new Option(label, value));
  for (const [value, label] of Object.entries(MessageHelper.tones)) tone.add(new Option(label, value));
  const preferences = await MessageHelper.settings();
  language.value = preferences.targetLanguage;
  tone.value = preferences.tone;
  for (const select of [language, tone]) select.addEventListener('change', async () => {
    await chrome.storage.local.set({targetLanguage: language.value, tone: tone.value});
    status.textContent = 'Settings saved.';
    status.className = '';
  });
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
})().catch(error => { document.querySelector('#status').textContent = error.message; });
