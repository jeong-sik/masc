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
// A console read passes capture: the events of the methods it names are the
// ones its own Runtime.enable caused, so they go to it and not to the rest.
async function mascDrainPage(page, capture) {
  const state = mascPageEventState(page);
  const drained = await page.events();
  if (!Array.isArray(drained)) throw new Error('ego returned a non-array event buffer');
  if (drained.length >= mascNetworkRules.egoBuffer) state.fullBufferReads++;
  for (const event of drained) {
    const method = event !== null && typeof event === 'object' && typeof event.method === 'string' ? event.method : '';
    if (method.startsWith('Network.')) mascRecordNetwork(state, event);
    else if (capture !== undefined && capture.methods.includes(method)) capture.events.push(event);
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
}
const mascConsoleRules = {"entries":200,"textBytes":4000,"answerUnits":2031616};
function mascConsoleArgText(arg) {
  if (arg === null || typeof arg !== 'object' || typeof arg.type !== 'string') return null;
  if (arg.type === 'string') return typeof arg.value === 'string' ? arg.value : null;
  if (arg.type === 'undefined') return 'undefined';
  if (typeof arg.description === 'string') return arg.description;
  if (typeof arg.unserializableValue === 'string') return arg.unserializableValue;
  if ('value' in arg) return String(arg.value);
  return null;
}
// A text keeps at most textBytes UTF-8 bytes and is cut where a character
// starts; the round trip also turns a lone surrogate into U+FFFD.
function mascConsoleCut(text) {
  const bytes = new TextEncoder().encode(text);
  let end = bytes.length, cut = false;
  if (end > mascConsoleRules.textBytes) {
    end = mascConsoleRules.textBytes;
    while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
    cut = true;
  }
  return {text: new TextDecoder().decode(bytes.subarray(0, end)), cut};
}
// The arguments are joined by a space as CDP describes them; a format
// specifier such as %s is not applied.
function mascConsoleEntry(event) {
  const params = event.params;
  if (params === null || typeof params !== 'object' || typeof params.timestamp !== 'number' || !Number.isFinite(params.timestamp))
    return {malformed: 'no timestamp'};
  let kind, level, parts;
  if (event.method === 'Runtime.consoleAPICalled') {
    if (typeof params.type !== 'string' || params.type === '' || !Array.isArray(params.args)) return {malformed: 'no type or args'};
    kind = 'console'; level = params.type; parts = params.args.map(mascConsoleArgText);
  } else {
    const details = params.exceptionDetails;
    if (details === null || typeof details !== 'object' || typeof details.text !== 'string') return {malformed: 'no exceptionDetails text'};
    kind = 'javascript'; level = 'error';
    parts = details.exception === undefined ? [details.text] : [details.text, mascConsoleArgText(details.exception)];
  }
  if (parts.includes(null)) return {malformed: 'an argument CDP does not describe'};
  const text = mascConsoleCut(parts.join(' '));
  return {entry: {type: kind, level, text: text.text, textCut: text.cut, timestamp: Math.floor(params.timestamp)}};
}
async function mascConsoleRead(page, reason) {
  const capture = {methods: ['Runtime.consoleAPICalled', 'Runtime.exceptionThrown', 'Runtime.executionContextCreated',
    'Runtime.executionContextDestroyed', 'Runtime.executionContextsCleared'], events: []};
  try { await mascDrainPage(page); }
  catch (error) { return {ok: false, before: true, error: "the tab's events were not read: " + reason(error)}; }
  const offAt = Date.now();
  try { await page.cdp('egoAutomated.disable'); }
  catch (error) { return {ok: false, before: true, error: "ego's console hiding was not turned off: " + reason(error)}; }
  let failure = null, restoreError = null;
  try {
    await page.cdp('Runtime.disable');
    await page.cdp('Runtime.enable');
    await mascDrainPage(page, capture);
  } catch (error) { failure = reason(error); }
  try { await page.cdp('egoAutomated.enable'); } catch (error) { restoreError = reason(error); }
  const offMs = Date.now() - offAt;
  if (failure === null) {
    try { await mascDrainPage(page, capture); } catch (error) { failure = reason(error); }
  }
  // Hiding that is on again leaves nothing changed, so the failure is one
  // before any effect; hiding left off is not.
  if (failure !== null)
    return restoreError === null
      ? {ok: false, before: true, error: "the tab's console was not read: " + failure + "; ego's console hiding was off for " + offMs + " ms and is on again"}
      : {ok: false, error: "the tab's console was not read: " + failure + "; ego's console hiding was not turned back on: " + restoreError};
  const entries = [];
  let malformed = 0, lastMalformed = null;
  for (const event of capture.events) {
    if (event.method !== 'Runtime.consoleAPICalled' && event.method !== 'Runtime.exceptionThrown') continue;
    const read = mascConsoleEntry(event);
    if (read.entry !== undefined) entries.push(read.entry);
    else { malformed++; lastMalformed = event.method + ': ' + read.malformed; }
  }
  // The newest entries go into the answer, within the entry limit and within
  // answerUnits UTF-16 units of JSON, so escaped control characters still
  // cross the connection.
  let units = 0, kept = 0;
  while (kept < entries.length && kept < mascConsoleRules.entries) {
    const size = JSON.stringify(entries[entries.length - 1 - kept]).length + 1;
    if (units + size > mascConsoleRules.answerUnits) break;
    units += size; kept++;
  }
  const hiding = restoreError === null ? {offMs, restored: true} : {offMs, restored: false, error: restoreError};
  return {ok: true, value: {entries: entries.slice(entries.length - kept), dropped: entries.length - kept,
    malformedEvents: {count: malformed, last: lastMalformed}, hiding}};
}
