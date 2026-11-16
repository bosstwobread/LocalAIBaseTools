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
    if (!node.textContent.trim() || node.parentElement.closest('script,style,code,noscript,[aria-hidden="true"]')) continue;
    textNodes.push([node, node.textContent]);
  }
  const attributes = [];
  document.querySelectorAll('[aria-label],[placeholder],[title],[alt],meta[name="description"]').forEach(element => {
    for (const name of ['aria-label', 'placeholder', 'title', 'alt', 'content']) {
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
  window.MarketI18n = Object.freeze({ t, setLocale, get locale() { return locale; } });
  apply();
})();
