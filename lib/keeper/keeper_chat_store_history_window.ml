open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_redaction
open Keeper_chat_store_line_decode

(* Window bounds for [load]. [max_history] counts user/assistant
   messages only, so tool lines never shrink the visible conversation
   depth. The rest of [max_total_lines] bounds every other row (tool rows and
   system receipts) so a tool-heavy turn cannot blow up the payload; the
   two together keep the window at or under [max_total_lines]. The bound
   used to be applied to the whole window from its oldest row, which made
   the tool rows shrink the conversation after all: one keeper whose every
   request was answered with a few hundred game-controller tool calls
   carried 388 tool rows in the window, and the 400-row guard left 11 user
   rows and one assistant row of a two-day transcript (msx-retro-mania,
   2026-09-14). Now the oldest tool row goes first and the conversation
   stays. *)
let max_history = 100
let max_total_lines = 400

let is_tool_message (msg : chat_message) = Role.equal msg.role Role.Tool

let is_history_primary (msg : chat_message) =
  Role.equal msg.role Role.User || Role.equal msg.role Role.Assistant
  || Role.equal msg.role Role.Request_failure
;;

(* Old rows without either causal identity can become unrenderable when a
   window evicts their owning user row. Current tool-only continuations carry
   [turn_ref] or idempotent [delivery_provenance] and remain valid even when they
   are the first retained row. *)
let drop_leading_orphan_tool_messages messages =
  let rec split anonymous_tools = function
    | ({ turn_ref = None; delivery_provenance = None; _ } as msg) :: rest
      when is_tool_message msg ->
      split (msg :: anonymous_tools) rest
    | rest -> List.rev anonymous_tools, rest
  in
  match split [] messages with
  | [], _ -> messages
  | anonymous_tools,
    ({ role = Role.Request_failure; _ } :: _ as rest) ->
    (* Failure persistence is one ordered batch: tool rows followed by its
       typed terminal assistant row. The user row may already have been
       persisted upstream or may fall just outside this page, so the terminal
       marker—not a guessed missing parent—proves these leading rows belong. *)
    anonymous_tools @ rest
  | _ :: _,
    (([] | { role = Role.User | Role.Assistant | Role.System | Role.Tool; _ } :: _) as rest) ->
    rest

(* RFC-0226 P2: [load] serves a fixed window ([max_total_lines]) but
   used to read and JSON-parse the whole file to build it, so its cost
   scaled with lane size — the same pathology family as the
   2026-06-09 telemetry-JSONL incident (multi-MB files starving the
   Eio domain). Read a bounded tail instead: [max_total_lines] lines
   at ~10 KiB each leaves wide slack over the gate's 4 KB content
   bound. A tail whose recent lines are larger (attachment payloads)
   degrades to a shorter window, never to an error or a full scan. *)
let tail_read_bytes = 4 * 1024 * 1024

(* RFC-0228 P1: binary-search probes for [before]-paging are tiny
   bounded reads; a probe only needs to span a handful of lines. A
   probe landing inside an oversized line degrades the cut estimate
   (shorter window), never correctness — the final ts filter discards
   overshoot rows. *)
let probe_bytes = 256 * 1024

type page = { messages : chat_message list; has_more : bool }

(* One row of [load_page]'s running window. *)
type window_row =
  { message : chat_message
  ; mutable in_window : bool
  }

(* Both permissive runtime reads and strict HTTP reads use this exact window
   selection. Each queue drops marked rows lazily, preserving linear work even
   when one turn has many tool rows. *)
let history_window ~window_history ~window_secondary =
  let rows : window_row Queue.t = Queue.create () in
  let secondaries : window_row Queue.t = Queue.create () in
  let primary_count = ref 0 in
  let secondary_count = ref 0 in
  let evicted = ref false in
  let rec take_first_kept queue =
    let row = Queue.pop queue in
    if row.in_window then row else take_first_kept queue
  in
  let pop_front () =
    evicted := true;
    let row = take_first_kept rows in
    row.in_window <- false;
    if is_history_primary row.message then decr primary_count else decr secondary_count
  in
  let drop_oldest_secondary () =
    evicted := true;
    let row = take_first_kept secondaries in
    row.in_window <- false;
    decr secondary_count
  in
  let push msg =
    let row = { message = msg; in_window = true } in
    Queue.push row rows;
    if is_history_primary msg then incr primary_count
    else (incr secondary_count; Queue.push row secondaries);
    while !primary_count > window_history do pop_front () done;
    while !secondary_count > window_secondary do drop_oldest_secondary () done
  in
  let finish () =
    let messages =
      Queue.fold
        (fun acc row -> if row.in_window then row.message :: acc else acc)
        [] rows
      |> List.rev
      |> drop_leading_orphan_tool_messages
    in
    messages, !evicted
  in
  push, finish

(* Lines of the byte slice [[from, upto)). When [from > 0] the first
   element is a (potentially partial) line fragment — dropped, same
   rationale as the RFC-0226 P2 tail read. A final element without a
   terminating '\n' (mid-line [upto], or a writer-in-flight tail) is
   dropped the same way; split yields [""] there for boundary cuts, so
   only true fragments are removed. *)
let slice_lines ~path ~from ~upto : string list =
  if upto <= from then []
  else
    let slice = Fs_compat.read_slice ~path ~from ~len:(upto - from) in
    let lines = String.split_on_char '\n' slice in
    let lines = match lines with _ :: rest when from > 0 -> rest | l -> l in
    match List.rev lines with
    | last :: rev_rest when last <> "" -> List.rev rev_rest
    | _ -> lines

(* Metric-quiet ts extractor for probes: probed lines are re-read by
   the real parse later, so a malformed row must not double-count in
   the read-drop metrics. *)
let quiet_line_ts line : float option =
  try
    match Json_util.assoc_member_opt "ts" (Yojson.Safe.from_string line) with
    | Some (`Float f) -> Some f
    | _ -> None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None

let probe_ts ~path ~size pos : float option =
  let upto = min size (pos + probe_bytes) in
  List.find_map
    (fun line ->
      let trimmed = String.trim line in
      if trimmed = "" then None else quiet_line_ts trimmed)
    (slice_lines ~path ~from:pos ~upto)

(* Largest prefix [[0, cut)) holding only lines with ts < [before].
   Append-only wall-clock stamps make line ts monotone in byte offset,
   so this is a plain byte-offset binary search: ~log2(size/probe)
   probes, each bounded. The returned cut overshoots by at most one
   probe window; callers filter by ts. *)
let find_cut ~path ~size ~before : int =
  let lo = ref 0 and hi = ref size in
  while !hi - !lo > probe_bytes do
    let mid = !lo + ((!hi - !lo) / 2) in
    match probe_ts ~path ~size mid with
    | Some t when t < before -> lo := mid
    | Some _ | None -> hi := mid
  done;
  !hi

let load_page ~base_dir ~keeper_name ?before ?(max_total = max_total_lines) () : page =
  (* [max_total] scales only the user/assistant share of the window. The
     budget for tool rows and receipts stays at its full size: paging runs
     backwards and a row pushed out of one page by that budget is older than
     nothing the next page reads (its cursor is the oldest row returned), so a
     smaller tool budget would drop those rows from every page. A small page
     therefore narrows the conversation, never the tool rows a turn kept. *)
  let max_total = max 1 (min max_total max_total_lines) in
  let window_history = max 1 (max_history * max_total / max_total_lines) in
  let window_secondary = max_total_lines - max_history in
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then { messages = []; has_more = false }
  else
  try
    let size = Option.value (Fs_compat.file_size path) ~default:0 in
    let upto, keep =
      match before with
      | None -> (size, fun (_ : chat_message) -> true)
      | Some b ->
          (find_cut ~path ~size ~before:b, fun (m : chat_message) -> m.ts < b)
    in
    let from = if upto > tail_read_bytes then upto - tail_read_bytes else 0 in
    let push, finish = history_window ~window_history ~window_secondary in
    List.iter
      (fun line ->
        let trimmed = String.trim line in
        if trimmed <> "" then
          match parse_line ~file_path:path trimmed with
          | Some msg when keep msg -> push msg
          | Some _ | None -> ())
      (slice_lines ~path ~from ~upto);
    let messages, evicted = finish () in
    let redaction = redaction_for ~base_dir ~keeper_name in
    { messages = List.map (redact_message redaction) messages
    ; has_more = from > 0 || evicted }
  with
  | Sys_error detail ->
      report_persistence_read_drop
        ~reason:Read_drop_reason.Entry_load_error
        ~path
        ~detail;
      { messages = []; has_more = false }
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ChatStoreFailures)
        ~labels:[("operation", Keeper_chat_store_operation.(to_label Load))]
        ();
      Log.Keeper.warn "keeper_chat_store: load failed for %s: %s"
        (sanitize_name keeper_name) (Printexc.to_string exn);
      { messages = []; has_more = false }

let load ~base_dir ~keeper_name : chat_message list =
  (load_page ~base_dir ~keeper_name ()).messages
