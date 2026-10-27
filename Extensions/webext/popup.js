// SPDX-License-Identifier: MIT
(async () => {
  const api = globalThis.browser ?? globalThis.chrome;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  let host = '';
  try { host = new URL(tab.url).hostname; } catch (e) { host = ''; }
  // Pause the whole site ("news.bbc.co.uk" → "bbc.co.uk", best effort).
  const parts = host.split('.');
  const two = ['co.uk', 'org.uk', 'ac.uk', 'com.au', 'co.nz', 'co.jp', 'com.br', 'co.in', 'co.za'];
  const site = parts.length > 2 && two.includes(parts.slice(-2).join('.')) ? parts.slice(-3).join('.') : parts.slice(-2).join('.');
  const $ = (id) => document.getElementById(id);
  $('site').textContent = site || 'This page';

  async function refresh() {
    const s = await api.runtime.sendMessage({ type: 'state', host, tabId: tab.id });
    if (!s) return;
    $('count').textContent = s.blocked == null ? '–' : String(s.blocked);
    $('toggleSite').textContent = s.paused ? 'Resume on this site' : 'Pause on this site';
    $('toggleAll').textContent = s.enabled ? 'Turn off everywhere' : 'Turn on everywhere';
    $('toggleSite').disabled = !site || !s.enabled;
  }
  $('toggleSite').addEventListener('click', async () => {
    await api.runtime.sendMessage({ type: 'toggle-site', site });
    await refresh();
    api.tabs.reload(tab.id);
  });
  $('toggleAll').addEventListener('click', async () => {
    await api.runtime.sendMessage({ type: 'toggle-all' });
    await refresh();
    api.tabs.reload(tab.id);
  });
  refresh();
})();
