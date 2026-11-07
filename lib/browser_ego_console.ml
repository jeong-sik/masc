open Result.Syntax

(* A console read answers at most [entries_limit] entries, newest kept, and
   cuts each text at [text_bytes_limit] bytes: the limits of the automation
   Firefox read the cleanup removed (feac9aa2). *)
let entries_limit = 200
let text_bytes_limit = 4000
(* The browser keeps the newest 1,000 console entries of a document and
   drops older ones without a count (L9 evidence a9). *)
let browser_kept_entries = 1000
(* Room in the answer for what is not an entry: the counts, the hiding
   window and its error. *)
let fields_units = 65_536

let rules ~answer_units = `Assoc ["entries",`Int entries_limit;"textBytes",`Int text_bytes_limit;
  "answerUnits",`Int (answer_units - fields_units)]

(* ego's Page sessions hide console messages from CDP: with the hiding on,
   Runtime.consoleAPICalled never arrives, Runtime on or not. The browser
   still stores what the document writes, and Runtime.enable replays the
   stored entries, uncaught errors included, but only when Runtime was off:
   native typing leaves it on, so the read turns it off first (L9 evidence
   a2, a3). The hiding is per Page and comes back with a new SDK process
   (b1, b2). The read turns it off, replays, and turns it back on in one
   step, and says how long it was off; sites can detect automation in that
   window. Runtime stays on afterwards, as native typing leaves it; with the
   hiding on no console line reaches CDP. The events the replay caused go to
   this read through the shared drain's capture, not to the next workflow
   events step. *)
let read_source = {js|function mascConsoleArgText(arg) {
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
  // Replayed events still on their way when the hiding came back on are
  // taken by a second drain.
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
}|js}

let script ~answer_units =
  String.concat "\n" ["const mascConsoleRules = " ^ Yojson.Safe.to_string (rules ~answer_units) ^ ";"; read_source]

type kind = Console | Javascript
type entry = { kind : kind; level : string; text : string; text_cut : bool; timestamp : int }
type hiding = Restored of { off_ms : int } | Left_off of { off_ms : int; error : string }
type read = { entries : entry list; dropped : int; malformed : int; last_malformed : string option; hiding : hiding }

let shape what = Error ("ego answered " ^ what ^ " in another shape")
let fields_are expected fields =
  let keys = List.map fst fields in
  List.length keys = List.length (List.sort_uniq String.compare keys)
  && List.sort String.compare keys = List.sort String.compare expected

let kind_to_wire = function Console -> "console" | Javascript -> "javascript"

let entry_of = function
  | `Assoc fields when fields_are ["type";"level";"text";"textCut";"timestamp"] fields ->
    (match List.assoc "type" fields, List.assoc "level" fields, List.assoc "text" fields,
           List.assoc "textCut" fields, List.assoc "timestamp" fields with
     | `String kind, `String level, `String text, `Bool text_cut, `Int timestamp
       when level <> "" && timestamp >= 0 && String.length text <= text_bytes_limit && String.is_valid_utf_8 text ->
       (match kind, level with
        | "console", _ -> Ok {kind = Console; level; text; text_cut; timestamp}
        | "javascript", "error" -> Ok {kind = Javascript; level; text; text_cut; timestamp}
        | _ -> shape "a console entry kind")
     | _ -> shape "a console entry")
  | _ -> shape "a console entry"

let hiding_of = function
  | `Assoc fields when fields_are ["offMs";"restored"] fields ->
    (match List.assoc "offMs" fields, List.assoc "restored" fields with
     | `Int off_ms, `Bool true when off_ms >= 0 -> Ok (Restored {off_ms})
     | _ -> shape "the console hiding window")
  | `Assoc fields when fields_are ["offMs";"restored";"error"] fields ->
    (match List.assoc "offMs" fields, List.assoc "restored" fields, List.assoc "error" fields with
     | `Int off_ms, `Bool false, `String error when off_ms >= 0 -> Ok (Left_off {off_ms; error})
     | _ -> shape "the console hiding window")
  | _ -> shape "the console hiding window"

let of_json = function
  | `Assoc fields when fields_are ["entries";"dropped";"malformedEvents";"hiding"] fields ->
    (match List.assoc "entries" fields, List.assoc "dropped" fields, List.assoc "malformedEvents" fields with
     | `List rows, `Int dropped, `Assoc malformed
       when List.length rows <= entries_limit && dropped >= 0 && fields_are ["count";"last"] malformed ->
       let* malformed, last_malformed = match List.assoc "count" malformed, List.assoc "last" malformed with
         | `Int count, `Null when count = 0 -> Ok (count, None)
         | `Int count, `String reason when count > 0 -> Ok (count, Some reason)
         | _ -> shape "the malformed event count" in
       let* entries = List.fold_right (fun row collected ->
           let* collected = collected in
           let* entry = entry_of row in
           Ok (entry :: collected)) rows (Ok []) in
       let* hiding = hiding_of (List.assoc "hiding" fields) in
       Ok {entries; dropped; malformed; last_malformed; hiding}
     | _ -> shape "a console read")
  | _ -> shape "a console read"

let left_off_note =
  "ego's console hiding for this tab is still off, so sites can detect automation; \
   it comes back with the next console read or when the ego SDK process ends (sdkProcessStartedAt changes)"

let entry_json {kind; level; text; text_cut; timestamp} =
  `Assoc ["type",`String (kind_to_wire kind);"level",`String level;"text",`String text;
          "textCut",`Bool text_cut;"timestamp",`Int timestamp]

let hiding_json = function
  | Restored {off_ms} -> `Assoc ["offMs",`Int off_ms;"restored",`Bool true]
  | Left_off {off_ms; error} ->
    `Assoc ["offMs",`Int off_ms;"restored",`Bool false;"error",`String error;"note",`String left_off_note]

(* Rebuilt from what was parsed, so a field the script did not name never
   reaches the caller. *)
let to_json ~tab {entries; dropped; malformed; last_malformed; hiding} =
  `Assoc ["tabId",`Int tab;"entries",`List (List.map entry_json entries);"dropped",`Int dropped;
          "malformedEvents",`Assoc ["count",`Int malformed;"last",(match last_malformed with Some reason -> `String reason | None -> `Null)];
          "hiding",hiding_json hiding]

let receipt ~tab value = Result.map (to_json ~tab) (of_json value)
