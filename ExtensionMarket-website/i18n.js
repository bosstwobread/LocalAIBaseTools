(() => {
  'use strict';
  const languages = [
    ['en', 'English'], ['zh-Hans', '简体中文'], ['zh-Hant', '繁體中文'],
    ['es', 'Español'], ['fr', 'Français'], ['de', 'Deutsch'], ['ja', '日本語'],
    ['ko', '한국어'], ['pt', 'Português'], ['ar', 'العربية'], ['hi', 'हिन्दी'],
    ['ru', 'Русский'], ['it', 'Italiano']
  ];
  const storageKey = 'localaibasetools.website.language';
  const catalogs = window.MARKET_TRANSLATIONS || {};
  const previewCatalogs = window.MARKET_PREVIEW_TRANSLATIONS || {};
  const canonical = value => {
    if (typeof value !== 'string') return null;
    const tag = value.replace(/_/g, '-').toLowerCase();
    if (/^zh(?:-|$)/.test(tag)) {
      if (/(?:^|-)hans(?:-|$)/.test(tag)) return 'zh-Hans';
      if (/(?:^|-)hant(?:-|$)/.test(tag)) return 'zh-Hant';
      return /(?:^|-)(?:tw|hk|mo)(?:-|$)/.test(tag) ? 'zh-Hant' : 'zh-Hans';
    }
    return languages.find(([code]) => code.toLowerCase() === tag || code === tag.split('-')[0])?.[0] || null;
  };
  let stored;
  try { stored = localStorage.getItem(storageKey); } catch { /* Private browsing may disable storage. */ }
  let locale = canonical(stored) || (navigator.languages || [navigator.language]).map(canonical).find(Boolean) || 'en';
  const previewText = key => previewCatalogs[locale]?.[key] || previewCatalogs.en?.[key] || '';
  const previewNames = new Map([['translation-preview.svg', 'translation'], ['polish-input-preview.svg', 'polish']]);
  function previewName(value) {
    try {
      const path = typeof value === 'string' && value.startsWith('/') && !value.startsWith('//') ? value.slice(1) : value;
      const target = new URL(path, document.baseURI), base = new URL('./', document.baseURI);
      if (target.origin !== base.origin || target.search || target.hash) return null;
      const relative = target.pathname.slice(base.pathname.length);
      if (!target.pathname.startsWith(base.pathname) || !/^assets\/(?:localized\/(?:en|zh-Hans|zh-Hant|es|fr|de|ja|ko|pt|ar|hi|ru|it)\/)?[^/]+$/.test(relative)) return null;
      const name = relative.split('/').pop();
      return previewNames.has(name) ? name : null;
    } catch { return null; }
  }
  function previewSource(value) {
    const name = previewName(value);
    return name ? new URL(`assets/localized/${locale}/${name}`, document.baseURI).href : value;
  }
  function previewAlt(value, fallback) {
    const name = previewName(value);
    return name ? previewText(`${previewNames.get(name)}.description`) || fallback : fallback;
  }
  const t = (message, values = {}) => {
    if (typeof message !== 'string') return '';
    const key = message.replace(/\s+/g, ' ').trim();
    const translated = catalogs[locale]?.[key];
    return (typeof translated === 'string' && translated ? translated : message)
      .replace(/\{(\w+)\}/g, (match, key) => Object.hasOwn(values, key) ? String(values[key]) : match);
  };
  // Capture only authored static nodes. Catalog data and dialog DOM are rendered
  // explicitly by app.js, so product names and untrusted text never become keys
  // on later language switches and never enter an HTML parsing sink.
  const textNodes = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) {
    if (!node.textContent.trim() || node.parentElement.closest('script,style,code,noscript,[aria-hidden="true"],[data-preview-key]')) continue;
    textNodes.push([node, node.textContent]);
  }
  const attributes = [];
  document.querySelectorAll('[aria-label],[placeholder],[title],[alt],meta[name="description"]').forEach(element => {
    for (const name of ['aria-label', 'placeholder', 'title', 'alt', 'content']) {
      if (name === 'alt' && previewName(element.getAttribute('src'))) continue;
      if (element.hasAttribute(name)) attributes.push([element, name, element.getAttribute(name)]);
    }
  });
  const originalTitle = document.title;
  const select = document.querySelector('#site-language');
  for (const [code, name] of languages) {
    const option = document.createElement('option'); option.value = code; option.textContent = name; option.lang = code;
    select.append(option);
  }
  function apply() {
    document.documentElement.lang = locale;
    document.documentElement.dir = locale === 'ar' ? 'rtl' : 'ltr';
    document.title = t(originalTitle);
    for (const [node, original] of textNodes) {
      if (!node.isConnected) continue;
      const prefix = original.match(/^\s*/)[0], suffix = original.match(/\s*$/)[0];
      node.textContent = prefix + t(original.trim()) + suffix;
    }
    for (const [element, attribute, original] of attributes) if (element.isConnected) element.setAttribute(attribute, t(original));
    // Illustration copy is authored synthetic content. It is deliberately
    // separate from live user text and remains localized even when decorative.
    document.querySelectorAll('[data-preview-key]').forEach(element => {
      const text = previewText(element.dataset.previewKey);
      if (text) element.textContent = text;
      element.lang = locale;
    });
    document.querySelectorAll('img').forEach(element => {
      const source = element.dataset.previewSource || element.getAttribute('src');
      if (!previewName(source)) return;
      element.dataset.previewSource = source;
      element.src = previewSource(source);
      element.alt = previewAlt(source, element.alt);
    });
    select.value = locale;
  }
  function setLocale(value) {
    const next = canonical(value);
    if (!next) return false;
    locale = next;
    try { localStorage.setItem(storageKey, locale); } catch { /* Choice still applies for this page. */ }
    apply();
    window.dispatchEvent(new CustomEvent('market-language-change', { detail: { locale } }));
    return true;
  }
  select.addEventListener('change', () => setLocale(select.value));
  window.MarketI18n = Object.freeze({ t, setLocale, previewText, previewSource, previewAlt, get locale() { return locale; } });
  apply();
})();
