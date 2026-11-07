const mascNetworkRules = {"requests":200,"pathBytes":500,"headerNames":64,"egoBuffer":10000,"redacted":"REDACTED"};
function mascPageEventState(page) {
  const label = page === null || typeof page !== 'object' ? undefined : page.label;
  if (typeof label !== 'string' || label === '') throw new Error('ego Page has no label');
  const states = globalThis.mascEventLogs ??= new Map();
  let state = states.get(label);
  if (state === undefined) {
    state = {pending: [], rows: [], open: new Map(), dropped: 0, malformed: 0, lastMalformed: null, fullBufferReads: 0};
    states.set(label, state);
  }
  return state;
}
function mascRedactUrl(raw) {
  let url;
  try { url = new URL(raw); } catch (error) { return null; }
  // data:, blob:, about: and file: name no host; what follows the scheme can
  // be the whole payload, so only the scheme stays.
  if (url.host === '') return {url: url.protocol, cut: true};
  // A special URL's path and query are ASCII after URL parsing, so a length
  // in characters is a length in bytes. A cut never ends inside an escape.
  let path = url.pathname, cut = false;
  if (path.length > mascNetworkRules.pathBytes) {
    path = path.slice(0, mascNetworkRules.pathBytes);
    const escape = path.lastIndexOf('%');
    if (escape >= 0 && escape > path.length - 3) path = path.slice(0, escape);
    cut = true;
  }
  const query = url.search === '' ? '' : '?' + url.search.slice(1).split('&').map(part => {
    const at = part.indexOf('=');
    return at < 0 ? part : part.slice(0, at) + '=' + mascNetworkRules.redacted;
  }).join('&');
  return {url: url.protocol + '//' + url.host + path + query, cut};
}
function mascRecordNetwork(state, event) {
  const plain = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const tracked = ['Network.requestWillBeSent', 'Network.responseReceived', 'Network.loadingFinished', 'Network.loadingFailed'];
  if (!tracked.includes(event.method)) return;
  const malformed = reason => { state.malformed++; state.lastMalformed = event.method + ': ' + reason; };
  const params = event.params;
  if (!plain(params) || typeof params.requestId !== 'string' || params.requestId === '') return malformed('no requestId');
  const names = headers => {
    if (headers === undefined) return {names: [], total: 0};
    if (!plain(headers)) return null;
    const listed = Object.keys(headers);
    return {names: listed.slice(0, mascNetworkRules.headerNames), total: listed.length};
  };
  const response = value => {
    if (!plain(value) || !Number.isInteger(value.status) || typeof value.mimeType !== 'string') return null;
    const headers = names(value.headers);
    return headers === null ? null : {status: value.status, mimeType: value.mimeType, responseHeaders: headers};
  };
  const bytes = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.round(value) : null;
  const open = state.open.get(params.requestId);
  switch (event.method) {
    case 'Network.requestWillBeSent': {
      const request = params.request;
      if (!plain(request) || typeof request.url !== 'string' || typeof request.method !== 'string'
          || typeof params.wallTime !== 'number' || !Number.isFinite(params.wallTime))
        return malformed('no address, method or wallTime');
      const url = mascRedactUrl(request.url);
      if (url === null) return malformed('an address URL cannot parse');
      const requestHeaders = names(request.headers);
      if (requestHeaders === null) return malformed('request headers are not an object');
      // A redirect starts again under the same requestId; the hop before it
      // completed with the redirect response.
      if (params.redirectResponse !== undefined) {
        if (open !== undefined) {
          const hop = response(params.redirectResponse), received = bytes(params.redirectResponse?.encodedDataLength);
          if (hop === null || received === null) return malformed('a redirect response without status, mimeType or encodedDataLength');
          open.response = hop; open.bytesReceived = received; open.state = 'completed';
          state.open.delete(params.requestId);
        }
      } else if (open !== undefined) return malformed('a second start without a redirect');
      const row = {id: params.requestId, method: request.method, url: url.url, urlCut: url.cut,
        timestamp: Math.floor(params.wallTime * 1000), requestHeaders, state: 'pending'};
      state.rows.push(row);
      state.open.set(params.requestId, row);
      if (state.rows.length > mascNetworkRules.requests) {
        const old = state.rows.shift();
        state.dropped++;
        if (state.open.get(old.id) === old) state.open.delete(old.id);
      }
      return;
    }
    // An end for a request whose start is not listed is skipped: its start
    // came before this SDK process held the Page, fell out of ego's buffer,
    // or was dropped from the log.
    case 'Network.responseReceived': {
      if (open === undefined) return;
      const seen = response(params.response);
      if (seen === null) return malformed('a response without status or mimeType');
      open.response = seen;
      return;
    }
    case 'Network.loadingFinished': {
      if (open === undefined) return;
      const received = bytes(params.encodedDataLength);
      if (open.response === undefined || received === null) return malformed('finished without a response or encodedDataLength');
      open.bytesReceived = received; open.state = 'completed';
      state.open.delete(params.requestId);
      return;
    }
    case 'Network.loadingFailed': {
      if (open === undefined) return;
      if (typeof params.errorText !== 'string') return malformed('failed without errorText');
      // A request block answers an empty errorText and blockedReason inspector (L8 evidence).
      open.error = [params.errorText, typeof params.blockedReason === 'string' ? 'blocked: ' + params.blockedReason : '']
        .filter(part => part !== '').join(' ');
      open.state = 'failed';
      state.open.delete(params.requestId);
      return;
    }
  }
}
async function mascDrainPage(page) {
  const state = mascPageEventState(page);
  const drained = await page.events();
  if (!Array.isArray(drained)) throw new Error('ego returned a non-array event buffer');
  if (drained.length >= mascNetworkRules.egoBuffer) state.fullBufferReads++;
  for (const event of drained) {
    if (event !== null && typeof event === 'object' && typeof event.method === 'string' && event.method.startsWith('Network.'))
      mascRecordNetwork(state, event);
    else state.pending.push(event);
  }
  // ego's own buffer keeps its newest events; the kept rest does the same.
  if (state.pending.length > mascNetworkRules.egoBuffer)
    state.pending.splice(0, state.pending.length - mascNetworkRules.egoBuffer);
  return state;
}
async function mascPageEvents(page) {
  const state = await mascDrainPage(page);
  return state.pending.splice(0);
}
async function mascNetworkLog(page) {
  const state = await mascDrainPage(page);
  const row = item => {
    const base = {method: item.method, url: item.url, urlCut: item.urlCut, timestamp: item.timestamp, requestHeaders: item.requestHeaders};
    if (item.state === 'completed') return {...base, state: 'completed', status: item.response.status, mimeType: item.response.mimeType,
      bytesReceived: item.bytesReceived, responseHeaders: item.response.responseHeaders};
    if (item.state === 'failed') return {...base, state: 'failed', error: item.error};
    // The response came but its body has not finished loading, as when the
    // page never reads a fetch body (L8 evidence).
    if (item.response !== undefined) return {...base, state: 'responded', status: item.response.status,
      mimeType: item.response.mimeType, responseHeaders: item.response.responseHeaders};
    return {...base, state: 'pending'};
  };
  return {requests: state.rows.map(row), dropped: state.dropped,
    malformedEvents: {count: state.malformed, last: state.lastMalformed}, fullBufferReads: state.fullBufferReads};
}// L8 probe c: the production drain script (network.js, prepended unchanged) on real Pages.
// It checks that the log keeps no secret, that alternating workflow-style drains and network reads lose no
// event, and how redirects, failures, blocks, long paths, userinfo, the row limit and a popup look.
// Logs rows of the test server only. No call opens a permission prompt or a dialog.
const log = (step, value) => console.log(JSON.stringify({ step, at: new Date().toISOString(), value }));
const run = async (step, fn) => {
  try { const value = await fn(); log(step, value === undefined ? null : value); return value; }
  catch (error) { log(step, { error: String((error && error.message) || error) }); return undefined; }
};
const port = 18775;
const origin = `http://127.0.0.1:${port}`;
const cross = `http://localhost:${port}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const secrets = ["L8_SECRET_QUERY", "L8_SECRET_HEADER", "L8_SECRET_ANSWER", "user:pass", "L8_USER"];
const leaks = (value) => secrets.filter((secret) => JSON.stringify(value).includes(secret));
const methods = (events) => { const c = {}; for (const e of events) c[e.method] = (c[e.method] ?? 0) + 1; return c; };
const since = (answer, count) => answer.requests.slice(-count);
const task = await taskSpace("masc-l8-network-c");
log("space", { spaceId: task.spaceId, name: task.name, ownership: task.ownership });
const p1 = task.page("p1");
await run("c1.goto", () => p1.goto(origin + "/page"));
await run("c1.log", async () => { const answer = await mascNetworkLog(p1); return { ...answer, leaks: leaks(answer) }; });
await run("c2.fire", () => p1.evaluate(() => window.fire(3, "c2")));
await sleep(300);
await run("c2.log", async () => { const answer = await mascNetworkLog(p1); return { last: since(answer, 3), total: answer.requests.length, leaks: leaks(answer) }; });
// C3: a workflow-style drain and a network read, alternating.
await run("c3.fire", () => p1.evaluate(() => window.fire(2, "c3a")));
await sleep(300);
await run("c3.pageEvents", async () => { const events = await mascPageEvents(p1); return { methods: methods(events) }; });
await run("c3.logAfterPageEvents", async () => { const answer = await mascNetworkLog(p1); return since(answer, 2).map((row) => row.url + " " + row.state); });
await run("c3.reload", () => p1.reload());
await run("c3.logAfterReload", async () => { const answer = await mascNetworkLog(p1); return since(answer, 2).map((row) => row.url + " " + row.state); });
await run("c3.pageEventsAfterLog", async () => methods(await mascPageEvents(p1)));
await run("c3.pageEventsAgain", async () => (await mascPageEvents(p1)).length);
// C4: a redirect. C5: a refused connection and a slow answer.
await run("c4.fetch", () => p1.evaluate(() => fetch("/redir").then((r) => r.status)));
await sleep(200);
await run("c4.log", async () => since(await mascNetworkLog(p1), 2));
await run("c5.refused", () => p1.evaluate((u) => fetch(u).then(() => "ok", (e) => String(e)), "http://127.0.0.1:18799/x?token=L8_SECRET_QUERY"));
await run("c5.slow", () => p1.evaluate(() => { fetch("/slow?tag=slow&token=L8_SECRET_QUERY"); return true; }));
await sleep(300);
await run("c5.log", async () => since(await mascNetworkLog(p1), 2).map((row) => ({ url: row.url, state: row.state, error: row.error })));
await sleep(2200);
await run("c5.slowEnd", async () => since(await mascNetworkLog(p1), 1).map((row) => ({ url: row.url, state: row.state, status: row.status })));
// C6: a request block from L6 shows in the error.
await run("c6.block", () => p1.cdp("Network.setBlockedURLs", { urlPatterns: [{ urlPattern: "*://localhost:*/*", block: true }] }));
await run("c6.fetch", () => p1.evaluate((u) => fetch(u, { mode: "no-cors" }).then(() => "ok", (e) => String(e)), cross + "/x?tag=blocked"));
await run("c6.unblock", () => p1.cdp("Network.setBlockedURLs", { urlPatterns: [] }));
await run("c6.log", async () => since(await mascNetworkLog(p1), 1).map((row) => ({ url: row.url, state: row.state, error: row.error })));
// C7: a long path, an address with a user, and a data: image.
await run("c7.long", () => p1.evaluate((path) => fetch(path + "?token=L8_SECRET_QUERY").then((r) => r.status), "/" + "a".repeat(498) + "%E2%82%AC" + "b".repeat(40)));
await run("c7.user", () => p1.evaluate((u) => new Promise((resolve) => { const img = new Image(); img.onload = img.onerror = () => resolve(true); img.src = u; }),
  "http://L8_USER:pass@127.0.0.1:18775/x?tag=user"));
await run("c7.data", () => p1.evaluate(() => new Promise((resolve) => { const img = new Image(); img.onload = img.onerror = () => resolve(true);
  img.src = "data:image/gif;base64,R0lGODlhAQABAAAAACw="; })));
await sleep(300);
await run("c7.log", async () => { const answer = await mascNetworkLog(p1); return { rows: since(answer, 3).map((row) => ({ url: row.url, urlLength: row.url.length, urlCut: row.urlCut, state: row.state })), leaks: leaks(answer) }; });
// C8: more than the row limit.
await run("c8.fire", () => p1.evaluate(() => window.fire(250, "c8", 10)));
await sleep(500);
await run("c8.log", async () => { const answer = await mascNetworkLog(p1); return { rows: answer.requests.length, dropped: answer.dropped, first: answer.requests[0].url, last: answer.requests.at(-1).url, malformed: answer.malformedEvents, fullBufferReads: answer.fullBufferReads, leaks: leaks(answer) }; });
// C9: a popup.
await run("c9.link", () => p1.evaluate(() => {
  const a = document.createElement("a"); a.id = "pop"; a.target = "_blank"; a.href = "/page?tag=popup"; a.textContent = "pop";
  document.body.appendChild(a); return true;
}));
let popup;
await run("c9.click", async () => { const waiting = p1.waitForEvent("popup"); await p1.click("#pop"); popup = await waiting; return popup.label; });
await run("c9.popupLoad", () => popup.waitForLoadState());
await run("c9.popupLog", async () => (await mascNetworkLog(popup)).requests.map((row) => row.url + " " + row.state));
await run("c9.popupFire", () => popup.evaluate(() => window.fire(1, "c9")));
await sleep(300);
await run("c9.popupLogAfter", async () => (await mascNetworkLog(popup)).requests.map((row) => row.url + " " + row.state));
await run("c9.openerUntouched", async () => since(await mascNetworkLog(p1), 1).map((row) => row.url));
await run("z.finish", () => task.finish({ keep: [] }));
