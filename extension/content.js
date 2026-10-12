(() => {
  'use strict';
  if (globalThis.MessageHelperContent) return;
  const MESSAGE_SELECTOR = '[data-test="story-message"], [data-mh-message], [data-test="message-text"]';
  const EDITOR_SELECTOR = '.up-d-composer .tiptap.ProseMirror[contenteditable="true"][role="textbox"], [data-mh-editor], .up-d-composer .ql-editor[contenteditable="true"]';
  const SEND_SELECTOR = 'button[data-test="send-message-button"], button[data-mh-send], button[aria-label="Send message"]';
  const messages = new WeakMap();
  const messageStates = new Set();
  const composers = new WeakMap();
  const composerStates = new Set();
  let scanTimer = null;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    node.className = className;
    node.dataset.messagehelper = 'true';
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function button(className, text, action) {
    const node = element('button', className, text);
    node.type = 'button';
    node.addEventListener('click', event => {
      event.preventDefault();
      event.stopPropagation();
      action(event);
    });
    return node;
  }
  function conversationKey() {
    let key = location.href;
    try { key += '|' + window.top.location.href; } catch { /* cross-origin frame */ }
    return key;
  }
  function visible(node) {
    if (!node.isConnected || node.closest('[hidden], [aria-hidden="true"]')) return false;
    const style = getComputedStyle(node);
    return style.display !== 'none' && style.visibility !== 'hidden';
  }
  function sourceText(node) {
    const clone = node.cloneNode(true);
    clone.querySelectorAll('[data-messagehelper], .end-of-message, script, style').forEach(child => child.remove());
    // Only the narrow message body is read; surrounding names, controls and our translation never become input.
    const lines = [];
    function walk(current) {
      if (current.nodeType === Node.TEXT_NODE) { lines.push(current.nodeValue); return; }
      if (current.nodeType !== Node.ELEMENT_NODE) return;
      if (current.tagName === 'BR') { lines.push('\n'); return; }
      const block = /^(P|DIV|LI|PRE|BLOCKQUOTE|UL|OL)$/.test(current.tagName);
      if (block && lines.length && !lines.at(-1).endsWith('\n')) lines.push('\n');
      current.childNodes.forEach(walk);
      if (block && lines.length && !lines.at(-1).endsWith('\n')) lines.push('\n');
    }
    clone.childNodes.forEach(walk);
    return lines.join('').replace(/\u00a0/g, ' ').trim();
  }
  function readDraft(editor) {
    if (editor instanceof HTMLTextAreaElement || editor instanceof HTMLInputElement) return editor.value;
    return typeof editor.innerText === 'string' ? editor.innerText.replace(/\u00a0/g, ' ') : editor.textContent;
  }
  function snapshot(state) {
    return {text: readDraft(state.editor), html: state.editor.innerHTML,
      revision: state.revision, key: conversationKey(), editor: state.editor};
  }
  function unchanged(state, captured) {
    return state.editor === captured.editor && state.editor.isConnected && visible(state.editor) &&
      captured.key === conversationKey() && state.revision === captured.revision &&
      readDraft(state.editor) === captured.text && state.editor.innerHTML === captured.html;
  }
  function showStatus(host, text, error = false) {
    const status = element('div', 'mh-status' + (error ? ' mh-error' : ''), text);
    status.setAttribute('role', error ? 'alert' : 'status');
    host.replaceChildren(status);
  }

  function addMessage(node) {
    if (node.closest('[data-messagehelper]') || !visible(node)) return;
    const text = sourceText(node);
    if (!text) return;
    let state = messages.get(node);
    if (state) {
      messageStates.add(state);
      if (state.source !== text || state.key !== conversationKey()) {
        state.generation++;
        state.source = text;
        state.key = conversationKey();
        state.cached = null;
        state.panel.replaceChildren();
        state.trigger.textContent = 'Translate';
        state.trigger.disabled = false;
      }
      if (!state.tools.isConnected) node.insertAdjacentElement('afterend', state.tools);
      return;
    }
    const tools = element('div', 'mh-message-tools');
    const panel = element('div', 'mh-translation');
    panel.setAttribute('aria-live', 'polite');
    state = {node, tools, panel, source: text, generation: 0, cached: null, key: conversationKey()};
    const trigger = button('mh-button mh-translate', 'Translate', async () => {
      const capturedText = sourceText(node);
      const capturedKey = conversationKey();
      const generation = ++state.generation;
      trigger.disabled = true;
      try {
        const preferences = await MessageHelper.settings();
        if (state.cached?.source === capturedText && state.cached?.language === preferences.targetLanguage) {
          const hidden = !panel.hidden;
          panel.hidden = hidden;
          trigger.textContent = hidden ? 'Translate' : 'Hide translation';
          return;
        }
        panel.hidden = false;
        showStatus(panel, 'Translating…');
        const response = await MessageHelper.request('translate', capturedText, preferences);
        if (!node.isConnected || sourceText(node) !== capturedText || capturedKey !== conversationKey() || generation !== state.generation) return;
        const title = element('div', 'mh-result-label', MessageHelper.languages[preferences.targetLanguage]);
        const result = element('div', 'mh-result', response.text);
        panel.replaceChildren(title, result);
        state.cached = {source: capturedText, language: preferences.targetLanguage};
        trigger.textContent = 'Hide translation';
      } catch (error) {
        if (generation !== state.generation || !node.isConnected) return;
        panel.hidden = false;
        showStatus(panel, error.message, true);
        trigger.textContent = 'Translate';
      } finally { if (generation === state.generation) trigger.disabled = false; }
    });
    state.trigger = trigger;
    tools.append(trigger, panel);
    node.insertAdjacentElement('afterend', tools);
    messages.set(node, state);
    messageStates.add(state);
  }

  function richFormatting(editor) {
    return Boolean(editor.querySelector('strong, b, em, i, u, s, a, ul, ol, blockquote, code, img'));
  }
  function normalized(text) { return text.replace(/\r\n/g, '\n').replace(/\n+$/g, ''); }
  function writeDraft(editor, text) {
    editor.focus({preventScroll: true});
    if (editor instanceof HTMLTextAreaElement || editor instanceof HTMLInputElement) {
      const prototype = editor instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, 'value').set.call(editor, text);
      editor.dispatchEvent(new Event('input', {bubbles: true}));
      return;
    }
    const range = document.createRange();
    range.selectNodeContents(editor);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    // A real editing command allows ProseMirror/Quill to process the edit and update their own state.
    // There are intentionally no keyboard, submit, Send-button or synthetic Enter events anywhere.
    const accepted = document.execCommand('insertText', false, text);
    if (!accepted || normalized(readDraft(editor)) !== normalized(text)) {
      throw new Error('The editor could not apply the result. Copy the preview into your draft manually.');
    }
  }
  function previewPolish(state, source, output) {
    const title = element('div', 'mh-result-label', 'Polished draft');
    const result = element('div', 'mh-result mh-polished-text', output);
    const actions = element('div', 'mh-actions');
    const status = element('div', 'mh-status', 'Review this preview, then apply it to your draft.');
    status.setAttribute('role', 'status');
    const original = element('details', 'mh-original');
    original.append(element('summary', 'mh-original-label', 'Original draft'), element('div', 'mh-result', source.text));
    const apply = button('mh-button mh-primary mh-apply', 'Apply', () => {
      if (!unchanged(state, source)) {
        status.textContent = 'Your draft or conversation changed. Click Polish again for the current draft.';
        status.classList.add('mh-error');
        apply.disabled = true;
        return;
      }
      try {
        writeDraft(state.editor, output);
        const applied = snapshot(state);
        const undo = button('mh-button mh-undo', 'Undo', () => {
          if (!unchanged(state, applied)) {
            status.textContent = 'Your draft changed after applying. Undo cannot replace your newer text.';
            status.classList.add('mh-error');
            undo.disabled = true;
            return;
          }
          try {
            if (richFormattingFromHTML(source.html) && state.editor.isContentEditable) {
              // Native undo restores original rich text. It is only allowed while our exact edit is still current.
              state.editor.focus({preventScroll: true});
              if (!document.execCommand('undo') || readDraft(state.editor) !== source.text) {
                throw new Error('Use the editor’s Undo command to restore your original formatting.');
              }
            } else { writeDraft(state.editor, source.text); }
            state.preview.replaceChildren();
          } catch (error) { status.textContent = error.message; status.classList.add('mh-error'); }
        });
        actions.replaceChildren(undo, button('mh-button mh-dismiss', 'Dismiss', () => state.preview.replaceChildren()));
        status.textContent = 'Applied to your draft. Review it in the editor before sending.';
        status.classList.remove('mh-error');
      } catch (error) {
        status.textContent = error.message;
        status.classList.add('mh-error');
        original.open = true;
        if (readDraft(state.editor) !== source.text || state.editor.innerHTML !== source.html) {
          const partial = snapshot(state);
          const recover = button('mh-button mh-undo', 'Undo attempted edit', () => {
            if (!unchanged(state, partial)) {
              status.textContent = 'Your draft changed. Copy the original draft below if you need it.';
              recover.disabled = true;
              return;
            }
            state.editor.focus({preventScroll: true});
            if (!document.execCommand('undo') || readDraft(state.editor) !== source.text) {
              status.textContent = 'Copy the original draft below to restore it manually.';
              return;
            }
            state.preview.replaceChildren();
          });
          actions.replaceChildren(recover, cancel);
        }
      }
    });
    const cancel = button('mh-button mh-cancel', 'Cancel', () => state.preview.replaceChildren());
    actions.append(apply, cancel);
    const nodes = [title, result];
    if (richFormatting(state.editor)) nodes.push(element('div', 'mh-format-note', 'Applying replaces this draft with plain text. Undo can restore the original formatting.'));
    nodes.push(actions, status, original);
    state.preview.replaceChildren(...nodes);
  }
  function richFormattingFromHTML(html) { return /<(strong|b|em|i|u|s|a|ul|ol|blockquote|code|img)(\s|>)/i.test(html); }

  function addComposer(editor) {
    if (!visible(editor)) return;
    const composer = editor.closest('.up-d-composer, [data-mh-composer]');
    if (!composer) return;
    const send = composer.querySelector(SEND_SELECTOR);
    if (!send) return;
    let state = composers.get(editor);
    if (state) {
      composerStates.add(state);
      if (!state.trigger.isConnected || state.trigger.nextElementSibling !== send) send.before(state.trigger);
      if (!state.preview.isConnected) composer.append(state.preview);
      if (state.key !== conversationKey()) {
        state.key = conversationKey();
        state.generation++;
        state.preview.replaceChildren();
        state.trigger.disabled = false;
        state.trigger.textContent = 'Polish';
      }
      return;
    }
    const preview = element('div', 'mh-preview');
    preview.setAttribute('aria-live', 'polite');
    state = {editor, composer, preview, revision: 0, generation: 0, key: conversationKey()};
    editor.addEventListener('input', () => { state.revision++; });
    const trigger = button('mh-button mh-polish', 'Polish', async () => {
      // Capture before awaiting settings or AI, so a later edit cannot be silently overwritten.
      const captured = snapshot(state);
      const generation = ++state.generation;
      trigger.disabled = true;
      trigger.textContent = 'Polishing…';
      try {
        MessageHelper.validateText(captured.text);
        showStatus(preview, 'Polishing your draft…');
        const response = await MessageHelper.request('polish', captured.text);
        if (!editor.isConnected || generation !== state.generation || captured.key !== conversationKey()) return;
        previewPolish(state, captured, response.text);
      } catch (error) {
        if (editor.isConnected && generation === state.generation) showStatus(preview, error.message, true);
      } finally {
        if (generation === state.generation) { trigger.disabled = false; trigger.textContent = 'Polish'; }
      }
    });
    state.trigger = trigger;
    send.before(trigger);
    composer.append(preview);
    composers.set(editor, state);
    composerStates.add(state);
  }

  function scan() {
    for (const state of messageStates) {
      if (!state.node.isConnected) { state.tools.remove(); state.generation++; messageStates.delete(state); }
    }
    for (const state of composerStates) {
      if (!state.editor.isConnected) { state.preview.remove(); state.trigger.remove(); state.generation++; composerStates.delete(state); }
    }
    document.querySelectorAll(MESSAGE_SELECTOR).forEach(node => {
      // The primary adapter has priority when old fallback markup appears nested inside it.
      if (node.parentElement?.closest(MESSAGE_SELECTOR)) return;
      addMessage(node);
    });
    document.querySelectorAll(EDITOR_SELECTOR).forEach(addComposer);
  }
  function schedule() {
    if (scanTimer !== null) return;
    scanTimer = setTimeout(() => { scanTimer = null; scan(); }, 180);
  }
  const observer = new MutationObserver(records => {
    if (records.some(record => {
      const target = record.target.nodeType === Node.ELEMENT_NODE ? record.target : record.target.parentElement;
      return !target?.closest('[data-messagehelper]');
    })) schedule();
  });
  observer.observe(document.documentElement, {childList: true, subtree: true, characterData: true,
    attributes: true, attributeFilter: ['contenteditable', 'data-room-id', 'hidden', 'aria-hidden', 'class']});
  window.addEventListener('popstate', schedule);
  window.addEventListener('hashchange', schedule);
  globalThis.MessageHelperContent = Object.freeze({scan, readDraft, conversationKey});
  scan();
})();
