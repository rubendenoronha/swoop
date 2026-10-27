// SPDX-License-Identifier: MIT
// node Extensions/webext/test/scriptlets.test.js : scriptlet behaviour outside a browser.
'use strict';
const assert = require('assert');
globalThis.window = globalThis;
const { swoopRunScriptlets } = require('../scriptlets.js');

window.ytInitialPlayerResponse = { adPlacements: [1], videoDetails: { title: 'x' } };
swoopRunScriptlets([
  ['set-constant', 'ytInitialPlayerResponse.adPlacements', 'undefined'],
  ['set-constant', 'later.flag', 'true'],
  ['json-prune', 'playerResponse.adPlacements adPlacements'],
  ['abort-on-property-read', 'adblockDetector'],
  ['prevent-setTimeout', 'adblock'],
]);

// set-constant on an existing and a not-yet-defined chain
assert.strictEqual(window.ytInitialPlayerResponse.adPlacements, undefined);
assert.strictEqual(window.ytInitialPlayerResponse.videoDetails.title, 'x');
window.later = {};
assert.strictEqual(window.later.flag, true);
window.ytInitialPlayerResponse = { adPlacements: [2], keep: 1 };
assert.strictEqual(window.ytInitialPlayerResponse.adPlacements, undefined, 'still trapped after reassignment');

// json-prune strips ad placements from parsed JSON
const parsed = JSON.parse('{"adPlacements":[1],"playerResponse":{"adPlacements":[2],"streamingData":{}},"ok":true}');
assert.deepStrictEqual(parsed, { playerResponse: { streamingData: {} }, ok: true });

// abort-on-property-read throws on access
assert.throws(() => window.adblockDetector, ReferenceError);

// prevent-setTimeout drops matching callbacks only
let ran = 0;
assert.strictEqual(setTimeout(() => { /* adblock check */ ran++; }, 1), 0);
const t = setTimeout(() => { ran += 10; }, 1);
clearTimeout(t);

// running twice is a no-op
swoopRunScriptlets([['set-constant', 'x2', '1']]);
assert.strictEqual(window.x2, undefined);
console.log('scriptlets: all assertions passed');
