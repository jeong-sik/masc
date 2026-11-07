open Result.Syntax

(* A tab's network log: at most [requests_limit] requests, oldest first, with
   how many older ones were dropped. An address keeps at most
   [path_bytes_limit] bytes of its path, and a header list at most
   [header_names_limit] names, with their total. The same limits as the
   automation Firefox log the cleanup removed (feac9aa2). *)
let requests_limit = 200
let path_bytes_limit = 500
let header_names_limit = 64
let redacted_value = "REDACTED"
(* ego lite 0.6.2.9 keeps the newest 10,000 events of a Page and drops older
   ones without a word (L8 evidence). A read that drains that many may have
   lost the oldest. *)
let ego_buffer_events = 10_000

let rules = `Assoc ["requests",`Int requests_limit;"pathBytes",`Int path_bytes_limit;
  "headerNames",`Int header_names_limit;"egoBuffer",`Int ego_buffer_events;"redacted",`String redacted_value]

(* ego's Page sessions already have the Network domain on, so page.events()
   holds Network events with no Network.enable (L8 evidence). That buffer is
   one per Page in the SDK process and every drain empties it: the workflow
   events step, native typing and the network read all drain it, so each
   goes through mascPageEvents or mascNetworkLog here. A drain moves the
   Network events into the Page's log, as rows that keep no header value,
   cookie, body or query value, and keeps the rest for the next
   mascPageEvents, so a network read takes no event from the others. *)
let drain_source = {js|function mascPageEventState(page) {
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
}|js}

let script = String.concat "\n" ["const mascNetworkRules = " ^ Yojson.Safe.to_string rules ^ ";"; drain_source]

type names = { listed : string list; total : int }
type outcome =
  | Pending
  | Responded of { status : int; mime_type : string; response_headers : names }
  | Completed of { status : int; mime_type : string; bytes_received : int; response_headers : names }
  | Failed of string
type request = { method_ : string; url : string; url_cut : bool; timestamp : int; request_headers : names; outcome : outcome }
type log = { requests : request list; dropped : int; malformed : int; last_malformed : string option; full_buffer_reads : int }

let shape what = Error ("ego answered " ^ what ^ " in another shape")
let fields_are expected fields =
  let keys = List.map fst fields in
  List.length keys = List.length (List.sort_uniq String.compare keys)
  && List.sort String.compare keys = List.sort String.compare expected

let names_of = function
  | `Assoc ["names",`List items;"total",`Int total] | `Assoc ["total",`Int total;"names",`List items]
    when total >= 0 && List.length items = min total header_names_limit ->
    let listed = List.filter_map (function `String name -> Some name | _ -> None) items in
    if List.length listed = List.length items then Ok {listed; total} else shape "a header name list"
  | _ -> shape "a header name list"

let is_scheme_char c = match c with 'a'..'z' | '0'..'9' | '+' | '-' | '.' -> true | _ -> false

(* The address must already be what the script makes of it: only a scheme,
   or a host with no user, no fragment and every query value replaced. An
   address that is not is refused, not repaired. *)
let redacted_url ~cut text =
  let length = String.length text in
  if length >= 2 && text.[length - 1] = ':' && (match text.[0] with 'a'..'z' -> true | _ -> false)
     && String.for_all is_scheme_char (String.sub text 0 (length - 1)) then
    (if cut then Ok text else shape "a scheme-only address that is not marked cut")
  else
    let uri = Uri.of_string text in
    match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
    | Some _, Some host, None, None
      when host <> "" && List.for_all (fun (_, values) -> List.for_all (String.equal redacted_value) values) (Uri.query uri) ->
      Ok text
    | _ -> shape "an address that keeps a user, a fragment or a query value"

let request_of = function
  | `Assoc fields ->
    let field name = List.assoc_opt name fields in
    let common = ["method";"url";"urlCut";"timestamp";"requestHeaders";"state"] in
    (match field "method", field "url", field "urlCut", field "timestamp", field "requestHeaders", field "state" with
     | Some (`String method_), Some (`String url), Some (`Bool url_cut), Some (`Int timestamp), Some headers, Some (`String state)
       when timestamp >= 0 ->
       let* url = redacted_url ~cut:url_cut url in
       let* request_headers = names_of headers in
       let* outcome = match state with
         | "pending" when fields_are common fields -> Ok Pending
         | "responded" when fields_are (common @ ["status";"mimeType";"responseHeaders"]) fields ->
           (match field "status", field "mimeType", field "responseHeaders" with
            | Some (`Int status), Some (`String mime_type), Some headers ->
              let* response_headers = names_of headers in
              Ok (Responded {status; mime_type; response_headers})
            | _ -> shape "a responded request")
         | "completed" when fields_are (common @ ["status";"mimeType";"bytesReceived";"responseHeaders"]) fields ->
           (match field "status", field "mimeType", field "bytesReceived", field "responseHeaders" with
            | Some (`Int status), Some (`String mime_type), Some (`Int bytes_received), Some headers when bytes_received >= 0 ->
              let* response_headers = names_of headers in
              Ok (Completed {status; mime_type; bytes_received; response_headers})
            | _ -> shape "a completed request")
         | "failed" when fields_are (common @ ["error"]) fields ->
           (match field "error" with Some (`String reason) -> Ok (Failed reason) | _ -> shape "a failed request")
         | _ -> shape "a request state" in
       Ok {method_; url; url_cut; timestamp; request_headers; outcome}
     | _ -> shape "a request")
  | _ -> shape "a request"

let of_json = function
  | `Assoc fields when fields_are ["requests";"dropped";"malformedEvents";"fullBufferReads"] fields ->
    (match List.assoc "requests" fields, List.assoc "dropped" fields, List.assoc "malformedEvents" fields,
           List.assoc "fullBufferReads" fields with
     | `List rows, `Int dropped, `Assoc malformed, `Int full_buffer_reads
       when List.length rows <= requests_limit && dropped >= 0 && full_buffer_reads >= 0
            && fields_are ["count";"last"] malformed ->
       let* malformed, last_malformed = match List.assoc "count" malformed, List.assoc "last" malformed with
         | `Int count, `Null when count = 0 -> Ok (count, None)
         | `Int count, `String reason when count > 0 -> Ok (count, Some reason)
         | _ -> shape "the malformed event count" in
       let* requests = List.fold_right (fun row collected ->
           let* collected = collected in
           let* request = request_of row in
           Ok (request :: collected)) rows (Ok []) in
       Ok {requests; dropped; malformed; last_malformed; full_buffer_reads}
     | _ -> shape "a network log")
  | _ -> shape "a network log"

let names_json {listed; total} = `Assoc ["names",`List (List.map (fun name -> `String name) listed);"total",`Int total]
let request_json {method_; url; url_cut; timestamp; request_headers; outcome} =
  let base = ["method",`String method_;"url",`String url;"urlCut",`Bool url_cut;"timestamp",`Int timestamp;
              "requestHeaders",names_json request_headers] in
  `Assoc (base @ match outcome with
    | Pending -> ["state",`String "pending"]
    | Responded {status; mime_type; response_headers} ->
      ["state",`String "responded";"status",`Int status;"mimeType",`String mime_type;
       "responseHeaders",names_json response_headers]
    | Completed {status; mime_type; bytes_received; response_headers} ->
      ["state",`String "completed";"status",`Int status;"mimeType",`String mime_type;
       "bytesReceived",`Int bytes_received;"responseHeaders",names_json response_headers]
    | Failed reason -> ["state",`String "failed";"error",`String reason])

(* Rebuilt from what was parsed, so a field the script did not name never
   reaches the caller. *)
let to_json ~tab {requests; dropped; malformed; last_malformed; full_buffer_reads} =
  `Assoc ["tabId",`Int tab;"requests",`List (List.map request_json requests);"dropped",`Int dropped;
          "malformedEvents",`Assoc ["count",`Int malformed;"last",(match last_malformed with Some reason -> `String reason | None -> `Null)];
          "fullBufferReads",`Int full_buffer_reads]

let receipt ~tab value = Result.map (to_json ~tab) (of_json value)
