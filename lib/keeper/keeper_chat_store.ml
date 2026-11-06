(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"id":"msg-...","role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines (persisted between the user and assistant lines of a
    turn) carry the executed tool name and accumulated arguments:
    {v {"id":"msg-...","role":"tool","content":"{\"path\":\"x\"}","ts":...,
        "tool_call_id":"toolu_1","tool_call_name":"Read",
        "surface":{"kind":"dashboard"}} v}

    Connector rows may additionally carry opaque route coordinates:
    [conversation_id] for channel/thread grouping and [external_message_id]
    for the inbound platform message. The store does not interpret these
    values.

    @since 2.145.0 *)

open Keeper_approval_lifecycle

include Keeper_chat_types

open Keeper_chat_projection
include Keeper_chat_store_paths
include Keeper_chat_store_redaction
include Keeper_chat_store_row_codec
include Keeper_chat_store_delivery_rules
include Keeper_chat_store_provenance_index
include Keeper_chat_store_append_primitives
include Keeper_chat_store_turn_append
include Keeper_chat_store_append_once
include Keeper_chat_store_message_append

type strict_decode_cause =
  | Invalid_surface of string
  | Unknown_speaker_authority of string
  | Missing_speaker_authority
  | Invalid_row_contract of string
  | Unreadable_file of string

type strict_decode_error =
  { location : string
  ; cause : strict_decode_cause
  }

let strict_decode_error_to_string { location; cause } =
  match cause with
  | Invalid_surface detail ->
    Printf.sprintf "%s invalid surface field: %s" location detail
  | Unknown_speaker_authority label ->
    Printf.sprintf "%s unknown speaker_authority %S" location label
  | Missing_speaker_authority ->
    Printf.sprintf "%s speaker_id/speaker_name without speaker_authority" location
  | Invalid_row_contract detail -> Printf.sprintf "%s %s" location detail
  | Unreadable_file detail -> detail

type parsed_line =
  { message : chat_message option
  ; strict_decode_error : strict_decode_cause option
  }

let parse_line_decoded ~file_path (line : string) : parsed_line =
  try
    let json = Yojson.Safe.from_string line in
    let role_label =
      Json_util.get_string_with_default json ~key:"role" ~default:""
    in
    let content = Json_util.get_string_with_default json ~key:"content" ~default:"" in
    let ts =
      match Json_util.assoc_member_opt "ts" json with
      | Some (`Float f) -> Some f
      | Some _ | None -> None
    in
    let opt_string key =
      match Json_util.assoc_member_opt key json with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None
    in
    let tool_call_id = opt_string "tool_call_id" in
    let execution_id_result =
      match json with
      | `Assoc fields -> execution_id_of_fields fields
      | _ -> Ok None
    in
    let execution_id =
      match execution_id_result with
      | Ok execution_id -> execution_id
      | Error _ -> None
    in
    let tool_call_name = opt_string "tool_call_name" in
    let surface, surface_error =
      match Json_util.assoc_member_opt "surface" json with
      | None -> None, None
      | Some surface_json -> (
          match Surface_ref.of_json surface_json with
          | Ok s -> Some s, None
          | Error detail ->
              (* A persisted surface is the row's only typed routing
                 identity. One that does not decode cannot be read as
                 "no surface": that would move a connector message into
                 unscoped global history. Both readers refuse the row —
                 the permissive reader drops it (counted here as a read
                 drop), the strict reader stops at it. *)
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid surface field: %s" detail);
              None, Some (Invalid_surface detail))
    in
    let conversation_id = opt_string "conversation_id" in
    let external_message_id = opt_string "external_message_id" in
    let workspace_id = opt_string "workspace_id" in
    let speaker, speaker_error =
      let speaker_id = opt_string "speaker_id" in
      let speaker_name = opt_string "speaker_name" in
      match opt_string "speaker_authority" with
      | Some label -> (
          match authority_of_label label with
          | Some speaker_authority ->
              Some { speaker_id; speaker_name; speaker_authority }, None
          | None ->
              (* Unknown authority label: surface it instead of guessing
                 a class; the row itself stays valid. *)
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:
                  (Printf.sprintf "unknown speaker_authority %S" label);
              None, Some (Unknown_speaker_authority label))
      | None ->
          (match speaker_id, speaker_name with
           | None, None -> None, None
           | _ ->
               (* id/name without an authority class never comes from our
                  writer; report so the producer gets fixed. *)
               report_persistence_read_drop
                 ~reason:Read_drop_reason.Invalid_payload
                 ~path:file_path
                 ~detail:"speaker_id/speaker_name without speaker_authority";
               None, Some Missing_speaker_authority)
    in
    let strict_decode_error =
      match surface_error with
      | Some _ -> surface_error
      | None -> speaker_error
    in
    let audio =
      match Json_util.assoc_member_opt "audio" json with
      | Some (`Assoc fields) ->
          let get k =
            match List.assoc_opt k fields with
            | Some (`String s) -> Some s
            | _ -> None
          in
          (match get "token", get "mime" with
           | Some token, Some mime ->
               let duration_sec =
                 match List.assoc_opt "duration_sec" fields with
                 | Some (`Float f) -> Some f
                 | _ -> None
               in
               let message_text = Option.value (get "message_text") ~default:"" in
               let audio_url = get "audio_url" in
               let device_id = get "device_id" in
               let expired =
                 match List.assoc_opt "expired" fields with
                 | Some (`Bool b) -> b
                 | _ -> false
               in
               Some { token; audio_url; mime; duration_sec; message_text; device_id; expired }
           | _ ->
               (* audio without token+mime is malformed; drop the field but
                  keep the row (text-only render). *)
               report_persistence_read_drop
                 ~reason:Read_drop_reason.Invalid_payload
                 ~path:file_path
                 ~detail:"audio field missing token/mime";
               None)
      | _ -> None
    in
    let attachments =
      match Json_util.assoc_member_opt "attachments" json with
      | Some (`List att_list) ->
          let atts = List.filter_map (fun att_json ->
            match att_json with
            | `Assoc _ ->
                (* No guard: Json_util getters absorb type errors into their
                   defaults, so this body is total — the catch that wrapped it
                   could only hide asynchronous exceptions. *)
                let id = Json_util.get_string_with_default att_json ~key:"id" ~default:"" in
                let att_type = Json_util.get_string_with_default att_json ~key:"type" ~default:"" in
                let name = Json_util.get_string_with_default att_json ~key:"name" ~default:"" in
                let size = (match Json_util.assoc_member_opt "size" att_json with
                  | Some (`Int i) -> i | _ -> 0) in
                let mime_type = Json_util.get_string_with_default att_json ~key:"mime_type" ~default:"" in
                let data = Json_util.get_string_with_default att_json ~key:"data" ~default:"" in
                let int_of key = (match Json_util.assoc_member_opt key att_json with
                  | Some (`Int i) when i >= 0 -> Some i | _ -> None) in
                if id = "" || data = "" then None
                else Some
                  { id; att_type; name; size; mime_type; data
                  ; width = int_of "width"; height = int_of "height" }
            | _ -> None
          ) att_list in
          if atts = [] then None else Some atts
      | _ -> None
    in
    let mentions =
      (* Absent field = pre-P4 row or no mentions; both read as [].
         Entries that cannot mint an id are reported and skipped — the
         row itself stays valid (losing one malformed mention must not
         drop the whole line from the lane). *)
      match Json_util.assoc_member_opt "mentions" json with
      | None -> []
      | Some (`List items) ->
          List.filter_map
            (fun item ->
              match item with
              | `String value -> (
                  match Keeper_identity.Keeper_id.of_string value with
                  | Some _ as id -> id
                  | None ->
                      report_persistence_read_drop
                        ~reason:
                          Read_drop_reason.Invalid_payload
                        ~path:file_path
                        ~detail:
                          (Printf.sprintf "empty mention entry %S" value);
                      None)
              | _ ->
                  report_persistence_read_drop
                    ~reason:
                      Read_drop_reason.Invalid_payload
                    ~path:file_path
                    ~detail:"non-string mention entry";
                  None)
            items
      | Some _ ->
          report_persistence_read_drop
            ~reason:Read_drop_reason.Invalid_payload
            ~path:file_path
            ~detail:"mentions field is not a list";
          []
    in
    let blocks =
      match Json_util.assoc_member_opt "blocks" json with
      | None -> None
      | Some blocks_json -> (
          match Keeper_chat_blocks.blocks_of_yojson blocks_json with
          | Some _ as blocks -> blocks
          | None ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:"invalid blocks field";
              None)
    in
    let contract_result = match json with
      | `Assoc fields -> validate_row_fields fields
      | _ -> Error "chat row must be an object" in
    let strict_decode_error = match contract_result with
      | Ok () -> strict_decode_error
      | Error detail ->
        report_persistence_read_drop ~reason:Read_drop_reason.Invalid_payload
          ~path:file_path ~detail;
        Some (Invalid_row_contract detail)
    in
    let turn_ref =
      (* RFC-0233 §7: parse the join key; a malformed value is surfaced as
         a read drop and reads as [None] — never repaired. *)
      match opt_string "turn_ref" with
      | None -> None
      | Some s -> (
          match Ids.Turn_ref.of_string s with
          | Some _ as tr -> tr
          | None ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid turn_ref %S" s);
              None)
    in
    let stream_lifecycle =
      match Json_util.assoc_member_opt "stream_lifecycle" json with
      | None -> None
      | Some stream_lifecycle_json ->
          parse_stream_lifecycle ~path:file_path stream_lifecycle_json
    in
    let approval_lifecycle =
      match Json_util.assoc_member_opt "approval_lifecycle" json with
      | None -> None
      | Some lifecycle_json ->
        parse_approval_lifecycle ~path:file_path lifecycle_json
    in
    let delivery_provenance =
      (* Same read-drop convention as [turn_ref]: a malformed persisted
         value is surfaced and reads as [None] — the row stays valid.
         This reader only renders, so it can carry on without the
         provenance; [provenance_of_line] decodes the same pair through
         the same function but must fail its transaction instead, because
         a skipped row there would answer "not appended yet" for a
         delivery that is already on disk. *)
      match json with
      | `Assoc fields -> (
          match
            Keeper_chat_delivery_identity.delivery_provenance_of_fields fields
          with
          | Ok None -> None
          | Ok (Some provenance) -> Some provenance
          | Error detail ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid delivery provenance: %s" detail);
              None)
      | _ -> None
    in
    let delivery_execution_identity_valid =
      match delivery_provenance with
      | Some provenance ->
        (match validate_delivery_role ~role_label provenance with
         | Error detail ->
           report_persistence_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path:file_path
             ~detail:(Printf.sprintf "invalid delivery row role: %s" detail);
           false
         | Ok () ->
           (match execution_id_result with
            | Error detail ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid execution identity: %s" detail);
              false
            | Ok execution_id ->
              (match
                 validate_delivery_execution_identity
                   ~execution_id
                   delivery_provenance
               with
               | Ok () -> true
               | Error detail ->
                 report_persistence_read_drop
                   ~reason:Read_drop_reason.Invalid_payload
                   ~path:file_path
                   ~detail:
                     (Printf.sprintf
                        "invalid delivery execution identity: %s"
                        detail);
                 false)))
      | None ->
        (match execution_id_result with
         | Ok _ -> true
         | Error detail ->
          report_persistence_read_drop
            ~reason:Read_drop_reason.Invalid_payload
            ~path:file_path
            ~detail:(Printf.sprintf "invalid execution identity: %s" detail);
          false)
    in
    let has_structured_payload =
      Option.is_some audio
      || Option.exists (fun values -> values <> []) attachments
      || Option.exists (fun values -> values <> []) blocks
      (* A Gate lifecycle row's payload is its typed phase. The store used to
         compose a sentence beside it, so the row also had text and passed
         here by accident; with the sentence gone the row is all typed field,
         and dropping it would delete the durable record of an external
         effect on read. *)
      || Option.is_some approval_lifecycle
    in
    let message =
      if Option.is_some surface_error then None
      else if not delivery_execution_identity_valid then None
      else if role_label = "" || (content = "" && not has_structured_payload) then (
        report_persistence_read_drop
          ~reason:Read_drop_reason.Invalid_payload
          ~path:file_path
          ~detail:"chat row missing role and readable text/structured payload";
        None)
      else
        match contract_result, Role.of_label role_label with
        | Error _, _ -> None
        | Ok _, None ->
            (* RFC-0232 P1: an unknown role cannot participate in any lane
               semantics (watermark, pending, rendering); surface it
               instead of carrying an untyped row. *)
            report_persistence_read_drop
              ~reason:Read_drop_reason.Invalid_payload
              ~path:file_path
              ~detail:(Printf.sprintf "unknown chat row role %S" role_label);
            None
        | Ok _, Some Role.Tool when tool_call_name = None ->
            report_persistence_read_drop
              ~reason:Read_drop_reason.Invalid_payload
              ~path:file_path
              ~detail:"tool chat row missing non-empty tool_call_name";
            None
        | Ok (),
          Some
            (( Role.User
             | Role.Assistant
             | Role.System
             | Role.Request_failure
             | Role.Tool ) as role) ->
            (match opt_string "id", ts with
             | None, _ ->
                 report_persistence_read_drop
                   ~reason:Read_drop_reason.Invalid_payload
                   ~path:file_path
                   ~detail:"chat row missing nonblank id";
                 None
             | Some _, None ->
                 (* [encode_line] always writes a float [ts]; a row without one
                    cannot be ordered, paged or joined, so it is dropped. *)
                 report_persistence_read_drop
                   ~reason:Read_drop_reason.Invalid_payload
                   ~path:file_path
                   ~detail:"chat row missing float ts";
                 None
             | Some id, Some ts ->
                 Some
                   { id; role; content; ts; attachments; tool_call_id; execution_id;
                     tool_call_name; surface; conversation_id;
                     external_message_id; workspace_id; speaker; audio; blocks;
                     mentions; turn_ref; stream_lifecycle; approval_lifecycle;
                     delivery_provenance })
    in
    { message; strict_decode_error }
  with Yojson.Json_error detail ->
    report_persistence_read_drop
      ~reason:Read_drop_reason.Json_syntax_error
      ~path:file_path
      ~detail;
    { message = None; strict_decode_error = None }

let parse_line ~file_path line =
  (parse_line_decoded ~file_path line).message
;;

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

(* ── Transcript cache (RFC main-domain-scheduler-latency §8.8, P4k) ────
   [load_all] used to read the whole transcript, parse every row and redact
   every message on the calling fiber, on every keeper wake: 1.7-3.5 MB and
   2,000-3,700 rows per keeper on the live root, and the regex passes of the
   redaction alone were 19% of the main domain's busy time (2026-09-05).
   The transcript is append-only — the store's one writer appends under the
   private JSONL lock — so a load parses only the rows past the last parsed
   row boundary and appends them to what was parsed before. The cache is per
   path and holds while the file keeps its identity (device, inode), has not
   shrunk below the parsed boundary, and the redaction snapshot the messages
   were redacted with is the one in force ([redaction_for] hands back the
   same value while the secret sources are unchanged). Anything else, and a
   torn tail, reload the whole transcript through the rows reader. Parsing
   and redaction run on the domain pool when one is installed. *)
type transcript_cache =
  { device : int
  ; inode : int
  ; parsed_end : int  (** Offset just past the last parsed ['\n']-terminated row. *)
  ; messages_rev : chat_message list  (** Newest first. *)
  ; redaction : Keeper_secret_redaction.t
  }

let transcript_caches : (string, transcript_cache) Hashtbl.t = Hashtbl.create 16
let transcript_caches_mu = Stdlib.Mutex.create ()

let remember_transcript path cache =
  Stdlib.Mutex.protect transcript_caches_mu (fun () ->
    Hashtbl.replace transcript_caches path cache)
;;

let forget_transcript path =
  Stdlib.Mutex.protect transcript_caches_mu (fun () -> Hashtbl.remove transcript_caches path)
;;

let transcript_identity path =
  match Unix.stat path with
  | st -> Some (st.Unix.st_dev, st.Unix.st_ino, st.Unix.st_size)
  | exception Unix.Unix_error _ -> None
;;

let parse_transcript_row_permissive ~path ~redaction line =
  let trimmed = String.trim line in
  if String.equal trimmed ""
  then None
  else (
    let decoded = parse_line_decoded ~file_path:path trimmed in
    Option.map (redact_message redaction) decoded.message)
;;

type transcript_position = Line_number of int | Byte_offset of int

let parse_transcript_row_strict ~path ~redaction ~position line =
  let location = match position with
    | Line_number line -> Printf.sprintf "%s:%d" path line
    | Byte_offset offset -> Printf.sprintf "%s at byte %d" path offset in
  let trimmed = String.trim line in
  if String.equal trimmed ""
  then `Blank
  else
    match parse_line_decoded ~file_path:path trimmed with
        | { strict_decode_error = Some cause; _ } ->
      `Unreadable { location; cause }
    | { message = Some message; strict_decode_error = None } ->
      `Message (redact_message redaction message)
    | { message = None; strict_decode_error = None } ->
      `Unreadable { location; cause = Invalid_row_contract "unreadable chat row" }
;;

let parse_transcript_rows ~path ~redaction rows =
  rows
  |> String.split_on_char '\n'
  |> List.filter_map (parse_transcript_row_permissive ~path ~redaction)
;;

type captured_row = { raw_line : string; projected_line : string; captured_message : chat_message }

let captured_row_message row = row.captured_message
let captured_row_same_source left right = String.equal left.raw_line right.raw_line
let captured_row_to_json row =
  `Assoc ["raw_line", `String row.raw_line; "projected_line", `String row.projected_line]

let redacted_row_fields = ["content"; "attachments"; "blocks"; "audio"; "approval_lifecycle"]

let projected_row_line raw_line (message : chat_message) =
  let encoded = encode_line ~role:message.role ~content:message.content ~ts:message.ts
      ~message_id:message.id ?attachments:message.attachments ?tool_call_id:message.tool_call_id
      ?execution_id:message.execution_id ?tool_call_name:message.tool_call_name
      ?surface:message.surface ?conversation_id:message.conversation_id
      ?external_message_id:message.external_message_id ?workspace_id:message.workspace_id
      ?speaker:message.speaker ?audio:message.audio ?blocks:message.blocks
      ~mentions:message.mentions ?turn_ref:message.turn_ref
      ?stream_lifecycle:message.stream_lifecycle ?approval_lifecycle:message.approval_lifecycle
      ?provenance:message.delivery_provenance () |> Yojson.Safe.from_string in
  match Yojson.Safe.from_string raw_line, encoded with
  | `Assoc raw, `Assoc fields ->
    `Assoc (List.map (fun (key, value) ->
      key, if List.mem key redacted_row_fields then
        (match List.assoc_opt key fields with Some redacted -> redacted | None -> value)
      else value) raw) |> Yojson.Safe.to_string
  | _ -> raw_line
;;

let captured_row_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["projected_line";"raw_line"] ->
    (match List.assoc "raw_line" fields, List.assoc "projected_line" fields with
     | `String raw_line, `String projected_line ->
       let decode line =
         try
           let value = Yojson.Safe.from_string line in
           match value with
           | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) ->
             (match parse_transcript_row_strict ~path:"captured chat row"
                ~redaction:Keeper_secret_redaction.empty ~position:(Line_number 1) line with
              | `Message message when Float.is_finite message.ts -> Ok (fields, message)
              | `Message _ -> Error "captured chat timestamp is not finite"
              | `Blank -> Error "blank captured chat row"
              | `Unreadable error -> Error (strict_decode_error_to_string error))
           | _ -> Error "invalid or duplicate captured chat row fields"
         with Yojson.Json_error detail -> Error detail in
       let open Result.Syntax in
       let* raw_fields, _ = decode raw_line in
       let* projected_fields, captured_message = decode projected_line in
       let immutable fields = List.filter (fun (key, _) -> not (List.mem key redacted_row_fields)) fields in
       if not (Yojson.Safe.equal (`Assoc (immutable raw_fields)) (`Assoc (immutable projected_fields)))
          || List.sort String.compare (List.map fst raw_fields) <> List.sort String.compare (List.map fst projected_fields)
       then Error "captured chat projection changed original identity or field presence"
       else Ok {raw_line; projected_line; captured_message}
     | _ -> Error "captured chat rows must contain original strings")
  | _ -> Error "unexpected captured chat row fields"
;;

let parse_transcript_captures_result ~select ~path ~redaction rows =
  rows
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun state line ->
          let open Result.Syntax in
          let* messages_rev, line_no = state in
          let line_no = line_no + 1 in
          match parse_transcript_row_strict ~path ~redaction ~position:(Line_number line_no) line with
          | `Blank -> Ok (messages_rev, line_no)
          | `Message message when not (Float.is_finite message.ts) ->
            Error {location=Printf.sprintf "%s:%d" path line_no;
              cause=Invalid_row_contract "captured chat timestamp is not finite"}
          | `Message message when not (select message) -> Ok (messages_rev, line_no)
          | `Message message ->
            let projected_line = projected_row_line line message in
            let row = {raw_line=line;projected_line;captured_message=message} in
            (match captured_row_of_json (captured_row_to_json row) with
             | Ok restored when restored.captured_message = message -> Ok (row :: messages_rev, line_no)
             | Ok _ -> Error {location=Printf.sprintf "%s:%d" path line_no;
                 cause=Invalid_row_contract "captured chat projection cannot preserve its complete typed row"}
             | Error detail -> Error {location=Printf.sprintf "%s:%d" path line_no;
                 cause=Invalid_row_contract detail})
          | `Unreadable err -> Error err)
       (Ok ([], 0))
  |> Result.map (fun (messages_rev, _line_no) -> List.rev messages_rev)
;;

let parse_transcript_rows_result ~path ~redaction rows =
  rows |> String.split_on_char '\n'
  |> List.fold_left (fun state line ->
    let open Result.Syntax in
    let* messages_rev, line_no = state in
    let line_no = line_no + 1 in
    match parse_transcript_row_strict ~path ~redaction ~position:(Line_number line_no) line with
    | `Blank -> Ok (messages_rev, line_no)
    | `Message message -> Ok (message :: messages_rev, line_no)
    | `Unreadable error -> Error error) (Ok ([], 0))
  |> Result.map (fun (messages_rev, _) -> List.rev messages_rev)
;;

let load_transcript_fully ~path ~redaction =
  let before = transcript_identity path in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Private_file_succeeded Fs_compat.Private_jsonl_rows.Rows_missing
  | Private_file_succeeded_with_cleanup_failure
      { value = Fs_compat.Private_jsonl_rows.Rows_missing; _ } ->
    forget_transcript path;
    []
  | Private_file_succeeded
      (Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset = _ })
  | Private_file_succeeded_with_cleanup_failure
      { value =
          Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset = _ }
      ; _
      } ->
    let messages =
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        parse_transcript_rows ~path ~redaction rows)
    in
    (* Register only when the file the rows came from is the one statted
       before the read: a replacement between the two would pair a new
       identity with old rows, and the next load would append to it. *)
    (match before, transcript_identity path with
     | Some (device, inode, _), Some (device', inode', _)
       when device = device' && inode = inode' ->
       remember_transcript
         path
         { device; inode; parsed_end = rows_end; messages_rev = List.rev messages; redaction }
     | Some _, Some _ | Some _, None | None, Some _ | None, None -> forget_transcript path);
    messages
  | Private_file_failed error
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure = _ } ->
    report_persistence_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:(Fs_compat.Private_jsonl_rows.error_to_string error);
    forget_transcript path;
    []
;;

let load_all ~base_dir ~keeper_name : chat_message list =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then (
    forget_transcript path;
    [])
  else
    let redaction = redaction_for ~base_dir ~keeper_name in
    let cached =
      Stdlib.Mutex.protect transcript_caches_mu (fun () ->
        Hashtbl.find_opt transcript_caches path)
    in
    let continuation =
      match cached, transcript_identity path with
      | Some cache, Some (device, inode, size)
        when cache.device = device
             && cache.inode = inode
             && size >= cache.parsed_end
             && cache.redaction == redaction -> Some cache
      | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
    in
    match continuation with
    | None -> load_transcript_fully ~path ~redaction
    | Some cache ->
      (match Fs_compat.read_private_jsonl_slice_locked_result path ~from:cache.parsed_end with
       | Private_file_succeeded { Fs_compat.Private_jsonl_slice.bytes; end_offset }
       | Private_file_succeeded_with_cleanup_failure
           { value = { Fs_compat.Private_jsonl_slice.bytes; end_offset }; _ } ->
         let fresh =
           if String.equal bytes ""
           then []
           else
             Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
               parse_transcript_rows ~path ~redaction bytes)
         in
         let messages_rev = List.rev_append fresh cache.messages_rev in
         remember_transcript path { cache with parsed_end = end_offset; messages_rev };
         List.rev messages_rev
       | Private_file_failed _ | Private_file_failed_with_cleanup_failure _ ->
         load_transcript_fully ~path ~redaction)

let load_all_using ~base_dir ~keeper_name ~parse_rows =
  let path = chat_path ~base_dir ~keeper_name in
  let redaction = redaction_for ~base_dir ~keeper_name in
  (* The [load_all] cache is permissive: malformed rows are omitted. A strict
     caller must parse the durable file so it cannot advance past such a row. *)
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Private_file_succeeded Fs_compat.Private_jsonl_rows.Rows_missing
  | Private_file_succeeded_with_cleanup_failure
      { value = Fs_compat.Private_jsonl_rows.Rows_missing; _ } -> Ok []
  | Private_file_succeeded
      (Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset })
  | Private_file_succeeded_with_cleanup_failure
      { value =
          Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset }
      ; _
      } ->
    if rows_end < end_offset
    then
      Error
        { location = path
        ; cause =
            Unreadable_file
              (Printf.sprintf
                 "%s incomplete chat tail: complete rows end at byte %d, file ends at byte %d"
                 path
                 rows_end
                 end_offset)
        }
    else parse_rows ~path ~redaction rows
  | Private_file_failed error
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure = _ } ->
    Error
      { location = path
      ; cause =
          Unreadable_file (Fs_compat.Private_jsonl_rows.error_to_string error)
      }

let load_captured_result ~select ~base_dir ~keeper_name =
  load_all_using ~base_dir ~keeper_name ~parse_rows:(parse_transcript_captures_result ~select)

let load_all_result ~base_dir ~keeper_name =
  load_all_using ~base_dir ~keeper_name ~parse_rows:parse_transcript_rows_result

type history_page =
  { history_messages : chat_message list
  ; next_cursor : Keeper_chat_history_page.cursor option
  }

let load_result ~base_dir ~keeper_name =
  let open Result.Syntax in
  let path = chat_path ~base_dir ~keeper_name in
  (* All complete rows inside the existing byte window participate in the
     role-based selection. Taking only 400 physical rows would let a tool-heavy
     tail erase the conversation again. The reader still reads at most 4 MiB. *)
  let* page = Keeper_chat_history_page.read ~path ~owner:keeper_name
      ~max_rows:max_int () in
  let redaction = redaction_for ~base_dir ~keeper_name in
  let push, finish = history_window ~window_history:max_history
      ~window_secondary:(max_total_lines - max_history) in
  let* () =
    List.fold_left (fun state (row : Keeper_chat_history_page.row) ->
      let* () = state in
      match parse_transcript_row_strict ~path ~redaction ~position:(Byte_offset row.offset) row.line with
      | `Blank -> Ok ()
      | `Message message -> push message; Ok ()
      | `Unreadable err ->
        Error (Keeper_chat_history_page.Invalid_row { offset = row.offset; detail = strict_decode_error_to_string err }))
      (Ok ()) page.rows
  in
  Ok (fst (finish ()))

let load_history_page_result ~base_dir ~keeper_name ?cursor
      ?(max_total = max_total_lines) () =
  let open Result.Syntax in
  let path = chat_path ~base_dir ~keeper_name in
  let* page = Keeper_chat_history_page.read ~path ~owner:keeper_name ?cursor
    ~max_rows:(max 1 (min max_total max_total_lines)) () in
  let redaction = redaction_for ~base_dir ~keeper_name in
  let* messages_rev =
    List.fold_left (fun state (row : Keeper_chat_history_page.row) ->
      let* messages = state in
      match parse_transcript_row_strict ~path ~redaction ~position:(Byte_offset row.offset) row.line with
      | `Blank -> Ok messages
      | `Message message -> Ok (message :: messages)
      | `Unreadable err -> Error (Keeper_chat_history_page.Invalid_row { offset = row.offset; detail = strict_decode_error_to_string err }))
      (Ok []) page.rows
  in
  Ok { history_messages = List.rev messages_rev; next_cursor = page.next_cursor }

(* Content equality for the [Already_present] branch of the append-once
   paths: does the row that already holds this approval's slot say the same
   thing as the row we were about to write? Only durable facts take part:
   which approval, which phase, what the replay produced ([artifact_ref]),
   and which tool when both sides know it.

   [call_summary] is deliberately not compared. It is a rendering, not a
   fact: the producing tool states it once from its typed input, on the Gate
   request ([Keeper_gate.request.call_summary]); the request row is written
   with that statement, the store redacts it before writing, and every later
   phase row copies the stored line back ([approval_request_call_summary]).
   The same approval_id therefore never carries two different facts under it,
   and two rows for the same slot differ in it for exactly two reasons that
   are not conflicts: a request row that was never written or carried no
   statement leaves every later copy [None], and the redaction snapshot
   changed between the two writes. Comparing it would turn either into
   "conflicting content" on the append path and into a spurious correction
   row on the replay path. The consequence accepted: a slot first written
   without a summary is not backfilled by a later writer that has one, the
   same way [tool_name] is not. Pinned by
   test/test_keeper_chat_store_approval_summary.ml. *)
let approval_lifecycle_equal left right =
  let artifact_equal left right =
    match left, right with
    | None, None -> true
    | Some left, Some right ->
      String.equal left.Tool_output.sha256 right.Tool_output.sha256
      && Int.equal left.bytes right.bytes
      && String.equal left.mime right.mime
      && String.equal left.preview right.preview
    | None, Some _ | Some _, None -> false
  in
  let tool_name_equal left right =
    match left, right with
    | Some left, Some right -> String.equal left right
    | None, _ | _, None -> true
  in
  String.equal left.approval_id right.approval_id
  && tool_name_equal left.tool_name right.tool_name
  && left.phase = right.phase
  && artifact_equal left.artifact_ref right.artifact_ref
;;

type approval_lifecycle_append =
  | Approval_lifecycle_exact of append_once_result
  | Approval_lifecycle_conflict of approval_lifecycle

let approval_lifecycle_is_replay = function
  | Approval_requested -> false
  | Approval_replay_applied
  | Approval_replay_applied_with_warning
  | Approval_replay_failed
  | Approval_replay_indeterminate -> true
  | Approval_resolved_approved
  | Approval_resolved_rejected
  | Approval_continuation_recorded
  | Approval_continuation_failed -> false
;;

(* The continuation settles once per approval, at the continuation slot:
   recorded when the turn that received the replay completed or durably
   checkpointed, failed when that turn failed after the provider answered.
   Either one is the settlement the intake reads before re-delivering the
   approval (#32956). *)
let approval_lifecycle_is_continuation = function
  | Approval_continuation_recorded
  | Approval_continuation_failed -> true
  | Approval_requested
  | Approval_resolved_approved
  | Approval_resolved_rejected
  | Approval_replay_applied
  | Approval_replay_applied_with_warning
  | Approval_replay_failed
  | Approval_replay_indeterminate -> false
;;

let append_approval_lifecycle_at_slot_once
      ~base_dir
      ~keeper_name
      ~lifecycle
      ~transcript_slot
  =
  let open Keeper_chat_delivery_identity in
  match Request_id.of_string lifecycle.approval_id with
  | Error detail -> Error detail
  | Ok approval_id ->
    (try
       ensure_dir_once ~base_dir;
       let redaction = redaction_for ~base_dir ~keeper_name in
       let lifecycle = redact_approval_lifecycle redaction lifecycle in
       let delivery_key = Approval_lifecycle approval_id in
       let provenance = { delivery_key; transcript_slot } in
       let path = chat_path ~base_dir ~keeper_name in
       let ts = Time_compat.now () in
       let row_id = mint_message_id ~ts in
       (* The row's fact is [approval_lifecycle], and [transcript_slot] says
          which step it is -- a correction is [Approval_replay_correction], not
          a sentence saying so. The store used to compose a Korean retelling of
          both into [content], which made a machine-written row read as
          something a Keeper said and put display wording in the persistence
          layer. Every reader now takes the typed fields and words them itself
          (masc #33016). *)
       let line =
         encode_line
           ~role:Role.System
           ~content:""
           ~ts
           ~message_id:row_id
           ~approval_lifecycle:lifecycle
           ~provenance
           ()
       in
       match append_line_once path ~provenance ~row_id line with
       | Error _ as error -> error
       | Ok (Appended _ as result) ->
         announce_appended ~keeper_name ();
         Ok (Approval_lifecycle_exact result)
       | Ok (Already_present { row_id } as result) ->
         (match
            load_all ~base_dir ~keeper_name
            |> List.find_opt (fun message -> String.equal message.id row_id)
          with
          | Some { approval_lifecycle = Some existing; _ }
            when approval_lifecycle_equal existing lifecycle ->
            Ok (Approval_lifecycle_exact result)
          | Some { approval_lifecycle = Some existing; _ } ->
            Ok (Approval_lifecycle_conflict existing)
          | Some _ ->
            Error "approval lifecycle provenance row has no lifecycle content"
          | None -> Error "approval lifecycle provenance row is unreadable")
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       let detail = Printexc.to_string exn in
       Log.Keeper.warn
         "keeper_chat_store: approval lifecycle append failed for %s: %s"
         (sanitize_name keeper_name)
         detail;
       Error detail)

let append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle =
  let open Keeper_chat_delivery_identity in
  let transcript_slot =
    match lifecycle.phase with
    | Approval_requested -> Approval_request
    | Approval_resolved_approved | Approval_resolved_rejected ->
      Approval_resolution
    | Approval_replay_applied
    | Approval_replay_applied_with_warning
    | Approval_replay_failed
    | Approval_replay_indeterminate -> Approval_replay
    | Approval_continuation_recorded
    | Approval_continuation_failed -> Approval_continuation
  in
  match
    append_approval_lifecycle_at_slot_once
      ~base_dir
      ~keeper_name
      ~lifecycle
      ~transcript_slot
  with
  | Error _ as error -> error
  | Ok (Approval_lifecycle_exact result) -> Ok result
  | Ok (Approval_lifecycle_conflict existing) ->
    (* The slot is settled once; say by what, so a caller that reports this
       as "projection failed" still names the phase already there. *)
    Error
      (Printf.sprintf
         "approval lifecycle provenance exists with conflicting content: \
          approval %s already holds phase %s where phase %s was to be appended"
         lifecycle.approval_id
         (approval_lifecycle_phase_to_label existing.phase)
         (approval_lifecycle_phase_to_label lifecycle.phase))
;;

let existing_approval_lifecycle_at_slot
      ~base_dir
      ~keeper_name
      ~approval_id
      ~transcript_slot
  =
  let open Keeper_chat_delivery_identity in
  load_all ~base_dir ~keeper_name
  |> List.find_map (fun message ->
    match message.delivery_provenance, message.approval_lifecycle with
    | ( Some
          { delivery_key = Approval_lifecycle existing_approval_id
          ; transcript_slot = existing_slot
          }
      , Some existing_lifecycle )
      when String.equal (Request_id.to_string existing_approval_id) approval_id
           && transcript_slot_equal existing_slot transcript_slot ->
      Some (message.id, existing_lifecycle)
    | ( ( None
        | Some
            { delivery_key =
                ( Operation _
                | Operation_checkpoint _
                | Operation_native _
                | Fusion_run _
                | Workspace_message _
                | Connector_message _
                | Approval_lifecycle _ )
            ; _
            } )
      , (None | Some _) ) -> None)
;;

let reconcile_approval_replay_lifecycle_once ~base_dir ~keeper_name ~lifecycle =
  let open Keeper_chat_delivery_identity in
  if not (approval_lifecycle_is_replay lifecycle.phase)
  then Error "approval replay reconciliation requires a replay lifecycle phase"
  else
    let redaction = redaction_for ~base_dir ~keeper_name in
    let redacted_lifecycle = redact_approval_lifecycle redaction lifecycle in
    match
      existing_approval_lifecycle_at_slot
        ~base_dir
        ~keeper_name
        ~approval_id:lifecycle.approval_id
        ~transcript_slot:Approval_replay_correction
    with
    | Some (row_id, existing)
      when approval_lifecycle_equal existing redacted_lifecycle ->
      Ok (Already_present { row_id })
    | Some _ -> Error "approval replay correction exists with conflicting content"
    | None ->
      (match
         append_approval_lifecycle_at_slot_once
           ~base_dir
           ~keeper_name
           ~lifecycle
           ~transcript_slot:Approval_replay
       with
       | Error _ as error -> error
       | Ok (Approval_lifecycle_exact result) -> Ok result
       | Ok (Approval_lifecycle_conflict previous) ->
         (match
            append_approval_lifecycle_at_slot_once
              ~base_dir
              ~keeper_name
              ~lifecycle
              ~transcript_slot:Approval_replay_correction
          with
          | Error _ as error -> error
          | Ok
              (Approval_lifecycle_exact
                (Appended _ as result)) ->
            Log.Keeper.warn
              ~keeper_name
              "approval replay chat correction appended approval=%s previous_phase=%s canonical_phase=%s"
              lifecycle.approval_id
              (approval_lifecycle_phase_to_label previous.phase)
              (approval_lifecycle_phase_to_label lifecycle.phase);
            Ok result
          | Ok (Approval_lifecycle_exact (Already_present _ as result)) -> Ok result
          | Ok (Approval_lifecycle_conflict _) ->
            Error "approval replay correction exists with conflicting content"))
;;

let approval_lifecycle_phase_present
      ~base_dir
      ~keeper_name
      ~approval_id
      ~phase
  =
  load_all ~base_dir ~keeper_name
  |> List.exists (fun message ->
    match message.approval_lifecycle with
    | Some lifecycle ->
      String.equal lifecycle.approval_id approval_id && lifecycle.phase = phase
    | None -> false)
;;

let approval_continuation_settled ~base_dir ~keeper_name ~approval_id =
  load_all ~base_dir ~keeper_name
  |> List.exists (fun message ->
    match message.approval_lifecycle with
    | Some lifecycle ->
      String.equal lifecycle.approval_id approval_id
      && approval_lifecycle_is_continuation lifecycle.phase
    | None -> false)
;;

(* The request row is written by the queue with the producer's statement in
   hand ([Keeper_gate.request.call_summary]); no later writer has the
   producer, so every later phase row copies the line from here. Read from the
   stored row, so the copy carries the redaction the store applied. *)
let approval_request_call_summary ~base_dir ~keeper_name ~approval_id =
  Option.bind
    (existing_approval_lifecycle_at_slot
       ~base_dir
       ~keeper_name
       ~approval_id
       ~transcript_slot:Keeper_chat_delivery_identity.Approval_request)
    (fun (_row_id, lifecycle) -> lifecycle.call_summary)
;;

(* RFC-0235 P3: the history endpoint can tell the dashboard that a clip
   has been reaped by checking the same audio directory the synthesis side
   writes to. This keeps the TTL reaper simple while avoiding a broken
   native player on reload. *)
let audio_clip_exists ~base_dir token =
  (* Which container the clip is in is the endpoint's, not this reader's, so
     the token is resolved against every format rather than against MP3 --
     a say clip is WAVE, and looking only for MP3 reports every one of them
     as reaped. *)
  Voice_bridge_core.find_clip
    ~dir:
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "audio")
    ~token
  |> Option.is_some

(* How a file the synthesis side just wrote is announced on a chat line.

   Both halves come out of the one path: the token builds the URL the
   dashboard fetches, and the extension says what the bytes are. They used to
   be taken separately -- the token chopped off by hand, the type the literal
   "audio/mpeg" -- so every [say] reply, which is WAVE and is what a fresh mac
   has, was announced as MP3. The dashboard reads the container off the clip
   response rather than off this field, which is why nothing looked broken;
   the field is still what is persisted here and emitted on SSE, so a reader
   that has only the payload had only the wrong answer.

   It lives here, next to {!audio_clip_exists}, because this is the module
   that owns the clip record: a caller that builds one field at a time is
   where the two halves came apart. *)
let audio_clip_of_synthesized_file ~audio_file ~message_text ~device_id =
  match Voice_bridge_core.clip_of_path audio_file with
  | None ->
    (* A file under a name masc does not serve would be announced at a URL the
       clip route answers 404 for: it resolves a token by trying each known
       extension. The line is still recorded, without audio. *)
    Voice_bridge_core.log_error
      (Printf.sprintf
         "voice: synthesized %s is not a clip masc can serve; the reply is \
          recorded without audio"
         (Filename.basename audio_file));
    None
  | Some (token, format) ->
    Some
      { token
      ; audio_url = Some (Masc_network_defaults.voice_audio_path token)
      ; mime = Voice_bridge_core.clip_content_type format
      ; duration_sec = Voice_bridge_core.audio_duration_seconds ~audio_file
      ; message_text
      ; device_id
      ; expired = false
      }

let valid_audio_token token =
  Re.execp (Re.compile (Re.Pcre.re "^[A-Za-z0-9_-]+$")) token

let resolve_audio_expiry ~base_dir audio =
  match audio with
  | None -> None
  | Some a ->
      let expired =
        if not (valid_audio_token a.token) then true
        else
          match base_dir with
          | None -> a.expired
          | Some base_dir ->
              a.expired
              || not (audio_clip_exists ~base_dir a.token)
      in
      Some { a with expired }

let trace_block_for_turn ~trace_block_by_turn_ref (m : chat_message) =
  match m.turn_ref, trace_block_by_turn_ref with
  | Some turn_ref, Some trace_block_by_turn_ref -> trace_block_by_turn_ref turn_ref
  | None, _ | Some _, None -> None

let to_json_array ?base_dir ?trace_block_by_turn_ref
    ?(omit_stream_contract = false)
    (messages : chat_message list) : Yojson.Safe.t =
  `List
    (List.map
       (fun (m : chat_message) ->
          let trace_block = trace_block_for_turn ~trace_block_by_turn_ref m in
          let audio = resolve_audio_expiry ~base_dir m.audio in
          Keeper_chat_projection.message_to_json ~omit_stream_contract
            ~trace_lookup_available:(Option.is_some trace_block_by_turn_ref)
            ~trace_block { m with audio })
       messages)

type turn_transcript = Keeper_chat_projection.turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

let transcript_of_messages = Keeper_chat_projection.transcript_of_messages
let turn_transcript_to_json = Keeper_chat_projection.turn_transcript_to_json

let exact_transcript_row_identity line =
  let open Result.Syntax in
  match Yojson.Safe.from_string line with
  | `Assoc fields ->
      let keys = List.map fst fields in
      let* () =
        if List.length keys = List.length (List.sort_uniq String.compare keys)
        then Ok () else Error "duplicate transcript row fields" in
      let* () = match List.assoc_opt "id" fields with
        | Some (`String id) when String.trim id <> "" -> Ok ()
        | _ -> Error "transcript row has no non-blank identity" in
      let* () = match List.assoc_opt "content" fields with
        | Some (`String _) -> Ok () | _ -> Error "transcript content is not text" in
      let* () = match List.assoc_opt "ts" fields with
        | Some (`Float ts) when Float.is_finite ts -> Ok ()
        | Some (`Int _) -> Ok () | _ -> Error "transcript timestamp is not finite" in
      let* () = match List.assoc_opt "turn_ref" fields with
        | None -> Ok ()
        | Some json -> Result.map (fun _ -> ()) (Ids.Turn_ref.of_yojson json) in
      Result.map (fun _ -> ())
        (Keeper_chat_delivery_identity.delivery_provenance_of_fields fields)
  | _ -> Error "transcript row is not an object"
  | exception Yojson.Json_error detail -> Error detail

let load_turn_transcript_result ~base_dir ~keeper_name ~turn_ref =
  let open Result.Syntax in
  let path = chat_path ~base_dir ~keeper_name in
  let redaction = redaction_for ~base_dir ~keeper_name in
  let read_page ?cursor () =
    Eio_guard.fair_yield ();
    let* page = Keeper_chat_history_page.read ~path ~owner:keeper_name ?cursor
        ~max_rows:max_int () in
    let* messages_rev = List.fold_left
        (fun state (row : Keeper_chat_history_page.row) ->
          let* messages = state in
          let* () = exact_transcript_row_identity row.line
            |> Result.map_error (fun detail ->
                 Keeper_chat_history_page.Invalid_row { offset = row.offset; detail }) in
          match parse_transcript_row_strict ~path ~redaction ~position:(Byte_offset row.offset) row.line with
          | `Blank -> Ok messages
          | `Message message -> Ok (message :: messages)
          | `Unreadable err ->
              Error (Keeper_chat_history_page.Invalid_row { offset = row.offset; detail = strict_decode_error_to_string err }))
        (Ok []) page.rows in
    Ok { history_messages = List.rev messages_rev; next_cursor = page.next_cursor }
  in
  let* first = read_page () in
  (* Reuse the same first page and its cursor for both passes: a later append
     cannot widen the second pass to a different newest boundary. *)
  let scan select =
    let rec loop page newer =
      let selected = List.filter select page.history_messages in
      let newer = selected @ newer in
      match page.next_cursor with
      | None -> Ok newer
      | Some cursor ->
          let* older = read_page ~cursor () in
          loop older newer
    in
    loop first []
  in
  let* target = scan (fun (message : chat_message) ->
      Option.exists (Ids.Turn_ref.equal turn_ref) message.turn_ref) in
  let assistant = (transcript_of_messages target ~turn_ref).assistant in
  let* user = scan (Keeper_chat_projection.user_matches_turn ~messages:target ~turn_ref) in
  Ok { user; assistant }
