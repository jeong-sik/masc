import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source = readFileSync(new URL('../connectors/browser/extension/background.js', import.meta.url), 'utf8');
const connections = [];
const timers = new Map();
let timerId = 0;
let finishRead;
const browser = {
  runtime: {connectNative() {
    const connection = {replies: [],
      onMessage: {addListener(fn) {connection.message = fn;}},
      onDisconnect: {addListener(fn) {connection.disconnect = fn;}},
      postMessage(value) {connection.replies.push(value);}};
    connections.push(connection);
    return connection;
  }},
  tabs: {query: () => new Promise(resolve => {finishRead = resolve;})},
};
const context = vm.createContext({browser, TextEncoder, AbortController,
  setTimeout(fn) {const id = ++timerId; timers.set(id, fn); return id;},
  clearTimeout(id) {timers.delete(id);}});
vm.runInContext(source, context);
const first = connections[0];
vm.runInContext('connect(); connect();', context);
assert.equal(connections.length, 1, 'an active port must not be duplicated');
const pending = first.message({id: 'old-request', verb: 'tabs.list', deadlineMs:Date.now()+20000, args: {}});
first.disconnect();
assert.equal(timers.size, 1);
const reconnect = [...timers.values()][0];
reconnect();
assert.equal(connections.length, 2);
const second = connections[1];
finishRead([{id: 33, title: 'Fixture', url: 'https://example.org/'}]);
await pending;
assert.equal(first.replies[0].id, 'old-request');
assert.equal(second.replies.length, 0, 'an old response must not enter the new host');
first.disconnect();
assert.equal(timers.size, 0, 'a stale disconnect must not retire the current host');
await second.message({id: 'new-request', verb: 'unknown-fixture', deadlineMs:Date.now()+20000, args: {}});
assert.equal(second.replies[0].id, 'new-request');
second.disconnect();
assert.equal(timers.size, 1, 'the current host still reconnects');
console.log('PASS: native connection identity, late response, stale disconnect, reconnect');
