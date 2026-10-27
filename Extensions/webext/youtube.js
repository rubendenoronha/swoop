// SPDX-License-Identifier: MIT
//
// YouTube, best effort. Video ads come from youtube.com itself, so neither DNS nor URL
// blocking can remove them without breaking playback. The scriptlets (scriptlets.js)
// strip ad placements from the player data before the player reads it; this script is the
// fallback when an ad still starts: it mutes it, skips to its end and presses "Skip".
// YouTube changes this often; expect occasional gaps until the rules are updated.
(() => {
  'use strict';
  if (window.__swoopYouTube) return;
  window.__swoopYouTube = true;
  const api = globalThis.browser ?? globalThis.chrome;

  let enabled = true;
  api.runtime.sendMessage({ type: 'init', host: location.hostname }).then((cfg) => { enabled = !!cfg && !cfg.paused; }, () => {});

  const SKIP = '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-slot button, .videoAdUiSkipButton';
  const OVERLAY_CLOSE = '.ytp-ad-overlay-close-button, .ytp-ad-overlay-close-container';
  let mutedByUs = false;

  function tick() {
    if (!enabled) return;
    const player = document.querySelector('#movie_player, .html5-video-player');
    if (!player) return;
    const video = player.querySelector('video');
    const adShowing = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
    if (adShowing && video) {
      if (!video.muted) { video.muted = true; mutedByUs = true; }
      if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.25) {
        try { video.currentTime = video.duration - 0.1; } catch (e) { /* not seekable yet */ }
      }
      if (video.playbackRate < 16) { try { video.playbackRate = 16; } catch (e) { /* ignore */ } }
    } else if (video && mutedByUs) {
      video.muted = false;
      mutedByUs = false;
      if (video.playbackRate > 2) video.playbackRate = 1;
    }
    for (const b of document.querySelectorAll(SKIP)) { try { b.click(); } catch (e) { /* ignore */ } }
    for (const b of document.querySelectorAll(OVERLAY_CLOSE)) { try { b.click(); } catch (e) { /* ignore */ } }
  }

  const obs = new MutationObserver(tick);
  const start = () => {
    obs.observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
    setInterval(tick, 500);
  };
  if (document.documentElement) start(); else document.addEventListener('DOMContentLoaded', start, { once: true });
})();
