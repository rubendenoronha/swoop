// SPDX-License-Identifier: MIT
//
// Swoop Shield browser extension: background (Chrome service worker; Firefox/Safari event
// page). Network blocking is declarative (rules/*.json, compiled by Swoop from the same
// filter lists as the system-wide layer). This script serves cosmetic selectors to the
// content script, injects scriptlets into pages, and handles per-site pause.
// No data leaves the browser.
/* global swoopRunScriptlets, importScripts */
const api = globalThis.browser ?? globalThis.chrome;
if (typeof swoopRunScriptlets === 'undefined' && typeof importScripts === 'function') importScripts('scriptlets.js');

let cosmetic = null;
let cosmeticLoading = null;

function loadCosmetic() {
  if (cosmetic) return Promise.resolve(cosmetic);
  if (!cosmeticLoading) {
    cosmeticLoading = fetch(api.runtime.getURL('cosmetic.json'))
      .then((r) => r.json())
      .catch(() => ({}))
      .then((c) => { cosmetic = c; return c; });
  }
  return cosmeticLoading;
}

async function getState() {
  const s = await api.storage.local.get({ pausedSites: [], enabled: true });
  return { pausedSites: s.pausedSites || [], enabled: s.enabled !== false };
}

const hostMatches = (host, domain) => host === domain || host.endsWith('.' + domain);

// Keys that apply to a host: every parent domain, plus "label.*" entity keys.
function keysFor(host) {
  const labels = host.split('.');
  const keys = [];
  for (let i = 0; i < labels.length - 1; i++) {
    keys.push(labels.slice(i).join('.'));
    keys.push(labels[i] + '.*');
  }
  return keys;
}

function collect(map, host) {
  if (!map) return [];
  const out = [];
  for (const k of keysFor(host)) if (map[k]) out.push(...map[k]);
  return out;
}

function isPaused(state, host) {
  return !state.enabled || state.pausedSites.some((d) => hostMatches(host, d));
}

async function pageConfig(host) {
  const [c, state] = await Promise.all([loadCosmetic(), getState()]);
  if (isPaused(state, host)) return { paused: true };
  const elemHide = (c.elemHide || []).some((d) => hostMatches(host, d));
  if (elemHide) return { paused: false, css: [], procedural: [], styles: [], genericHide: true };
  const exceptions = new Set(collect(c.exceptions, host));
  const genericHide = (c.genericHide || []).some((d) => hostMatches(host, d));
  const css = collect(c.specific, host).filter((s) => !exceptions.has(s));
  if (!genericHide) css.push(...(c.genericComplex || []).filter((s) => !exceptions.has(s)));
  return {
    paused: false,
    css,
    procedural: collect(c.procedural, host).concat(genericHide ? [] : (c.procedural && c.procedural['*']) || []).filter((s) => !exceptions.has(s)),
    styles: collect(c.styles, host).concat((c.styles && c.styles['*']) || []),
    genericHide,
  };
}

async function genericSelectors(host, classes, ids) {
  const c = await loadCosmetic();
  const exceptions = new Set(collect(c.exceptions, host));
  const out = [];
  for (const cls of classes) { const s = c.genericClasses && c.genericClasses[cls]; if (s) out.push(...s); }
  for (const id of ids) { const s = c.genericIds && c.genericIds[id]; if (s) out.push(...s); }
  return out.filter((s) => !exceptions.has(s));
}

async function scriptletsFor(host) {
  const c = await loadCosmetic();
  const off = new Set(collect(c.scriptletExceptions, host));
  if (off.has('')) return [];   // "#@#+js()" switches all scriptlets off
  return collect(c.scriptlets, host).filter((s) => !off.has(s[0]));
}

// Per-site pause = a high-priority allowAllRequests rule for that site.
function ruleIdFor(domain) {
  let h = 0;
  for (let i = 0; i < domain.length; i++) h = (h * 31 + domain.charCodeAt(i)) | 0;
  return 1000000 + (Math.abs(h) % 900000);
}

async function syncDynamicRules() {
  if (!api.declarativeNetRequest) return;   // Safari page cleaner: no network rules here
  const state = await getState();
  const existing = await api.declarativeNetRequest.getDynamicRules();
  const add = state.pausedSites.map((d) => ({
    id: ruleIdFor(d),
    priority: 1000,
    action: { type: 'allowAllRequests' },
    condition: { requestDomains: [d], resourceTypes: ['main_frame', 'sub_frame'] },
  }));
  await api.declarativeNetRequest.updateDynamicRules({ removeRuleIds: existing.map((r) => r.id), addRules: add });
  const manifest = api.runtime.getManifest();
  const ids = ((manifest.declarative_net_request || {}).rule_resources || []).map((r) => r.id);
  if (ids.length) {
    await api.declarativeNetRequest.updateEnabledRulesets(state.enabled ? { enableRulesetIds: ids } : { disableRulesetIds: ids });
  }
}

api.runtime.onInstalled.addListener(() => {
  syncDynamicRules();
  if (api.declarativeNetRequest && api.declarativeNetRequest.setExtensionActionOptions) {
    api.declarativeNetRequest.setExtensionActionOptions({ displayActionCountAsBadgeText: true });
  }
});
if (api.runtime.onStartup) api.runtime.onStartup.addListener(syncDynamicRules);

// Scriptlets run in the page's own JavaScript world as early as the browser allows.
if (api.webNavigation && api.scripting) {
  api.webNavigation.onCommitted.addListener(async (d) => {
    let host;
    try { host = new URL(d.url).hostname; } catch (e) { return; }
    if (!host || !/^https?:/.test(d.url)) return;
    const state = await getState();
    if (isPaused(state, host)) return;
    const list = await scriptletsFor(host);
    if (!list.length) return;
    try {
      await api.scripting.executeScript({
        target: { tabId: d.tabId, frameIds: [d.frameId] },
        world: 'MAIN',
        injectImmediately: true,
        func: swoopRunScriptlets,
        args: [list],
      });
    } catch (e) { /* restricted page or frame went away */ }
  });
}

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    switch (msg && msg.type) {
      case 'init': return pageConfig(msg.host);
      case 'generic': return genericSelectors(msg.host, msg.classes || [], msg.ids || []);
      case 'scriptlets': return scriptletsFor(msg.host);
      case 'state': {
        const s = await getState();
        let blocked = null;
        try {
          if (msg.tabId != null && api.declarativeNetRequest && api.declarativeNetRequest.getMatchedRules) {
            const r = await api.declarativeNetRequest.getMatchedRules({ tabId: msg.tabId });
            blocked = r.rulesMatchedInfo.filter((x) => x.rule.rulesetId !== '_dynamic').length;
          }
        } catch (e) { blocked = null; }
        return { enabled: s.enabled, paused: msg.host ? s.pausedSites.some((d) => hostMatches(msg.host, d)) : false, blocked };
      }
      case 'toggle-site': {
        const s = await getState();
        const site = msg.site;
        const paused = s.pausedSites.includes(site) ? s.pausedSites.filter((d) => d !== site) : s.pausedSites.concat([site]);
        await api.storage.local.set({ pausedSites: paused });
        await syncDynamicRules();
        return { paused: paused.includes(site) };
      }
      case 'toggle-all': {
        const s = await getState();
        await api.storage.local.set({ enabled: !s.enabled });
        await syncDynamicRules();
        return { enabled: !s.enabled };
      }
      default: return null;
    }
  })().then(sendResponse, () => sendResponse(null));
  return true;   // async response
});
