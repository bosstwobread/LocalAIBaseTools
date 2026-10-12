(() => {
  'use strict';
  const status = document.querySelector('#status');
  document.querySelector('#connection').addEventListener('click', async event => {
    event.target.disabled = true;
    status.textContent = 'Connecting…';
    status.className = '';
    try {
      const response = await MessageHelper.request('ping');
      status.textContent = `Connected · ${response.model || 'local GPT helper'}${response.version ? ' · ' + response.version : ''}`;
    } catch (error) { status.textContent = error.message; status.className = 'mh-page-error'; }
    finally { event.target.disabled = false; }
  });
  document.querySelector('#settings').addEventListener('click', () => chrome.tabs.create({url: chrome.runtime.getURL('popup.html')}));
  document.querySelector('#reset').addEventListener('click', () => {
    const editor = document.querySelector('[data-mh-editor]');
    editor.replaceChildren();
    const paragraph = document.createElement('p');
    paragraph.textContent = 'Hi, thanks for your feedback. I has updated the document and I will sending the new version tomorrow.';
    editor.append(paragraph);
    editor.dispatchEvent(new Event('input', {bubbles: true}));
    document.querySelector('.mh-preview')?.replaceChildren();
    status.textContent = 'Sample draft reset.';
  });
})();
