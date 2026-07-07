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

let default_claim_stale_after_s = 900.0

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
      parent_channel_id : string option;
      thread_id : string option;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
    }
  | Github of { repo : string; notification_id : string option }
  | Webhook of { source : string; event_id : string }
  | Agent
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
  continuation_channel : Keeper_continuation_channel.t;
  actor : actor;
  urgency : urgency;
  content_preview : string;
  content_ref : string option;
  received_at : float;
  metadata : (string * string) list;
}

type event =
  | Recorded of item
  | Claimed_for_turn of {
      event_id : string;
      claim_id : string;
      turn_id : int option;
      claimed_at : float;
    }
  | Resolved of {
      event_id : string;
      resolved_at : float;
      reason : string;
    }
  | Ignored of {
      event_id : string;
      ignored_at : float;
      reason : string;
    }

type record_result =
  [ `Recorded
  | `Duplicate of item
  | `Error of string
  ]

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

let opt_string_field key = function
  | None -> []
  | Some value -> [ (key, `String value) ]

let opt_int_field key = function
  | None -> []
  | Some value -> [ (key, `Int value) ]

let string_assoc_json fields =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) fields)

let string_assoc_of_json = function
  | `Assoc fields ->
      Ok
        (List.filter_map
           (fun (key, value) ->
             match value with
             | `String s -> Some (key, s)
             | _ -> None)
           fields)
  | _ -> Error "expected string object"

let required_string key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | _ -> Error (Printf.sprintf "missing string field %s" key))
  | _ -> Error "expected object"

let optional_string key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | Some (`String _) | Some `Null | None -> None
      | Some _ -> None)
  | _ -> None

let optional_int key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int value) -> Some value
      | Some `Null | None -> None
      | Some _ -> None)
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

let optional_object key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Assoc _ as obj) -> Some obj
      | Some `Null | None -> None
      | Some _ -> None)
  | _ -> None

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
  let* conversation_id = required_string "conversation_id" json in
  let* surface_json = required_object "surface" json in
  let* surface = surface_ref_of_json surface_json in
  Ok { conversation_id; surface }

let external_message_ref_to_json m =
  `Assoc
    ([ ("surface", surface_ref_to_json m.surface); ("message_id", `String m.message_id) ]
    @ opt_string_field "reply_to_message_id" m.reply_to_message_id)

let external_message_ref_of_json json =
  let* surface_json = required_object "surface" json in
  let* surface = surface_ref_of_json surface_json in
  let* message_id = required_string "message_id" json in
  Ok { surface; message_id; reply_to_message_id = optional_string "reply_to_message_id" json }

let actor_to_json actor =
  `Assoc
    (opt_string_field "actor_id" actor.actor_id
    @ opt_string_field "display_name" actor.display_name
    @ [
        ( "authority",
          `String (Keeper_chat_store.authority_label actor.authority) );
      ])

let actor_of_json json =
  let* authority_label = required_string "authority" json in
  match Keeper_chat_store.authority_of_label authority_label with
  | None -> Error (Printf.sprintf "unknown actor authority %S" authority_label)
  | Some authority ->
      Ok
        {
          actor_id = optional_string "actor_id" json;
          display_name = optional_string "display_name" json;
          authority;
        }

let item_to_json item =
  `Assoc
    ([ ("event_id", `String item.event_id);
       ("dedupe_key", `String item.dedupe_key);
       ("keeper_name", `String item.keeper_name);
       ("conversation", conversation_ref_to_json item.conversation);
       ("source_label", `String item.source_label);
       ( "continuation_channel",
         Keeper_continuation_channel.to_yojson item.continuation_channel );
       ("actor", actor_to_json item.actor);
       ("urgency", `String (urgency_to_string item.urgency));
       ("content_preview", `String item.content_preview);
       ("received_at", `Float item.received_at);
       ("metadata", string_assoc_json item.metadata);
     ]
    @ (match item.external_message with
      | None -> []
      | Some ref_ -> [ ("external_message", external_message_ref_to_json ref_) ])
    @ opt_string_field "content_ref" item.content_ref)

let item_of_json json =
  let* event_id = required_string "event_id" json in
  let* dedupe_key = required_string "dedupe_key" json in
  let* keeper_name = required_string "keeper_name" json in
  let* conversation_json = required_object "conversation" json in
  let* conversation = conversation_ref_of_json conversation_json in
  let external_message =
    match optional_object "external_message" json with
    | None -> Ok None
    | Some obj ->
        let* msg = external_message_ref_of_json obj in
        Ok (Some msg)
  in
  let* external_message = external_message in
  let* source_label = required_string "source_label" json in
  let continuation_channel =
    match optional_object "continuation_channel" json with
    | None ->
      Ok
        (Keeper_continuation_channel.unrouted
           "external attention record missing continuation_channel")
    | Some obj ->
      (match Keeper_continuation_channel.of_yojson obj with
       | Ok channel -> Ok channel
       | Error err ->
         Ok
           (Keeper_continuation_channel.unrouted
              ("invalid external attention continuation_channel: " ^ err)))
  in
  let* continuation_channel = continuation_channel in
  let* actor_json = required_object "actor" json in
  let* actor = actor_of_json actor_json in
  let* urgency_label = required_string "urgency" json in
  let* urgency =
    match urgency_of_string urgency_label with
    | Some urgency -> Ok urgency
    | None -> Error (Printf.sprintf "unknown urgency %S" urgency_label)
  in
  let* content_preview = required_string "content_preview" json in
  let* received_at = required_float "received_at" json in
  let metadata =
    match optional_object "metadata" json with
    | None -> Ok []
    | Some obj -> string_assoc_of_json obj
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
      continuation_channel;
      actor;
      urgency;
      content_preview;
      content_ref = optional_string "content_ref" json;
      received_at;
      metadata;
    }

let event_to_json = function
  | Recorded item -> `Assoc [ ("event", `String "recorded"); ("item", item_to_json item) ]
  | Claimed_for_turn { event_id; claim_id; turn_id; claimed_at } ->
      `Assoc
        ([ ("event", `String "claimed_for_turn");
           ("event_id", `String event_id);
           ("claim_id", `String claim_id);
           ("claimed_at", `Float claimed_at);
         ]
        @ opt_int_field "turn_id" turn_id)
  | Resolved { event_id; resolved_at; reason } ->
      `Assoc
        [
          ("event", `String "resolved");
          ("event_id", `String event_id);
          ("resolved_at", `Float resolved_at);
          ("reason", `String reason);
        ]
  | Ignored { event_id; ignored_at; reason } ->
      `Assoc
        [
          ("event", `String "ignored");
          ("event_id", `String event_id);
          ("ignored_at", `Float ignored_at);
          ("reason", `String reason);
        ]

let event_of_json json =
  let* tag = required_string "event" json in
  match tag with
  | "recorded" ->
      let* item_json = required_object "item" json in
      let* item = item_of_json item_json in
      Ok (Recorded item)
  | "claimed_for_turn" ->
      let* event_id = required_string "event_id" json in
      let* claim_id = required_string "claim_id" json in
      let* claimed_at = required_float "claimed_at" json in
      Ok
        (Claimed_for_turn
           {
             event_id;
             claim_id;
             turn_id = optional_int "turn_id" json;
             claimed_at;
           })
  | "resolved" ->
      let* event_id = required_string "event_id" json in
      let* resolved_at = required_float "resolved_at" json in
      let* reason = required_string "reason" json in
      Ok (Resolved { event_id; resolved_at; reason })
  | "ignored" ->
      let* event_id = required_string "event_id" json in
      let* ignored_at = required_float "ignored_at" json in
      let* reason = required_string "reason" json in
      Ok (Ignored { event_id; ignored_at; reason })
  | other -> Error (Printf.sprintf "unknown external attention event %S" other)

let report_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ ("surface", persistence_surface); ("reason", reason) ]
        ())
    ~surface:persistence_surface ~reason ~path ~detail

let parse_line_result ~file_path ~line_no line =
  try
    match event_of_json (Yojson.Safe.from_string line) with
    | Ok event -> Ok event
    | Error detail ->
        report_read_drop
          ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
          ~path:file_path ~detail;
        Error
          (Printf.sprintf
             "%s:%d external attention decode failed: %s"
             file_path
             line_no
             detail)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Yojson.Json_error detail ->
      report_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
        ~path:file_path ~detail;
      Error
        (Printf.sprintf
           "%s:%d external attention JSON parse failed: %s"
           file_path
           line_no
           detail)

let parse_line ~file_path line =
  match parse_line_result ~file_path ~line_no:0 line with
  | Ok event -> Some event
  | Error msg ->
      Log.Keeper.warn "keeper_external_attention: %s" msg;
      None

let load_events_result ~base_path ~keeper_name =
  let path = attention_path ~base_path ~keeper_name in
  if not (Sys.file_exists path) then Ok []
  else
    try
      let (events_rev, _line_no), _boundary =
        Fs_compat.fold_appended_lines ~path ~from:0 ~init:(Ok [], 0)
          ~f:(fun (events, line_no) line ->
            let line_no = line_no + 1 in
            let line = String.trim line in
            if line = "" then events, line_no
            else
              match events with
              | Error _ -> events, line_no
              | Ok acc -> (
                  match parse_line_result ~file_path:path ~line_no line with
                  | Ok event -> Ok (event :: acc), line_no
                  | Error _ as error -> error, line_no))
      in
      Result.map List.rev events_rev
    with
    | Sys_error detail ->
        report_read_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~path ~detail;
        Error (Printf.sprintf "%s external attention read failed: %s" path detail)
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Error
          (Printf.sprintf
             "%s external attention load failed for %s: %s"
             path
             (sanitize_name keeper_name)
             (Printexc.to_string exn))

let load_events ~base_path ~keeper_name =
  match load_events_result ~base_path ~keeper_name with
  | Ok events -> events
  | Error msg ->
      Log.Keeper.warn "keeper_external_attention: %s" msg;
      []

let append_event ~base_path ~keeper_name event =
  try
    ensure_attention_dir ~base_path;
    let path = attention_path ~base_path ~keeper_name in
    Fs_compat.append_file path (Yojson.Safe.to_string (event_to_json event) ^ "\n");
    Ok ()
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
      | Recorded _ | Claimed_for_turn _ | Resolved _ | Ignored _ -> None)
    events

(* Events from the last [dedup_window_bytes] of the store, for the
   redelivery dedup check in [record]. Reads a bounded tail via
   [read_slice] instead of folding the whole file, so it stays O(window)
   regardless of how large the append-only store has grown. The slice
   starts mid-line (and the writer may be mid-append), so only the bytes
   strictly between the first and last newline are complete lines —
   parsing just those avoids feeding a partial line to [parse_line]
   (which would otherwise log a spurious read-drop on every call). *)
let load_recent_events ~base_path ~keeper_name =
  let path = attention_path ~base_path ~keeper_name in
  match Fs_compat.file_size path with
  | None -> []
  | Some size when size <= dedup_window_bytes ->
      (* Small store: the full scan is already within the window. *)
      load_events ~base_path ~keeper_name
  | Some size ->
      let from = size - dedup_window_bytes in
      let slice = Fs_compat.read_slice ~path ~from ~len:dedup_window_bytes in
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

let record ~base_path (item : item) =
  let events = load_recent_events ~base_path ~keeper_name:item.keeper_name in
  match recorded_item_by_event_id events item.event_id with
  | Some existing -> `Duplicate existing
  | None -> (
      match append_event ~base_path ~keeper_name:item.keeper_name (Recorded item) with
      | Ok () -> `Recorded
      | Error detail -> `Error detail)

let now_or_default = function
  | Some now -> now
  | None -> Time_compat.now ()

let append_many ~base_path ~keeper_name events =
  try
    ensure_attention_dir ~base_path;
    let path = attention_path ~base_path ~keeper_name in
    let jsons = List.map event_to_json events in
    Fs_compat.append_jsonl_batch path jsons;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let detail = Printexc.to_string exn in
      Log.Keeper.warn "keeper_external_attention: append batch failed for %s: %s"
        (sanitize_name keeper_name) detail;
      Error detail

let claim_for_turn ~base_path ~keeper_name ~event_ids ~claim_id ~turn_id ?now () =
  let claimed_at = now_or_default now in
  let events =
    List.map
      (fun event_id -> Claimed_for_turn { event_id; claim_id; turn_id; claimed_at })
      event_ids
  in
  append_many ~base_path ~keeper_name events

let mark_resolved ~base_path ~keeper_name ~event_ids ~reason ?now () =
  let resolved_at = now_or_default now in
  let events =
    List.map
      (fun event_id -> Resolved { event_id; resolved_at; reason })
      event_ids
  in
  append_many ~base_path ~keeper_name events

let mark_ignored ~base_path ~keeper_name ~event_ids ~reason ?now () =
  let ignored_at = now_or_default now in
  let events =
    List.map
      (fun event_id -> Ignored { event_id; ignored_at; reason })
      event_ids
  in
  append_many ~base_path ~keeper_name events

type projected_state =
  | Pending of item
  | Claimed of item * float
  | Terminal

let project_pending events ~now ~claim_stale_after =
  let tbl : (string, projected_state) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (function
      | Recorded item -> (
          match Hashtbl.find_opt tbl item.event_id with
          | Some Terminal -> ()
          | Some (Claimed _ | Pending _) | None ->
              Hashtbl.replace tbl item.event_id (Pending item))
      | Claimed_for_turn { event_id; claimed_at; _ } -> (
          match Hashtbl.find_opt tbl event_id with
          | Some (Pending item) -> Hashtbl.replace tbl event_id (Claimed (item, claimed_at))
          | Some (Claimed _ | Terminal) | None -> ())
      | Resolved { event_id; _ } | Ignored { event_id; _ } ->
          Hashtbl.replace tbl event_id Terminal)
    events;
  Hashtbl.fold
    (fun _ state acc ->
      match state with
      | Pending item -> item :: acc
      | Claimed (item, claimed_at)
        when now -. claimed_at > claim_stale_after ->
          item :: acc
      | Claimed _ | Terminal -> acc)
    tbl []
  |> List.sort (fun a b -> compare a.received_at b.received_at)

let take limit items =
  let rec loop n acc = function
    | _ when n <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> loop (n - 1) (item :: acc) rest
  in
  loop limit [] items

let pending_for_keeper_result ~base_path ~keeper_name ?now ?claim_stale_after ~limit () =
  let now = now_or_default now in
  let claim_stale_after =
    match claim_stale_after with
    | Some seconds -> seconds
    | None -> default_claim_stale_after_s
  in
  let* events = load_events_result ~base_path ~keeper_name in
  Ok (events |> project_pending ~now ~claim_stale_after |> take (max 0 limit))

let pending_for_keeper ~base_path ~keeper_name ?now ?claim_stale_after ~limit () =
  match
    pending_for_keeper_result ~base_path ~keeper_name ?now ?claim_stale_after
      ~limit ()
  with
  | Ok pending -> pending
  | Error msg ->
      Log.Keeper.warn "keeper_external_attention: %s" msg;
      []
