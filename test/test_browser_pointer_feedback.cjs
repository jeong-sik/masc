const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../lib/browser_pointer_feedback.ml'), 'utf8');
const runtime = source.match(/let runtime = \{js\|([\s\S]*?)\|js\}/)?.[1];
assert.ok(runtime, 'feedback runtime must be present');

let attachments = 0;
let badgeWrites = 0;
const document = { documentElement: { append() { attachments++; } } };
const badge = { set textContent(value) { badgeWrites++; this.value = value; } };
const state = { document, host: { isConnected: false }, badge, pointer: null,
  requestId: 'new-request', actor: 'keeper', action: 'click', phase: 'working' };
const window = { [Symbol.for('masc.browser.pointer.feedback.v1')]: state };
const context = vm.createContext({ window, document, Symbol });
vm.runInContext(runtime, context);

context.args = { phase: 'finished', requestId: 'old-request' };
assert.equal(vm.runInContext('mascPointerFeedback(args)', context), null);
assert.equal(attachments, 0, 'stale finish must not reattach the newer badge');
assert.equal(badgeWrites, 0, 'stale finish must not rewrite the newer badge');
assert.equal(state.phase, 'working');

context.args = { phase: 'finished', requestId: 'new-request' };
vm.runInContext('mascPointerFeedback(args)', context);
assert.equal(attachments, 1, 'the owner can restore its own badge');
assert.equal(badgeWrites, 1, 'the owner can finish its own badge');
assert.equal(state.phase, 'finished');

context.args = { phase: 'recorded', requestId: 'later-request', actor: 'keeper', action: 'type' };
vm.runInContext('mascPointerFeedback(args)', context);
assert.equal(state.phase, 'recorded');
assert.match(badge.value, /Last request/);
assert.doesNotMatch(badge.value, /Working/);

context.args = { phase: 'working', requestId: 'newest-request', actor: 'keeper', action: 'click' };
vm.runInContext('mascPointerFeedback(args)', context);
const latestWrites = badgeWrites;
context.args = { phase: 'finished', requestId: 'later-request' };
assert.equal(vm.runInContext('mascPointerFeedback(args)', context), null);
assert.equal(badgeWrites, latestWrites, 'a stale finish must not change the newer request');
assert.equal(state.requestId, 'newest-request');
assert.equal(state.phase, 'working');
