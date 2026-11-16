/* The marketplace can request discovery only. Local AI credentials and general
 * MacHelper actions are deliberately outside this browser-facing protocol. */
(() => {
  "use strict";
  const MARKETPLACE = "https://local-ai-extension.nelson007.com";
  const HOST = "com.localaibasetools.mac_helper";
  const TYPE = "machelper.discovery";
  const LANGUAGES = new Set(["en", "zh-Hans", "zh-Hant", "es", "fr", "de", "ja", "ko", "pt", "ar", "hi", "ru", "it"]);
  const REQUEST_ID = /^[A-Za-z0-9_-]{1,80}$/;
  const VERSION = /^\d{1,4}\.\d{1,4}\.\d{1,4}(?:[-+][A-Za-z0-9.-]{1,40})?$/;

  function trustedSender(sender) {
    if (!sender || sender.id || !Number.isInteger(sender.tab?.id) || sender.tab.id < 0 || sender.frameId !== 0) return false;
    if (sender.origin !== undefined && sender.origin !== MARKETPLACE) return false;
    try {
      const url = new URL(sender.url);
      return url.origin === MARKETPLACE && !url.username && !url.password;
    } catch { return false; }
  }

  function validRequest(message) {
    if (!message || typeof message !== "object" || Array.isArray(message) || message.type !== TYPE) return false;
    const allowed = message.action === "search" ? ["type", "action", "requestId", "query", "language"]
      : message.action === "cancel" ? ["type", "action", "requestId"]
      : message.action === "status" ? ["type", "action"] : [];
    if (!allowed.length || Object.keys(message).some(key => !allowed.includes(key))) return false;
    if (message.action === "status") return true;
    if (typeof message.requestId !== "string" || !REQUEST_ID.test(message.requestId)) return false;
    if (message.action === "cancel") return true;
    return typeof message.query === "string" && message.query.trim().length > 0 && !message.query.includes("\0")
      && message.query.length <= 2000 && new TextEncoder().encode(message.query).length <= 8000
      && (message.language === undefined || LANGUAGES.has(message.language));
  }

  function compatible(version) {
    if (typeof version !== "string" || !VERSION.test(version)) return false;
    const [major, minor] = version.split(/[.+-]/).map(Number);
    return major > 6 || (major === 6 && minor >= 3);
  }

  function publicSearch(value) {
    const text = (item, maximum) => typeof item === "string" && item.length <= maximum;
    if (!value || !text(value.revision, 128) || !text(value.updatedAt, 64)
      || typeof value.stale !== "boolean" || !text(value.model, 200) || new TextEncoder().encode(value.model).length > 200
      || !Array.isArray(value.matches) || value.matches.length > 20) return null;
    const matches = [];
    for (const match of value.matches) {
      if (!match || !text(match.id, 160) || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(match.id)
        || !text(match.reason, 2000) || !["good", "partial"].includes(match.fit)) return null;
      matches.push({ id: match.id, reason: match.reason, fit: match.fit });
    }
    if (value.noMatchReason !== undefined && !text(value.noMatchReason, 2000)) return null;
    return { revision: value.revision, updatedAt: value.updatedAt, stale: value.stale, model: value.model, matches,
      ...(value.noMatchReason !== undefined ? { noMatchReason: value.noMatchReason } : {}) };
  }

  function createBridge(api, options = {}) {
    const schedule = options.setTimeout || setTimeout;
    const unschedule = options.clearTimeout || clearTimeout;
    const statusTimeout = options.statusTimeout ?? 10000;
    const searchTimeout = options.searchTimeout ?? 240000;
    const version = api.runtime.getManifest().version;
    const active = new Map();
    let statusCount = 0;
    let serial = 0;
    const owner = sender => `${sender.tab.id}:${sender.documentId || sender.url}`;
    const failure = error => ({ ok: false, error });

    function nativeRequest(message, sender, respond) {
      const isSearch = message.action === "search";
      const tabID = sender.tab.id;
      if (isSearch) {
        const existing = active.get(tabID);
        if (existing?.owner === owner(sender)) {
          respond(failure("A search is already running in this tab. Cancel it before starting another."));
          return;
        }
        if (existing) existing.finish(failure("The page changed; its previous search was cancelled."));
        if (active.size >= 8) { respond(failure("Too many searches are running. Please try again shortly.")); return; }
      } else if (statusCount >= 8) {
        respond(failure("Too many connection checks are running. Please try again shortly.")); return;
      }
      let port;
      try { port = api.runtime.connectNative(HOST); }
      catch { respond(failure("MacHelper is unavailable. Open MacHelper and install browser support, then try again.")); return; }
      const pingID = `discovery-status-${++serial}`;
      let phase = "ping";
      let helperVersion;
      let settled = false;
      let timer;
      const record = { owner: owner(sender), requestId: message.requestId, finish };
      if (isSearch) active.set(tabID, record); else statusCount++;
      function finish(response) {
        if (settled) return;
        settled = true;
        unschedule(timer);
        if (isSearch) { if (active.get(tabID) === record) active.delete(tabID); }
        else statusCount--;
        port.onMessage.removeListener(onMessage);
        port.onDisconnect.removeListener(onDisconnect);
        try { port.disconnect(); } catch { /* Already disconnected. */ }
        respond(response);
      }
      function onDisconnect() {
        // Consume lastError without exposing native paths or browser diagnostics.
        void api.runtime.lastError;
        finish(failure("MacHelper disconnected. Open MacHelper and check browser support, then try again."));
      }
      function onMessage(response) {
        if (!response || response.id !== (phase === "ping" ? pingID : `discovery-${message.requestId}`)) return;
        if (response.ok !== true) {
          // Provider errors can contain local paths or echoed request data.
          // The marketplace gets only a fixed diagnostic, never native details.
          finish(failure("MacHelper could not complete this discovery request. Open MacHelper and check its AI connection, then try again.")); return;
        }
        if (phase === "ping") {
          helperVersion = response.version;
          if (typeof helperVersion !== "string" || !VERSION.test(helperVersion)) {
            finish(failure("MacHelper returned an invalid version. Please update MacHelper.")); return;
          }
          if (!isSearch) {
            finish({ ok: true, version: helperVersion, connectorVersion: version, compatible: compatible(helperVersion) }); return;
          }
          if (!compatible(helperVersion)) {
            finish(failure("AI discovery requires MacHelper 6.3 or later. Please update MacHelper.")); return;
          }
          phase = "search";
          unschedule(timer);
          timer = schedule(() => finish(failure("The search timed out. Please try again.")), searchTimeout);
          try {
            port.postMessage({ id: `discovery-${message.requestId}`, action: "searchExtensions", text: message.query,
              interfaceLanguage: message.language || "en" });
          } catch { onDisconnect(); }
          return;
        }
        const search = publicSearch(response.search);
        finish(search ? { ok: true, version: helperVersion, search } : failure("MacHelper returned an invalid discovery result. Please update MacHelper."));
      }
      port.onMessage.addListener(onMessage);
      port.onDisconnect.addListener(onDisconnect);
      timer = schedule(() => finish(failure("MacHelper did not respond. Open MacHelper and try again.")), statusTimeout);
      try { port.postMessage({ id: pingID, action: "ping" }); } catch { onDisconnect(); }
    }

    function onMessage(message, sender, respond) {
      if (!trustedSender(sender) || !validRequest(message)) {
        respond(failure("This discovery request is not allowed.")); return false;
      }
      if (message.action === "cancel") {
        const existing = active.get(sender.tab.id);
        if (existing?.owner === owner(sender) && existing.requestId === message.requestId) {
          existing.finish(failure("The search was cancelled."));
          respond({ ok: true, cancelled: true });
        } else respond({ ok: true, cancelled: false });
        return false;
      }
      nativeRequest(message, sender, respond);
      return true;
    }
    api.runtime.onMessageExternal.addListener(onMessage);
    api.tabs?.onRemoved?.addListener(tabID => active.get(tabID)?.finish(failure("The tab was closed; its search was cancelled.")));
    api.action?.onClicked?.addListener(() => api.tabs.create({ url: `${MARKETPLACE}/` }));
    return { onMessage };
  }

  if (typeof module !== "undefined") module.exports = { trustedSender, validRequest, compatible, publicSearch, createBridge };
  if (typeof chrome !== "undefined" && chrome.runtime?.onMessageExternal) createBridge(chrome);
})();
