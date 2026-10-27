// SPDX-License-Identifier: MIT
//
// Swoop Shield scriptlets: small, well-known page patches that filter lists ask for
// (uBO "+js()", AdGuard "//scriptlet()", ABP "#$#" snippets). Swoop's own implementations,
// written from the public behaviour of those scriptlets.
//
// swoopRunScriptlets is passed whole to scripting.executeScript({ world: "MAIN" }), so it
// must not reference anything outside itself.
/* exported swoopRunScriptlets */
function swoopRunScriptlets(list) {
  'use strict';
  if (!Array.isArray(list) || list.length === 0) return;
  const W = window;
  if (W.__swoopScriptletsRan) return;
  W.__swoopScriptletsRan = true;

  const log = () => {};
  const toRegex = (s) => {
    if (s === undefined || s === null || s === '') return null;
    const m = /^\/(.+)\/([gimsu]*)$/.exec(s);
    if (m) { try { return new RegExp(m[1], m[2]); } catch (e) { return null; } }
    return new RegExp(String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  };
  const matches = (re, text) => re === null || re.test(String(text));
  const constValue = (v) => {
    switch (v) {
      case 'undefined': return undefined;
      case 'false': return false;
      case 'true': return true;
      case 'null': return null;
      case 'noopFunc': return function () {};
      case 'trueFunc': return function () { return true; };
      case 'falseFunc': return function () { return false; };
      case 'emptyArr': case '[]': return [];
      case 'emptyObj': case '{}': return {};
      case 'emptyStr': case '': return '';
      case 'zero': case '0': return 0;
      case 'one': case '1': return 1;
      case 'noopPromiseResolve': return function () { return Promise.resolve(); };
      case 'noopPromiseReject': return function () { return Promise.reject(); };
      default:
        if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
        return v;
    }
  };

  // Define `path` (a.b.c) on window, creating getters/setters along the chain.
  function setConstant(path, rawValue) {
    const value = constValue(rawValue);
    const parts = path.split('.');
    const trap = (owner, i) => {
      const prop = parts[i];
      if (i === parts.length - 1) {
        try {
          Object.defineProperty(owner, prop, { configurable: true, get: () => value, set: () => {} });
        } catch (e) { log(e); }
        return;
      }
      let inner = owner[prop];
      if (inner !== undefined && inner !== null && (typeof inner === 'object' || typeof inner === 'function')) {
        trap(inner, i + 1);
      }
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: () => inner,
          set: (v) => {
            inner = v;
            if (v !== undefined && v !== null && (typeof v === 'object' || typeof v === 'function')) trap(v, i + 1);
          },
        });
      } catch (e) { log(e); }
    };
    trap(W, 0);
  }

  function abortOnProperty(path, onWrite) {
    const parts = path.split('.');
    const magic = 'SwoopShield' + Math.random().toString(36).slice(2);
    const abort = () => { throw new ReferenceError(magic); };
    const trap = (owner, i) => {
      const prop = parts[i];
      if (i === parts.length - 1) {
        try {
          if (onWrite) Object.defineProperty(owner, prop, { configurable: true, get: () => undefined, set: abort });
          else Object.defineProperty(owner, prop, { configurable: true, get: abort, set: () => {} });
        } catch (e) { log(e); }
        return;
      }
      let inner = owner[prop];
      if (inner && typeof inner === 'object') trap(inner, i + 1);
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: () => inner,
          set: (v) => { inner = v; if (v && typeof v === 'object') trap(v, i + 1); },
        });
      } catch (e) { log(e); }
    };
    trap(W, 0);
    const prev = W.onerror;
    W.onerror = function (msg, ...rest) {
      if (typeof msg === 'string' && msg.includes(magic)) return true;
      return prev ? prev.call(this, msg, ...rest) : false;
    };
  }

  function abortCurrentInlineScript(path, search) {
    const re = toRegex(search);
    const parts = path.split('.');
    const prop = parts.pop();
    let owner = W;
    for (const p of parts) { owner = owner && owner[p]; }
    if (!owner) return;
    const desc = Object.getOwnPropertyDescriptor(owner, prop);
    let value = owner[prop];
    const check = () => {
      const s = document.currentScript;
      if (s instanceof HTMLScriptElement && !s.src && matches(re, s.textContent)) throw new ReferenceError('SwoopShield');
    };
    try {
      Object.defineProperty(owner, prop, {
        configurable: true,
        get() { check(); return desc && desc.get ? desc.get.call(this) : value; },
        set(v) { check(); if (desc && desc.set) desc.set.call(this, v); else value = v; },
      });
    } catch (e) { log(e); }
  }

  // Remove properties (space-separated dotted paths, "[]" = every array item) from an object.
  function prune(obj, paths, required) {
    if (!obj || typeof obj !== 'object') return obj;
    const has = (o, path) => path.split('.').reduce((a, k) => (a && typeof a === 'object' ? a[k] : undefined), o) !== undefined;
    if (required && required.length && !required.every((p) => has(obj, p))) return obj;
    for (const path of paths) {
      const keys = path.split('.');
      const walk = (o, i) => {
        if (!o || typeof o !== 'object') return;
        const k = keys[i];
        if (k === '[]' && Array.isArray(o)) { o.forEach((x) => walk(x, i + 1)); return; }
        if (i === keys.length - 1) { if (k in o) delete o[k]; return; }
        walk(o[k], i + 1);
      };
      walk(obj, 0);
    }
    return obj;
  }

  function jsonPrune(pruneArg, requiredArg) {
    const paths = (pruneArg || '').split(/\s+/).filter(Boolean);
    const required = (requiredArg || '').split(/\s+/).filter(Boolean);
    if (!paths.length) return;
    const parse = JSON.parse;
    JSON.parse = new Proxy(parse, {
      apply(target, thisArg, args) {
        const r = Reflect.apply(target, thisArg, args);
        try { prune(r, paths, required); } catch (e) { log(e); }
        return r;
      },
    });
    const json = Response.prototype.json;
    Response.prototype.json = new Proxy(json, {
      apply(target, thisArg, args) {
        return Reflect.apply(target, thisArg, args).then((r) => { try { prune(r, paths, required); } catch (e) { log(e); } return r; });
      },
    });
  }

  // args: prunePaths, requiredPaths, then key/value pairs; "propsToMatch" = URL pattern.
  function kv(args) {
    const o = {};
    for (let i = 0; i + 1 < args.length; i += 2) o[args[i]] = args[i + 1];
    return o;
  }

  function jsonPruneFetch(pruneArg, requiredArg, ...rest) {
    const paths = (pruneArg || '').split(/\s+/).filter(Boolean);
    const required = (requiredArg || '').split(/\s+/).filter(Boolean);
    const urlRe = toRegex(kv(rest).propsToMatch);
    const orig = W.fetch;
    if (!orig || !paths.length) return;
    W.fetch = new Proxy(orig, {
      apply(target, thisArg, args) {
        const req = args[0];
        const url = typeof req === 'string' ? req : (req && req.url) || '';
        const p = Reflect.apply(target, thisArg, args);
        if (!matches(urlRe, url)) return p;
        return p.then((resp) => resp.clone().text().then((text) => {
          try {
            const data = prune(JSON.parse(text), paths, required);
            return new Response(JSON.stringify(data), { status: resp.status, statusText: resp.statusText, headers: resp.headers });
          } catch (e) { return resp; }
        }).catch(() => resp));
      },
    });
  }

  function jsonPruneXHR(pruneArg, requiredArg, ...rest) {
    const paths = (pruneArg || '').split(/\s+/).filter(Boolean);
    const required = (requiredArg || '').split(/\s+/).filter(Boolean);
    const urlRe = toRegex(kv(rest).propsToMatch);
    if (!paths.length) return;
    const XHR = W.XMLHttpRequest;
    const open = XHR.prototype.open;
    XHR.prototype.open = function (method, url, ...a) { this.__swoopUrl = String(url); return open.call(this, method, url, ...a); };
    for (const prop of ['response', 'responseText']) {
      const d = Object.getOwnPropertyDescriptor(XHR.prototype, prop);
      if (!d || !d.get) continue;
      Object.defineProperty(XHR.prototype, prop, {
        configurable: true,
        get() {
          const v = d.get.call(this);
          if (this.readyState !== 4 || !matches(urlRe, this.__swoopUrl || '')) return v;
          try {
            if (typeof v === 'string') return JSON.stringify(prune(JSON.parse(v), paths, required));
            if (v && typeof v === 'object') return prune(v, paths, required);
          } catch (e) { log(e); }
          return v;
        },
      });
    }
  }

  function preventTimer(name, search, delay) {
    const re = toRegex(search);
    const wantDelay = delay !== undefined && delay !== '' ? Number(delay) : null;
    const orig = W[name];
    W[name] = new Proxy(orig, {
      apply(target, thisArg, args) {
        const code = String(args[0]);
        if (matches(re, code) && (wantDelay === null || Number(args[1]) === wantDelay)) return 0;
        return Reflect.apply(target, thisArg, args);
      },
    });
  }

  function preventAddEventListener(type, search) {
    const typeRe = toRegex(type), fnRe = toRegex(search);
    const orig = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = new Proxy(orig, {
      apply(target, thisArg, args) {
        if (matches(typeRe, args[0]) && matches(fnRe, String(args[1]))) return undefined;
        return Reflect.apply(target, thisArg, args);
      },
    });
  }

  function preventFetch(search) {
    const re = toRegex(search === '*' ? '' : search);
    const orig = W.fetch;
    if (!orig) return;
    W.fetch = new Proxy(orig, {
      apply(target, thisArg, args) {
        const req = args[0];
        const url = typeof req === 'string' ? req : (req && req.url) || '';
        if (matches(re, url)) return Promise.resolve(new Response('', { status: 200 }));
        return Reflect.apply(target, thisArg, args);
      },
    });
  }

  function preventXHR(search) {
    const re = toRegex(search === '*' ? '' : search);
    const XHR = W.XMLHttpRequest;
    const open = XHR.prototype.open, send = XHR.prototype.send;
    XHR.prototype.open = function (m, url, ...a) { this.__swoopBlock = matches(re, String(url)); return open.call(this, m, url, ...a); };
    XHR.prototype.send = function (...a) {
      if (!this.__swoopBlock) return send.apply(this, a);
      Object.defineProperty(this, 'readyState', { value: 4 });
      Object.defineProperty(this, 'status', { value: 200 });
      Object.defineProperty(this, 'responseText', { value: '' });
      setTimeout(() => { this.dispatchEvent(new Event('readystatechange')); this.dispatchEvent(new Event('load')); this.dispatchEvent(new Event('loadend')); }, 1);
    };
  }

  function onDOM(fn) {
    const run = () => { try { fn(); } catch (e) { log(e); } };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true }); else run();
    const obs = new MutationObserver(() => run());
    const start = () => obs.observe(document.documentElement, { childList: true, subtree: true });
    if (document.documentElement) start(); else document.addEventListener('readystatechange', start, { once: true });
    setTimeout(() => obs.disconnect(), 20000);
  }

  function removeAttr(attrs, selector) {
    const names = String(attrs).split(/\s*\|\s*/).filter(Boolean);
    onDOM(() => {
      for (const el of document.querySelectorAll(selector || names.map((n) => `[${n}]`).join(','))) names.forEach((n) => el.removeAttribute(n));
    });
  }

  function removeClass(classes, selector) {
    const names = String(classes).split(/\s*\|\s*/).filter(Boolean);
    onDOM(() => {
      for (const el of document.querySelectorAll(selector || names.map((n) => `.${CSS.escape(n)}`).join(','))) el.classList.remove(...names);
    });
  }

  function noWindowOpen(search) {
    const re = toRegex(search === '*' ? '' : search);
    const orig = W.open;
    W.open = new Proxy(orig, {
      apply(target, thisArg, args) {
        if (matches(re, String(args[0] || ''))) return null;
        return Reflect.apply(target, thisArg, args);
      },
    });
  }

  function preventEval(search) {
    const re = toRegex(search);
    const orig = W.eval;
    W.eval = new Proxy(orig, { apply(t, th, args) { if (matches(re, String(args[0]))) return undefined; return Reflect.apply(t, th, args); } });
  }

  function setCookie(name, value) {
    const ok = ['true', 'false', 'yes', 'no', 'ok', 'on', 'off', 'accept', 'reject', 'allow', 'deny', '0', '1', ''];
    if (!ok.includes(String(value).toLowerCase()) && !/^\d+$/.test(value)) return;
    document.cookie = `${encodeURIComponent(name)}=${encodeURIComponent(value)}; path=/; max-age=31536000`;
  }

  function setLocalStorage(key, value) {
    try { localStorage.setItem(key, String(constValue(value))); } catch (e) { log(e); }
  }

  const impl = {
    'set-constant': setConstant,
    'abort-on-property-read': (p) => abortOnProperty(p, false),
    'abort-on-property-write': (p) => abortOnProperty(p, true),
    'abort-current-inline-script': abortCurrentInlineScript,
    'json-prune': jsonPrune,
    'json-prune-fetch-response': jsonPruneFetch,
    'json-prune-xhr-response': jsonPruneXHR,
    'prevent-setTimeout': (s, d) => preventTimer('setTimeout', s, d),
    'prevent-setInterval': (s, d) => preventTimer('setInterval', s, d),
    'prevent-addEventListener': preventAddEventListener,
    'prevent-fetch': preventFetch,
    'prevent-xhr': preventXHR,
    'remove-attr': removeAttr,
    'remove-class': removeClass,
    'no-window-open-if': noWindowOpen,
    'prevent-eval-if': preventEval,
    'set-cookie': setCookie,
    'set-local-storage-item': setLocalStorage,
  };
  for (const entry of list) {
    const [name, ...args] = entry;
    const fn = impl[name];
    if (!fn) continue;
    try { fn(...args); } catch (e) { log(e); }
  }
}

if (typeof module !== 'undefined') module.exports = { swoopRunScriptlets };
