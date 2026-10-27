// SPDX-License-Identifier: MIT
//
// Swoop Shield content script: hides ad elements.
//   • site-specific and complex generic selectors are injected as CSS at document_start;
//   • simple generic selectors (.class / #id, tens of thousands of them) are only injected
//     when that class or id actually appears in the page (checked as the DOM changes);
//   • procedural selectors (:has-text, :upward, :remove, :matches-css, :min-text-length,
//     :-abp-has, :-abp-contains) are evaluated in JS.
(() => {
  'use strict';
  const api = globalThis.browser ?? globalThis.chrome;
  const host = location.hostname;
  if (!host || window.__swoopShieldContent) return;
  window.__swoopShieldContent = true;

  const injected = new Set();
  let sheet = null;
  function ensureSheet() {
    if (sheet) return sheet;
    const el = document.createElement('style');
    el.setAttribute('data-swoop-shield', '');
    (document.head || document.documentElement).appendChild(el);
    sheet = el.sheet;
    return sheet;
  }
  // One invalid selector invalidates a whole CSS rule, so insert in chunks and fall back
  // to one-by-one for a chunk that fails.
  function hide(selectors, declaration = 'display: none !important;') {
    const fresh = selectors.filter((s) => s && !injected.has(s));
    if (!fresh.length) return;
    fresh.forEach((s) => injected.add(s));
    const s = ensureSheet();
    if (!s) return;
    for (let i = 0; i < fresh.length; i += 200) {
      const chunk = fresh.slice(i, i + 200);
      try { s.insertRule(`${chunk.join(',\n')} { ${declaration} }`, s.cssRules.length); } catch (e) {
        for (const one of chunk) { try { s.insertRule(`${one} { ${declaration} }`, s.cssRules.length); } catch (e2) { /* invalid here */ } }
      }
    }
  }
  function addStyles(rules) {
    const s = ensureSheet();
    if (!s) return;
    for (const r of rules) { try { s.insertRule(r, s.cssRules.length); } catch (e) { /* ignore */ } }
  }

  // ---- lazy generic filtering ----
  const seenClasses = new Set();
  const seenIds = new Set();
  let pending = null;
  function scan(root) {
    const classes = [], ids = [];
    const visit = (el) => {
      if (el.id && !seenIds.has(el.id)) { seenIds.add(el.id); ids.push(el.id); }
      const cl = el.classList;
      if (cl) for (const c of cl) if (!seenClasses.has(c)) { seenClasses.add(c); classes.push(c); }
    };
    if (root.nodeType === 1) visit(root);
    if (root.querySelectorAll) for (const el of root.querySelectorAll('[id],[class]')) visit(el);
    return { classes, ids };
  }
  let queuedClasses = [], queuedIds = [];
  function queue(r) {
    queuedClasses.push(...r.classes);
    queuedIds.push(...r.ids);
    if (pending || (!queuedClasses.length && !queuedIds.length)) return;
    pending = setTimeout(() => {
      pending = null;
      const classes = queuedClasses, ids = queuedIds;
      queuedClasses = []; queuedIds = [];
      api.runtime.sendMessage({ type: 'generic', host, classes, ids }).then((sel) => { if (sel && sel.length) hide(sel); }, () => {});
    }, 50);
  }

  // ---- procedural selectors ----
  const OPS = ['has-text', '-abp-contains', 'contains', 'upward', 'remove', 'matches-css', 'matches-css-before', 'matches-css-after',
    'min-text-length', '-abp-has', 'xpath', 'nth-ancestor', 'watch-attr', 'style', 'others', 'if', 'if-not', 'matches-attr'];
  function parseProcedural(src) {
    // "base:op(arg):op2(arg) > tail" → { base, steps: [{op,arg}|{css}] }
    const steps = [];
    let i = 0, base = null, buf = '';
    while (i < src.length) {
      if (src[i] === ':') {
        const name = OPS.find((op) => src.startsWith(op + '(', i + 1));
        if (name) {
          let depth = 0, j = i + 1 + name.length;
          const start = j + 1;
          for (; j < src.length; j++) {
            if (src[j] === '(') depth++;
            else if (src[j] === ')') { depth--; if (depth === 0) break; }
          }
          if (base === null) base = buf.trim() || '*'; else if (buf.trim()) steps.push({ css: buf.trim() });
          buf = '';
          steps.push({ op: name, arg: src.slice(start, j) });
          i = j + 1;
          continue;
        }
      }
      buf += src[i++];
    }
    if (base === null) return null;
    if (buf.trim()) steps.push({ css: buf.trim() });
    return { base, steps };
  }
  const textRe = (arg) => {
    const m = /^\/(.*)\/([imsu]*)$/.exec(arg);
    if (m) { try { return new RegExp(m[1], m[2]); } catch (e) { return null; } }
    return null;
  };
  function applyStep(nodes, st) {
    if (st.css) {
      const out = [];
      for (const n of nodes) { try { out.push(...n.querySelectorAll(':scope ' + st.css)); } catch (e) { /* bad css */ } }
      return out;
    }
    const a = st.arg;
    switch (st.op) {
      case 'has-text': case '-abp-contains': case 'contains': {
        const re = textRe(a);
        return nodes.filter((n) => (re ? re.test(n.textContent) : n.textContent.includes(a)));
      }
      case 'min-text-length': return nodes.filter((n) => n.textContent.length >= Number(a));
      case '-abp-has': return nodes.filter((n) => { try { return !!n.querySelector(':scope ' + a); } catch (e) { return false; } });
      case 'upward': case 'nth-ancestor': {
        const out = [];
        for (const n of nodes) {
          let p = n;
          if (/^\d+$/.test(a)) { for (let k = 0; k < Number(a) && p; k++) p = p.parentElement; } else { p = n.parentElement && n.parentElement.closest(a); }
          if (p) out.push(p);
        }
        return out;
      }
      case 'matches-css': case 'matches-css-before': case 'matches-css-after': {
        const pseudo = st.op.endsWith('before') ? '::before' : st.op.endsWith('after') ? '::after' : null;
        const [prop, ...rest] = a.split(':');
        const want = rest.join(':').trim();
        const re = textRe(want);
        return nodes.filter((n) => { const v = getComputedStyle(n, pseudo).getPropertyValue(prop.trim()); return re ? re.test(v) : v === want; });
      }
      case 'matches-attr': {
        const [k, v] = a.split('=').map((x) => x.replace(/^"|"$/g, ''));
        return nodes.filter((n) => [...n.attributes].some((at) => at.name === k && (v === undefined || at.value === v)));
      }
      case 'xpath': {
        const out = [];
        for (const n of nodes) {
          try {
            const r = document.evaluate(a, n, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
            for (let k = 0; k < r.snapshotLength; k++) { const x = r.snapshotItem(k); if (x.nodeType === 1) out.push(x); }
          } catch (e) { /* bad xpath */ }
        }
        return out;
      }
      default: return nodes;   // remove/style/watch-attr are actions, handled by the caller
    }
  }
  let procedural = [];
  function runProcedural() {
    for (const p of procedural) {
      let nodes;
      try { nodes = [...document.querySelectorAll(p.base)]; } catch (e) { continue; }
      let action = 'hide', style = null;
      for (const st of p.steps) {
        if (st.op === 'remove') { action = 'remove'; continue; }
        if (st.op === 'style') { action = 'style'; style = st.arg; continue; }
        if (st.op === 'watch-attr') continue;
        nodes = applyStep(nodes, st);
        if (!nodes.length) break;
      }
      for (const n of nodes) {
        if (n.__swoopHidden) continue;
        n.__swoopHidden = true;
        if (action === 'remove') n.remove();
        else if (action === 'style' && style) n.setAttribute('style', (n.getAttribute('style') || '') + ';' + style);
        else n.style.setProperty('display', 'none', 'important');
      }
    }
  }

  let observer = null;
  let procTimer = null;
  function observe(generic) {
    if (observer) return;
    observer = new MutationObserver((muts) => {
      if (generic) for (const m of muts) for (const n of m.addedNodes) if (n.nodeType === 1) queue(scan(n));
      if (procedural.length && !procTimer) procTimer = setTimeout(() => { procTimer = null; runProcedural(); }, 100);
    });
    const start = () => observer.observe(document.documentElement, { childList: true, subtree: true });
    if (document.documentElement) start();
  }

  api.runtime.sendMessage({ type: 'init', host }).then((cfg) => {
    if (!cfg || cfg.paused) return;
    hide(cfg.css || []);
    addStyles(cfg.styles || []);
    procedural = (cfg.procedural || []).map(parseProcedural).filter(Boolean);
    const generic = !cfg.genericHide;
    const firstScan = () => {
      if (generic) queue(scan(document.documentElement));
      if (procedural.length) runProcedural();
      observe(generic);
    };
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', firstScan, { once: true });
      observe(generic);
    } else {
      firstScan();
    }
  }, () => {});
})();
