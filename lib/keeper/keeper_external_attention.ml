(* See .mli. *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

let attention_dir base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "external_attention"

let attention_path ~base_path ~keeper_name =
  Filename.concat (attention_dir base_path) (sanitize_name keeper_name ^ ".jsonl")

let ensure_attention_dir ~base_path =
  let (_ : string) = Keeper_fs.ensure_dir (attention_dir base_path) in
  ()

let persistence_surface = "keeper_external_attention"

(* Dedup scan window for [record]. The store is append-only and
   unbounded, so parsing the whole file on every record is O(file) per
   call — O(N^2) across N inbound messages on the Discord hot path. The
   dedup check only needs to catch gateway *redelivery* (Discord replays
   missed events after a RESUME), which is bounded to recent events, so
   scanning the last [dedup_window_bytes] is both sufficient and O(1) in
   file size (one [Fs_compat.read_slice]). A record older than the
   window can in principle be re-appended on a very late redelivery —
   that is a rare, harmless duplicate, never data loss. *)
let dedup_window_bytes = 64 * 1024

(* RFC-0232 P5: the surface vocabulary moved to the shared [Surface_ref]
   module; this equation re-exports it so existing consumers keep
   constructing/matching [Keeper_external_attention.Dashboard] etc. *)
type surface_ref = Surface_ref.t =
  | Dashboard of { session_id : string option }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      channel_name : string option;
      parent_channel_id : string option;
      thread_id : string option;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      channel_name : string option;
      thread_ts : string option;
    }
  | Webhook of { source : string; event_id : string }
  | Agent
  | Broadcast
  | Gate of { label : string; address : (string * string) list }

type conversation_ref = {
  conversation_id : string;
  surface : surface_ref;
}

type external_message_ref = {
  surface : surface_ref;
  message_id : string;
  reply_to_message_id : string option;
}

type urgency =
  | Mention
  | Direct_message
  | Ambient
  | System

type actor = {
  actor_id : string option;
  display_name : string option;
  authority : Keeper_chat_store.speaker_authority;
}

type item = {
  event_id : string;
  dedupe_key : string;
  keeper_name : string;
  conversation : conversation_ref;
  external_message : external_message_ref option;
  source_label : string;
  actor : actor;
  urgency : urgency;
  content_preview : string;
  content_ref : string option;
  received_at : float;
  metadata : (string * string) list;
}

type record_result =
  [ `Recorded
  | `Duplicate of item
  | `Error of string
  ]

type event = Recorded of item

let event_id_of_dedupe_key key =
  Digestif.SHA256.(digest_string key |> to_hex)

let urgency_to_string = function
  | Mention -> "mention"
  | Direct_message -> "direct_message"
  | Ambient -> "ambient"
  | System -> "system"

let urgency_of_string = function
  | "mention" -> Some Mention
  | "direct_message" -> Some Direct_message
  | "ambient" -> Some Ambient
  | "system" -> Some System
  | _ -> None

let required_float key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Float value) -> Ok value
      | Some (`Int value) -> Ok (float_of_int value)
      | _ -> Error (Printf.sprintf "missing float field %s" key))
  | _ -> Error "expected object"

let required_object key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Assoc _ as obj) -> Ok obj
      | _ -> Error (Printf.sprintf "missing object field %s" key))
  | _ -> Error "expected object"

let ( let* ) = Result.bind

let surface_ref_to_json = Surface_ref.to_json

let surface_ref_of_json = Surface_ref.of_json

let conversation_ref_to_json c =
  `Assoc
    [
      ("conversation_id", `String c.conversation_id);
      ("surface", surface_ref_to_json c.surface);
    ]

let conversation_ref_of_json json =
  let* conversation_id = Json_util.require_string json "conversation_id" in
  let* surface_json = required_object "surface" json in
  let* surface = surface_ref_of_json surface_json in
  Ok { conversation_id; surface }

let external_message_ref_to_json m =
  `Assoc
    ([ ("surface", surface_ref_to_json m.surface); ("message_id", `String m.message_id) ]
    @ Json_util.string_field_if_present "reply_to_message_id" m.reply_to_message_id)

let external_message_ref_of_json json =
  let* surface_json = required_object "surface" json in
  let* surface = surface_ref_of_json surface_json in
  let* message_id = Json_util.require_string json "message_id" in
  Ok { surface; message_id; reply_to_message_id = Json_util.assoc_string_opt "reply_to_message_id" json }

let actor_to_json actor =
  `Assoc
    (Json_util.string_field_if_present "actor_id" actor.actor_id
    @ Json_util.string_field_if_present "display_name" actor.display_name
    @ [
        ( "authority",
          `String (Keeper_chat_store.authority_label actor.authority) );
      ])

let actor_of_json json =
  let* authority_label = Json_util.require_string json "authority" in
  match Keeper_chat_store.authority_of_label authority_label with
  | None -> Error (Printf.sprintf "unknown actor authority %S" authority_label)
  | Some authority ->
      Ok
        {
          actor_id = Json_util.assoc_string_opt "actor_id" json;
          display_name = Json_util.assoc_string_opt "display_name" json;
          authority;
        }

let item_to_json item =
  `Assoc
    ([ ("event_id", `String item.event_id);
       ("dedupe_key", `String item.dedupe_key);
       ("keeper_name", `String item.keeper_name);
       ("conversation", conversation_ref_to_json item.conversation);
       ("source_label", `String item.source_label);
       ("actor", actor_to_json item.actor);
       ("urgency", `String (urgency_to_string item.urgency));
       ("content_preview", `String item.content_preview);
       ("received_at", `Float item.received_at);
       ("metadata", Json_util.string_assoc_to_json item.metadata);
     ]
    @ (match item.external_message with
      | None -> []
      | Some ref_ -> [ ("external_message", external_message_ref_to_json ref_) ])
    @ Json_util.string_field_if_present "content_ref" item.content_ref)

let item_of_json json =
  let* event_id = Json_util.require_string json "event_id" in
  let* dedupe_key = Json_util.require_string json "dedupe_key" in
  let* keeper_name = Json_util.require_string json "keeper_name" in
  let* conversation_json = required_object "conversation" json in
  let* conversation = conversation_ref_of_json conversation_json in
  let external_message =
    match Json_util.assoc_object_opt "external_message" json with
    | None -> Ok None
    | Some obj ->
        let* msg = external_message_ref_of_json obj in
        Ok (Some msg)
  in
  let* external_message = external_message in
  let* source_label = Json_util.require_string json "source_label" in
  let* actor_json = required_object "actor" json in
  let* actor = actor_of_json actor_json in
  let* urgency_label = Json_util.require_string json "urgency" in
  let* urgency =
    match urgency_of_string urgency_label with
    | Some urgency -> Ok urgency
    | None -> Error (Printf.sprintf "unknown urgency %S" urgency_label)
  in
  let* content_preview = Json_util.require_string json "content_preview" in
  let* received_at = required_float "received_at" json in
  let metadata =
    match Json_util.assoc_object_opt "metadata" json with
    | None -> Ok []
    | Some obj -> Json_util.string_assoc_of_json obj
  in
  let* metadata = metadata in
  Ok
    {
      event_id;
      dedupe_key;
      keeper_name;
      conversation;
      external_message;
      source_label;
      actor;
      urgency;
      content_preview;
      content_ref = Json_util.assoc_string_opt "content_ref" json;
      received_at;
      metadata;
    }

let event_to_json = function
  | Recorded item -> `Assoc [ ("event", `String "recorded"); ("item", item_to_json item) ]

let event_of_json json =
  let* kind = Json_util.require_string json "event" in
  match kind with
  | "recorded" ->
      let* item_json = required_object "item" json in
      let* item = item_of_json item_json in
      Ok (Recorded item)
  | other -> Error (Printf.sprintf "unknown external attention event: %s" other)

let report_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop_counted
    ~surface:persistence_surface ~reason ~path ~detail

type malformed_line_error =
  | Json_syntax_error of string
  | Invalid_payload of string

type read_error =
  | Malformed_line of
      { path : string
      ; line_no : int
      ; cause : malformed_line_error
      }
  | Incomplete_tail of
      { path : string
      ; rows_end : int
      ; end_offset : int
      }
  | Io_failed of
      { path : string
      ; cause : exn
      }
  | Settlement_failed of
      { path : string
      ; primary_cause : exn option
      ; cleanup_failure : Fs_compat.private_jsonl_operation_failure
      }

let malformed_line_error_to_string = function
  | Json_syntax_error detail -> "JSON parse failed: " ^ detail
  | Invalid_payload detail -> "decode failed: " ^ detail
;;

let read_error_to_string = function
  | Malformed_line { path; line_no; cause } ->
    Printf.sprintf
      "%s:%d external attention %s"
      path
      line_no
      (malformed_line_error_to_string cause)
  | Incomplete_tail { path; rows_end; end_offset } ->
    Printf.sprintf
      "%s external attention incomplete tail: complete rows end at byte %d, file ends at byte %d"
      path
      rows_end
      end_offset
  | Io_failed { path; cause } ->
    Printf.sprintf
      "%s external attention read failed: %s"
      path
      (Printexc.to_string cause)
  | Settlement_failed { path; primary_cause; cleanup_failure } ->
    let cleanup =
      Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure
    in
    (match primary_cause with
     | None ->
       Printf.sprintf
         "%s external attention read succeeded but transaction settlement failed: %s"
         path
         cleanup
     | Some cause ->
       Printf.sprintf
         "%s external attention read failed: %s; transaction settlement also failed: %s"
         path
         (Printexc.to_string cause)
         cleanup)
;;

let parse_line_result ~file_path ~line_no line =
  try
    match event_of_json (Yojson.Safe.from_string line) with
    | Ok event -> Ok event
    | Error detail ->
        report_read_drop
          ~reason:Read_drop_reason.Invalid_payload
          ~path:file_path ~detail;
        Error
          (Malformed_line
             { path = file_path; line_no; cause = Invalid_payload detail })
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Yojson.Json_error detail ->
      report_read_drop
        ~reason:Read_drop_reason.Json_syntax_error
        ~path:file_path ~detail;
      Error
        (Malformed_line
           { path = file_path; line_no; cause = Json_syntax_error detail })

let parse_line ~file_path line =
  match parse_line_result ~file_path ~line_no:0 line with
  | Ok event -> Some event
  | Error error ->
      Log.Keeper.warn
        "keeper_external_attention: %s"
        (read_error_to_string error);
      None

type loaded_events =
  { events : event list
  ; incomplete_tail : (int * int) option
  }

let events_of_rows ~path rows =
  rows
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun state line ->
          let ( let* ) = Result.bind in
          let* events_rev, line_no = state in
          let line_no = line_no + 1 in
          let line = String.trim line in
          if String.equal line ""
          then Ok (events_rev, line_no)
          else
            let* event = parse_line_result ~file_path:path ~line_no line in
            Ok (event :: events_rev, line_no))
       (Ok ([], 0))
  |> Result.map (fun (events_rev, _line_no) -> List.rev events_rev)
;;

let load_events_snapshot ~base_path ~keeper_name =
  let path = attention_path ~base_path ~keeper_name in
  let of_rows = function
    | Fs_compat.Private_jsonl_rows.Rows_missing ->
      Ok { events = []; incomplete_tail = None }
    | Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset } ->
      events_of_rows ~path rows
      |> Result.map (fun events ->
        { events
        ; incomplete_tail =
            (if rows_end < end_offset
             then Some (rows_end, end_offset)
             else None)
        })
  in
  let io_failed cause =
    report_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:(Printexc.to_string cause);
    Error (Io_failed { path; cause })
  in
  let settlement_failed ?primary_cause cleanup_failure =
    report_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:
        (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    Error (Settlement_failed { path; primary_cause; cleanup_failure })
  in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Fs_compat.Private_file_succeeded rows -> of_rows rows
  | Fs_compat.Private_file_succeeded_with_cleanup_failure
      { value = _; cleanup_failure } ->
    settlement_failed cleanup_failure
  | Fs_compat.Private_file_failed (Fs_compat.Private_jsonl_rows.Io_failed cause) ->
    io_failed cause
  | Fs_compat.Private_file_failed_with_cleanup_failure
      { error = Fs_compat.Private_jsonl_rows.Io_failed cause; cleanup_failure } ->
    settlement_failed ~primary_cause:cause cleanup_failure
;;

let load_events_result ~base_path ~keeper_name =
  let path = attention_path ~base_path ~keeper_name in
  let ( let* ) = Result.bind in
  let* loaded = load_events_snapshot ~base_path ~keeper_name in
  match loaded.incomplete_tail with
  | None -> Ok loaded.events
  | Some (rows_end, end_offset) ->
    let error = Incomplete_tail { path; rows_end; end_offset } in
    report_read_drop
      ~reason:Read_drop_reason.Invalid_payload
      ~path
      ~detail:(read_error_to_string error);
    Error error

let load_events ~base_path ~keeper_name =
  match load_events_snapshot ~base_path ~keeper_name with
  | Ok loaded -> loaded.events
  | Error error ->
      Log.Keeper.warn
        "keeper_external_attention: %s"
        (read_error_to_string error);
      []

let append_event ~base_path ~keeper_name event =
  try
    ensure_attention_dir ~base_path;
    let path = attention_path ~base_path ~keeper_name in
    let line = Yojson.Safe.to_string (event_to_json event) ^ "\n" in
    (match Fs_compat.append_private_jsonl_durable_locked_result path line with
     | Fs_compat.Private_file_succeeded () -> Ok ()
     | Fs_compat.Private_file_succeeded_with_cleanup_failure
         { value = (); cleanup_failure } ->
       Log.Keeper.warn
         "keeper_external_attention: append committed with transaction settlement failure path=%s: %s"
         path
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
       Ok ()
     | Fs_compat.Private_file_failed error ->
       Error (Fs_compat.private_jsonl_append_error_to_string error)
     | Fs_compat.Private_file_failed_with_cleanup_failure
         { error; cleanup_failure } ->
       Error
         (Printf.sprintf
            "%s; transaction settlement also failed: %s"
            (Fs_compat.private_jsonl_append_error_to_string error)
            (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let detail = Printexc.to_string exn in
      Log.Keeper.warn "keeper_external_attention: append failed for %s: %s"
        (sanitize_name keeper_name) detail;
      Error detail

let recorded_item_by_event_id events event_id =
  List.find_map
    (function
      | Recorded item when String.equal item.event_id event_id -> Some item
      | Recorded _ -> None)
    events

(* RFC-0377: [load_events] parses the whole file on every call, exactly the
   O(file)-per-call shape the [dedup_window_bytes] comment above already
   warns against for [record]'s dedup scan. A caller resolving a *batch* of
   event_ids (e.g. every stimulus admitted into one turn) must not call
   [load_events] once per id — that reintroduces the same O(N * file) trap
   on the read side. Load once, then resolve every id against that one
   in-memory list via a single pass building an id -> item table (first
   [Recorded] occurrence per id wins, matching [recorded_item_by_event_id]
   exactly), so the whole batch costs one file read regardless of size. *)
let recorded_items_by_event_ids ~base_path ~keeper_name ~event_ids =
  let events = load_events ~base_path ~keeper_name in
  let wanted : (string, unit) Hashtbl.t = Hashtbl.create (List.length event_ids) in
  List.iter (fun event_id -> Hashtbl.replace wanted event_id ()) event_ids;
  let found : (string, item) Hashtbl.t = Hashtbl.create (List.length event_ids) in
  List.iter
    (function
      | Recorded item
        when Hashtbl.mem wanted item.event_id
             && not (Hashtbl.mem found item.event_id) ->
        Hashtbl.add found item.event_id item
      | Recorded _ -> ())
    events;
  List.filter_map
    (fun event_id ->
       Option.map (fun item -> event_id, item) (Hashtbl.find_opt found event_id))
    event_ids

(* Read one bounded tail without parsing either boundary fragment. The writer
   may be mid-append, and [from] usually lands mid-line, so only bytes strictly
   between the first and last newline are complete records. *)
let load_tail_events ~window_bytes ~base_path ~keeper_name =
  let path = attention_path ~base_path ~keeper_name in
  match Fs_compat.file_size path with
  | None -> []
  | Some size when size <= window_bytes ->
      (* Small store: the full scan is already within the window. *)
      load_events ~base_path ~keeper_name
  | Some size ->
      let from = size - window_bytes in
      let slice = Fs_compat.read_slice ~path ~from ~len:window_bytes in
      (match String.index_opt slice '\n', String.rindex_opt slice '\n' with
       | Some i, Some j when j > i ->
           String.sub slice (i + 1) (j - i - 1)
           |> String.split_on_char '\n'
           |> List.filter_map (fun line ->
                  let line = String.trim line in
                  if line = "" then None else parse_line ~file_path:path line)
       | _ ->
           (* Fewer than two newlines in the window: no complete line to
              dedup against. Accept the (rare) duplicate over a partial
              parse. *)
           [])

(* Redelivery is always recent, so duplicate admission keeps its small O(1)
   tail. This must not be reused as a conversation-history policy. *)
let load_recent_events ~base_path ~keeper_name =
  load_tail_events ~window_bytes:dedup_window_bytes ~base_path ~keeper_name
;;

(* Connector content defaults to a 4 KiB gate. A separate 4 MiB evidence tail
   therefore leaves ample room for the Librarian's default 72-message window
   plus lifecycle rows, while remaining O(1) in the append-only file. An
   operator-raised content limit degrades to a shorter window, never a scan of
   the whole history. *)
let evidence_window_bytes = 4 * 1024 * 1024

let load_recent_evidence_events ~base_path ~keeper_name =
  load_tail_events ~window_bytes:evidence_window_bytes ~base_path ~keeper_name
;;

let record ~base_path (item : item) =
  let events = load_recent_events ~base_path ~keeper_name:item.keeper_name in
  match recorded_item_by_event_id events item.event_id with
  | Some existing -> `Duplicate existing
  | None -> (
      match append_event ~base_path ~keeper_name:item.keeper_name (Recorded item) with
      | Ok () -> `Recorded
      | Error detail -> `Error detail)

let store_read_error ~base_path ~keeper_name =
  match load_events_result ~base_path ~keeper_name with
  | Ok _ -> None
  | Error error -> Some (read_error_to_string error)
