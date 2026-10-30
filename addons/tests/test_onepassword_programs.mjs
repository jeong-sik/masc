import {readFileSync} from "node:fs";
import vm from "node:vm";
import {test} from "node:test";
import assert from "node:assert/strict";

const prepare = readFileSync(new URL("../onepassword/prepare.js", import.meta.url), "utf8");
const autofill = readFileSync(new URL("../onepassword/autofill.js", import.meta.url), "utf8");
const auth = {access_token: "private-access", integration_key: "private-key"};
const website = "https://example.org/login";
function harness({initialization = "ready", enabled = true} = {}) {
  const calls = [];
  const replies = {
    createAccessRequest: {success: true, result: {accessRequest: {id: "request", entries: [{id: "entry"}]},
      appLink: "onepassword://grant-brokered-access?opaque=private-approval"}},
    getAccessRequestStatus: {success: true, result: {state: "pending"}},
    fillCredential: {success: true, result: {status: "fill_submitted", password: "must-not-escape"}},
  };
  const tab = {id: 57, url: website};
  const api = {
    initialization: {v1: {whenSettled: async () => {calls.push(["settled"]); return initialization;}}},
    agenticMode: {v1: {enable: async (...args) => {calls.push(["enable", args]); return {success: enabled};}}},
    agenticAutofill: {v1: Object.fromEntries(Object.keys(replies).map(name => [name, async parameters => {
      calls.push([name, JSON.parse(JSON.stringify(parameters))]);
      const reply = replies[name];
      if (reply instanceof Error) throw reply;
      return reply;
    }]))},
  };
  const sandbox = vm.createContext({api, URL, chrome: {tabs: {get: async id => {
    calls.push(["tab", id]); return tab;
  }}}});
  const execute = async (program, args) => JSON.parse(JSON.stringify(await
    vm.runInContext(`(${program})`, sandbox)({tab_id: 57, page_id: "cdp-page-9", url: website, arguments: args})));
  return {calls, replies, tab, api, execute};
}
test("prepare waits for initialization then enables the whole browser", async () => {
  const h = harness();
  assert.deepEqual(await h.execute(prepare, {}), {ready: true});
  assert.deepEqual(h.calls, [["settled"], ["enable", []]]);
  for (const options of [{initialization: "failed"}, {enabled: false}]) {
    const failed = harness(options);
    assert.deepEqual(await failed.execute(prepare, {}), {ready: false});
  }
});
test("request projects only private identifiers and the opaque app link", async () => {
  const h = harness();
  h.replies.createAccessRequest.result.extraSecret = "must-not-escape";
  const result = await h.execute(autofill, {...auth, kind: "request", website, goal: "Read invoices", reason: "Sign in"});
  assert.deepEqual(result, {request_id: "request", entry_id: "entry",
    app_link: "onepassword://grant-brokered-access?opaque=private-approval"});
  assert.deepEqual(h.calls.at(-1), ["createAccessRequest", {accessToken: auth.access_token,
    integrationKey: auth.integration_key, requests: {version: 2, goal: "Read invoices",
      entries: [{type: "login", parameters: {website}, reason: "Sign in"}]}}]);
});
test("status selects by entry identity and refuses duplicate or unrelated grants", async () => {
  const h = harness(), args = {...auth, kind: "status", request_id: "request", entry_id: "entry"};
  h.replies.getAccessRequestStatus.result = {state: "resolved", resolved: [
    {entryId: "unrelated", reference: "wrong"}, {entryId: "entry", reference: "correct", secret: "must-not-escape"}]};
  assert.deepEqual(await h.execute(autofill, args), {state: "resolved", granted: true, reference: "correct"});
  h.replies.getAccessRequestStatus.result.resolved = [{entryId: "unrelated", reference: "wrong"}];
  assert.deepEqual(await h.execute(autofill, args), {state: "resolved", granted: false});
  h.replies.getAccessRequestStatus.result.resolved = [{entryId: "entry", reference: "one"}, {entryId: "entry", reference: "two"}];
  assert.deepEqual(await h.execute(autofill, args), {error: "provider_outcome_unknown"});
});
test("pending and every documented terminal status are distinct", async () => {
  const h = harness(), args = {...auth, kind: "status", request_id: "request", entry_id: "entry"};
  for (const state of ["pending", "denied", "failed", "expired"]) {
    h.replies.getAccessRequestStatus.result = {state, secret: "must-not-escape"};
    assert.deepEqual(await h.execute(autofill, args), {state});
  }
  h.replies.getAccessRequestStatus.result = {state: "new_unknown_state"};
  assert.deepEqual(await h.execute(autofill, args), {error: "provider_outcome_unknown"});
});
test("fill uses the exact Chrome numeric tab and keeps website verification separate", async () => {
  const h = harness();
  assert.deepEqual(await h.execute(autofill, {...auth, kind: "fill", website, reference: "grant/path"}), {status: "fill_submitted"});
  assert.deepEqual(h.calls, [["tab", 57], ["fillCredential", {accessToken: auth.access_token,
    integrationKey: auth.integration_key, resourcePath: "grant/path", tabId: 57}]]);
});
test("navigation mismatch is refused before any credential operation", async () => {
  for (const changed of [{id: 58, url: website}, {id: 57, url: "https://example.org/changed"}]) {
    const h = harness(); Object.assign(h.tab, changed);
    assert.deepEqual(await h.execute(autofill, {...auth, kind: "fill", website, reference: "grant/path"}), {error: "target_changed"});
    assert.equal(h.calls.some(([name]) => name === "fillCredential"), false);
  }
  const h = harness();
  assert.deepEqual(await h.execute(autofill, {...auth, kind: "fill", website: "https://other.org/login", reference: "grant/path"}), {error: "target_changed"});
  assert.deepEqual(h.calls, []);
});
test("every post-entry fill failure throws a fixed fencing error", async () => {
  for (const response of [{success: false, error: {code: "autosubmitFailed", message: "private-password"}},
    {success: true, result: {status: "queued"}}, new Error("private-password")]) {
    const h = harness(); h.replies.fillCredential = response;
    await assert.rejects(h.execute(autofill, {...auth, kind: "fill", website, reference: "grant/path"}),
      {message: "onepassword_private_outcome_unknown"});
    assert.equal(h.calls.filter(([name]) => name === "fillCredential").length, 1);
  }
});
test("provider prose, arbitrary errors and extra arguments never propagate", async () => {
  const h = harness(), args = {...auth, kind: "status", request_id: "request", entry_id: "entry"};
  h.replies.getAccessRequestStatus = {success: false, error: {code: "rateLimitExceeded", message: "private-key"}};
  assert.deepEqual(await h.execute(autofill, args), {error: "rateLimitExceeded"});
  h.replies.getAccessRequestStatus.error.code = "private-key";
  assert.deepEqual(await h.execute(autofill, args), {error: "provider_failed"});
  h.replies.getAccessRequestStatus = new Error("private-key");
  assert.deepEqual(await h.execute(autofill, args), {error: "provider_outcome_unknown"});
  h.calls.length = 0;
  assert.deepEqual(await h.execute(autofill, {...args, refresh_token: "never-send"}), {error: "invalid_request"});
  assert.deepEqual(h.calls, []);
});
