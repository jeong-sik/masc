(** Durable per-Keeper chat receipt queue. *)

type message_source =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of {
      channel_id : string;
      user_id : string;
      user_name : string;
      team_id : string option;
      thread_ts : string option;
    }

type queued_message = {
  content : string;
  user_blocks : Keeper_multimodal_input.user_input_block list;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
}

module Receipt_id = Keeper_chat_delivery_identity.Receipt_id

type completion = {
  completed_at : float;
  outcome_ref : string option;
}

type failure_kind =
  | Turn_failed
  | Legacy_request_timeout
  | No_visible_reply
  | Transcript_persist_failed
  | Connector_unavailable
  | Delivery_failed
  | Cancelled
  | Internal_error
  | Recovery_interrupted

type failure = {
  completed_at : float;
  kind : failure_kind;
  detail : string;
  outcome_ref : string option;
}

type receipt_state =
  | Pending
  | Inflight of { lease_id : string; started_at : float }
  | Delivered of completion
  | Failed of failure

type leased_message = {
  receipt_id : Receipt_id.t;
  message : queued_message;
}

type lease = {
  lease_id : string;
  items : leased_message list;
}

type finalization =
  | Mark_delivered of completion
  | Mark_failed of failure

type snapshot_load_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Migration_failed
  | Recovery_failed

type snapshot_load_error = {
  kind : snapshot_load_error_kind;
  path : string option;
  message : string;
}

type mutation_error =
  | Persistence_not_configured
  | Snapshot_unavailable of snapshot_load_error
  | Invalid_input of string
  | Revision_exhausted
  | Persist_failed of string

let snapshot_load_error_kind_to_string = function
  | Invalid_path -> "invalid_path"
  | Read_failed -> "read_failed"
  | Parse_failed -> "parse_failed"
  | Migration_failed -> "migration_failed"
  | Recovery_failed -> "recovery_failed"

let mutation_error_to_string = function
  | Persistence_not_configured -> "chat queue persistence is not configured"
  | Invalid_input message -> "chat queue input is invalid: " ^ message
  | Revision_exhausted -> "chat queue revision domain is exhausted"
  | Persist_failed message -> "chat queue persistence failed: " ^ message
  | Snapshot_unavailable error ->
    Printf.sprintf
      "chat queue snapshot unavailable (%s): %s"
      (snapshot_load_error_kind_to_string error.kind)
      error.message

type active_receipt = {
  receipt_id : Receipt_id.t;
  message : queued_message;
  state : receipt_state;
}

type receipt_view = {
  receipt_id : Receipt_id.t;
  state : receipt_state;
}

type receipt_lookup = {
  revision : int64;
  receipt : receipt_view option;
}

type diagnostic_snapshot = {
  revision : int64;
  pending : active_receipt list;
  inflight : active_receipt list;
  terminal : receipt_view list;
  load_errors : snapshot_load_error list;
}

type enqueue_receipt = {
  receipt_id : Receipt_id.t;
  revision : int64;
  pending_count : int;
  inflight_count : int;
}

type configure_report = {
  restored_keeper_count : int;
  migrated_keeper_count : int;
  recovered_receipt_count : int;
  load_errors : (string option * snapshot_load_error) list;
}

type transition_observer = keeper_name:string -> revision:int64 -> unit

type stored_state =
  | Stored_pending of queued_message
  | Stored_inflight of
      { lease_id : string
      ; started_at : float
      ; message : queued_message
      }
  | Stored_delivered of completion
  | Stored_failed of failure

type stored_receipt = {
  receipt_id : Receipt_id.t;
  state : stored_state;
}

type queue_entry = {
  mutex : Eio.Mutex.t;
  mutable revision : int64;
  mutable receipts : stored_receipt list;
  mutable load_errors : snapshot_load_error list;
}

let schema_v1 = "keeper_chat_queue.v1"
let schema_v2 = "keeper_chat_queue.v2"
(* Revisions cross the JSON/JavaScript dashboard boundary as numbers. Keep the
   persisted domain within IEEE-754's exact integer range instead of accepting
   all int64 values and silently losing identity in the browser. *)
let max_revision = 9_007_199_254_740_991L
let persistence_file = "chat-queue.json"
let persistence_base_path : string option Atomic.t = Atomic.make None
let global_load_errors : snapshot_load_error list Atomic.t = Atomic.make []
let fail_next_persist_for_testing = Atomic.make false
let transition_observer : transition_observer option Atomic.t = Atomic.make None

let registry_mutex = Eio.Mutex.create ()
let registry : (string, queue_entry) Hashtbl.t = Hashtbl.create 16

let dashboard_queue_default_thread_id = "dashboard"

let dashboard_thread_id_or_default = function
  | Some thread_id -> thread_id
  | None -> dashboard_queue_default_thread_id

let continuation_channel_of_message_source ?dashboard_thread_id = function
  | Dashboard ->
    Keeper_continuation_channel.Dashboard
      { thread_id = dashboard_thread_id_or_default dashboard_thread_id }
  | Discord { channel_id; user_id } ->
    Keeper_continuation_channel.Discord
      { guild_id = None
      ; channel_id
      ; parent_channel_id = None
      ; thread_id = None
      ; user_id
      }
  | Slack { channel_id; user_id; team_id; thread_ts; _ } ->
    Keeper_continuation_channel.Slack
      { team_id; channel_id; thread_ts; user_id }

let set_transition_observer observer = Atomic.set transition_observer observer

let notify_transition ~keeper_name ~revision =
  match Atomic.get transition_observer with
  | None -> ()
  | Some observer ->
    (try observer ~keeper_name ~revision with
     | exn ->
       Log.Keeper.warn
         "chat_queue_transition_observer: keeper=%s revision=%Ld failed: %s"
         keeper_name revision (Printexc.to_string exn))

let valid_keeper_name name =
  let valid_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  (not (String.equal name ""))
  && not (String.equal name ".")
  && not (String.equal name "..")
  && String.for_all valid_char name

let snapshot_path ~base_path ~keeper_name =
  if valid_keeper_name keeper_name
  then
    Ok
      (Filename.concat
         (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
         persistence_file)
  else Error (Printf.sprintf "invalid keeper name for chat queue snapshot: %s" keeper_name)

let source_to_yojson = function
  | Dashboard -> `Assoc [ "kind", `String "dashboard" ]
  | Discord { channel_id; user_id } ->
    `Assoc
      [ "kind", `String "discord"
      ; "channel_id", `String channel_id
      ; "user_id", `String user_id
      ]
  | Slack { channel_id; user_id; user_name; team_id; thread_ts } ->
    `Assoc
      [ "kind", `String "slack"
      ; "channel_id", `String channel_id
      ; "user_id", `String user_id
      ; "user_name", `String user_name
      ; ("team_id", Option.fold ~none:`Null ~some:(fun value -> `String value) team_id)
      ; ("thread_ts", Option.fold ~none:`Null ~some:(fun value -> `String value) thread_ts)
      ]

let required_member json key =
  match Json_util.assoc_member_opt key json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "chat queue JSON requires %s" key)

let required_string json key =
  match required_member json key with
  | Ok (`String value) -> Ok value
  | Ok _ -> Error (Printf.sprintf "chat queue JSON field %s must be a string" key)
  | Error _ as error -> error

let required_float json key =
  match required_member json key with
  | Ok (`Float value) when Float.is_finite value -> Ok value
  | Ok (`Float _) ->
    Error (Printf.sprintf "chat queue JSON field %s must be finite" key)
  | Ok (`Int value) -> Ok (Float.of_int value)
  | Ok _ -> Error (Printf.sprintf "chat queue JSON field %s must be a number" key)
  | Error _ as error -> error

let required_nonnegative_int json key =
  match required_member json key with
  | Ok (`Int value) when value >= 0 -> Ok value
  | Ok _ ->
    Error
      (Printf.sprintf
         "chat queue JSON field %s must be a non-negative integer"
         key)
  | Error _ as error -> error

let optional_string json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    let value = String.trim value in
    if value = ""
    then Error (Printf.sprintf "chat queue JSON field %s must be non-empty when present" key)
    else Ok (Some value)
  | Some _ -> Error (Printf.sprintf "chat queue JSON field %s must be string or null" key)

let source_of_yojson json =
  match required_string json "kind" with
  | Error _ as error -> error
  | Ok "dashboard" -> Ok Dashboard
  | Ok "discord" ->
    (match required_string json "channel_id", required_string json "user_id" with
     | Ok channel_id, Ok user_id
       when String.trim channel_id <> "" && String.trim user_id <> "" ->
       Ok (Discord { channel_id; user_id })
     | Ok _, Ok _ -> Error "discord chat queue source requires non-empty ids"
     | Error error, _ | _, Error error -> Error error)
  | Ok "slack" ->
    (match
       required_string json "channel_id",
       required_string json "user_id",
       required_string json "user_name",
       optional_string json "team_id",
       optional_string json "thread_ts"
     with
     | Ok channel_id, Ok user_id, Ok user_name, Ok team_id, Ok thread_ts
       when String.trim channel_id <> ""
            && String.trim user_id <> ""
            && String.trim user_name <> "" ->
       Ok (Slack { channel_id; user_id; user_name; team_id; thread_ts })
     | Ok _, Ok _, Ok _, Ok _, Ok _ ->
       Error "slack chat queue source requires non-empty channel/user identity"
     | Error error, _, _, _, _
     | _, Error error, _, _, _
     | _, _, Error error, _, _
     | _, _, _, Error error, _
     | _, _, _, _, Error error -> Error error)
  | Ok kind -> Error (Printf.sprintf "unsupported chat queue source kind: %s" kind)

let same_source left right =
  match left, right with
  | Dashboard, Dashboard -> true
  | Discord left, Discord right ->
    String.equal left.channel_id right.channel_id
    && String.equal left.user_id right.user_id
  | Slack left, Slack right ->
    String.equal left.channel_id right.channel_id
    && String.equal left.user_id right.user_id
    && Option.equal String.equal left.team_id right.team_id
    && Option.equal String.equal left.thread_ts right.thread_ts
  | Dashboard, (Discord _ | Slack _)
  | Discord _, (Dashboard | Slack _)
  | Slack _, (Dashboard | Discord _) -> false

let queued_message_to_yojson (message : queued_message) =
  `Assoc
    [ "content", `String message.content
    ; "user_blocks", Keeper_multimodal_input.user_blocks_to_yojson message.user_blocks
    ; "attachments", Keeper_multimodal_input.attachments_to_yojson message.attachments
    ; "timestamp", `Float message.timestamp
    ; "source", source_to_yojson message.source
    ]

let attachment_of_yojson json =
  match json with
  | `Assoc _ ->
    (match
       required_string json "id",
       required_string json "type",
       required_string json "name",
       required_nonnegative_int json "size",
       required_string json "mime_type",
       required_string json "data"
     with
     | Ok id, Ok att_type, Ok name, Ok size, Ok mime_type, Ok data
       when String.trim id <> "" && data <> "" ->
       Ok
         { Keeper_chat_store.id
         ; att_type
         ; name
         ; size
         ; mime_type
         ; data
         }
     | Ok _, Ok _, Ok _, Ok _, Ok _, Ok _ ->
       Error "chat queue attachment requires non-empty id and data"
     | Error error, _, _, _, _, _
     | _, Error error, _, _, _, _
     | _, _, Error error, _, _, _
     | _, _, _, Error error, _, _
     | _, _, _, _, Error error, _
     | _, _, _, _, _, Error error -> Error error)
  | _ -> Error "chat queue attachment must be a JSON object"

let attachments_of_yojson = function
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match attachment_of_yojson value with
         | Ok attachment -> loop (attachment :: acc) rest
         | Error _ as error -> error)
    in
    loop [] values
  | _ -> Error "chat queue attachments must be an array"

let queued_message_of_yojson_with_source source_parser json =
  match json with
  | `Assoc _ ->
    (match
       required_string json "content",
       required_float json "timestamp",
       required_member json "user_blocks",
       required_member json "attachments",
       required_member json "source"
     with
     | Ok content, Ok timestamp, Ok _, Ok attachments_json, Ok source_json ->
       (match
          Keeper_multimodal_input.parse_user_blocks json,
          attachments_of_yojson attachments_json,
          source_parser source_json
        with
        | Ok user_blocks, Ok attachments, Ok source ->
          Ok { content; user_blocks; attachments; timestamp; source }
        | Error error, _, _ | _, Error error, _ | _, _, Error error ->
          Error error)
     | Error error, _, _, _, _
     | _, Error error, _, _, _
     | _, _, Error error, _, _
     | _, _, _, Error error, _
     | _, _, _, _, Error error -> Error error)
  | _ -> Error "chat queue message must be a JSON object"

let queued_message_of_yojson json =
  queued_message_of_yojson_with_source source_of_yojson json

let source_of_v1_yojson json =
  match required_string json "kind" with
  | Ok "slack" ->
    (match required_string json "channel", required_string json "user_id" with
     | Ok channel_id, Ok user_id
       when String.trim channel_id <> "" && String.trim user_id <> "" ->
       (* Version 1 predates typed Slack thread/team/name persistence. Preserve
          its known channel/user identity explicitly; absent fields remain
          absent rather than being inferred from unrelated values. *)
       Ok
         (Slack
            { channel_id
            ; user_id
            ; user_name = user_id
            ; team_id = None
            ; thread_ts = None
            })
     | Ok _, Ok _ -> Error "legacy slack chat queue source requires non-empty ids"
     | Error error, _ | _, Error error -> Error error)
  | Ok _ | Error _ -> source_of_yojson json

let rec validate_json_utf8 path = function
  | `String value when String.is_valid_utf_8 value -> Ok ()
  | `String _ -> Error (path ^ " contains malformed UTF-8")
  | `Assoc fields ->
    List.fold_left
      (fun result (key, value) ->
         Result.bind result (fun () ->
             if not (String.is_valid_utf_8 key)
             then Error (path ^ " contains a malformed UTF-8 field name")
             else validate_json_utf8 (path ^ "." ^ key) value))
      (Ok ()) fields
  | `List values | `Tuple values ->
    List.fold_left
      (fun result value ->
         Result.bind result (fun () -> validate_json_utf8 path value))
      (Ok ()) values
  | `Variant (name, value) ->
    if not (String.is_valid_utf_8 name)
    then Error (path ^ " contains a malformed UTF-8 variant name")
    else Option.fold ~none:(Ok ()) ~some:(validate_json_utf8 path) value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> Ok ()

let canonical_queued_message message =
  let json = queued_message_to_yojson message in
  Result.bind (validate_json_utf8 "message" json) (fun () ->
      queued_message_of_yojson json)

let failure_kind_to_string = function
  | Turn_failed -> "turn_failed"
  | Legacy_request_timeout -> "legacy_request_timeout"
  | No_visible_reply -> "no_visible_reply"
  | Transcript_persist_failed -> "transcript_persist_failed"
  | Connector_unavailable -> "connector_unavailable"
  | Delivery_failed -> "delivery_failed"
  | Cancelled -> "cancelled"
  | Internal_error -> "internal_error"
  | Recovery_interrupted -> "recovery_interrupted"

let failure_kind_of_string = function
  | "turn_failed" -> Ok Turn_failed
  | "timed_out" | "legacy_request_timeout" -> Ok Legacy_request_timeout
  | "no_visible_reply" -> Ok No_visible_reply
  | "transcript_persist_failed" -> Ok Transcript_persist_failed
  | "connector_unavailable" -> Ok Connector_unavailable
  | "delivery_failed" -> Ok Delivery_failed
  | "cancelled" -> Ok Cancelled
  | "internal_error" -> Ok Internal_error
  | "recovery_interrupted" -> Ok Recovery_interrupted
  | value -> Error (Printf.sprintf "unknown chat queue failure kind: %s" value)

let completion_fields (completion : completion) =
  [ "completed_at", `Float completion.completed_at
  ; ( "outcome_ref"
    , match completion.outcome_ref with
      | None -> `Null
      | Some value -> `String value )
  ]

let state_to_yojson = function
  | Stored_pending _ -> `Assoc [ "kind", `String "pending" ]
  | Stored_inflight { lease_id; started_at; _ } ->
    `Assoc
      [ "kind", `String "inflight"
      ; "lease_id", `String lease_id
      ; "started_at", `Float started_at
      ]
  | Stored_delivered completion ->
    `Assoc (("kind", `String "delivered") :: completion_fields completion)
  | Stored_failed failure ->
    `Assoc
      (("kind", `String "failed")
       :: ("failure_kind", `String (failure_kind_to_string failure.kind))
       :: ("detail", `String failure.detail)
       :: completion_fields
            { completed_at = failure.completed_at; outcome_ref = failure.outcome_ref })

let stored_receipt_to_yojson receipt =
  let fields =
    [ "receipt_id", `String (Receipt_id.to_string receipt.receipt_id)
    ; "state", state_to_yojson receipt.state
    ]
  in
  let fields =
    match receipt.state with
    | Stored_pending message | Stored_inflight { message; _ } ->
      fields @ [ "message", queued_message_to_yojson message ]
    | Stored_delivered _ | Stored_failed _ -> fields
  in
  `Assoc fields

let snapshot_to_yojson ~revision receipts =
  `Assoc
    [ "schema", `String schema_v2
    ; "revision", `Intlit (Int64.to_string revision)
    ; "receipts", `List (List.map stored_receipt_to_yojson receipts)
    ]

let save_json_atomic path json =
  Fs_compat.mkdir_p (Filename.dirname path);
  json
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic path

let persist_snapshot_to_path path ~revision receipts =
  if Atomic.exchange fail_next_persist_for_testing false
  then Error "injected chat queue persist failure"
  else
    try save_json_atomic path (snapshot_to_yojson ~revision receipts) with
    | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
    | exception_ -> Error (Printexc.to_string exception_)

let revision_in_domain revision =
  Int64.compare revision 0L >= 0 && Int64.compare revision max_revision <= 0

let parse_revision json =
  match required_member json "revision" with
  | Ok (`Int value) when revision_in_domain (Int64.of_int value) ->
    Ok (Int64.of_int value)
  | Ok (`Intlit value) ->
    (try
       let revision = Int64.of_string value in
       if revision_in_domain revision then Ok revision
       else Error "chat queue revision exceeds the exact non-negative JSON integer domain"
     with Failure _ -> Error "chat queue revision must be an int64")
  | Ok _ ->
    Error "chat queue revision must be an exact non-negative JSON integer"
  | Error _ as error -> error

let parse_receipt_id json =
  match required_string json "receipt_id" with
  | Error _ as error -> error
  | Ok value -> Receipt_id.of_string value

let reject_terminal_message json =
  match Json_util.assoc_member_opt "message" json with
  | None -> Ok ()
  | Some _ -> Error "terminal chat queue receipts must not retain message bodies"

let stored_receipt_of_v2_yojson json =
  match json with
  | `Assoc _ ->
    (match parse_receipt_id json, required_member json "state" with
     | Error error, _ | _, Error error -> Error error
     | Ok receipt_id, Ok state_json ->
       (match required_string state_json "kind" with
        | Error _ as error -> error
        | Ok "pending" ->
          (match required_member json "message" with
           | Error _ as error -> error
           | Ok message_json ->
             Result.map
               (fun message -> { receipt_id; state = Stored_pending message })
               (queued_message_of_yojson message_json))
        | Ok "inflight" ->
          (match
             required_string state_json "lease_id",
             required_float state_json "started_at",
             required_member json "message"
           with
           | Ok lease_id, Ok started_at, Ok message_json
             when String.trim lease_id <> "" ->
             Result.map
               (fun message ->
                  { receipt_id
                  ; state = Stored_inflight { lease_id; started_at; message }
                  })
               (queued_message_of_yojson message_json)
           | Ok _, Ok _, Ok _ ->
             Error "chat queue inflight lease_id must be non-empty"
           | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error)
        | Ok "delivered" ->
          (match
             required_float state_json "completed_at",
             optional_string state_json "outcome_ref",
             reject_terminal_message json
           with
           | Ok completed_at, Ok outcome_ref, Ok () ->
             Ok { receipt_id; state = Stored_delivered { completed_at; outcome_ref } }
           | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error)
        | Ok "failed" ->
          (match
             required_float state_json "completed_at",
             required_string state_json "failure_kind",
             required_string state_json "detail",
             optional_string state_json "outcome_ref",
             reject_terminal_message json
           with
           | Ok completed_at, Ok kind, Ok detail, Ok outcome_ref, Ok ()
             when String.trim detail <> "" ->
             Result.map
               (fun kind ->
                  { receipt_id
                  ; state = Stored_failed { completed_at; kind; detail; outcome_ref }
                  })
               (failure_kind_of_string kind)
           | Ok _, Ok _, Ok _, Ok _, Ok () ->
             Error "failed chat queue receipt detail must be non-empty"
           | Error error, _, _, _, _
           | _, Error error, _, _, _
           | _, _, Error error, _, _
           | _, _, _, Error error, _
           | _, _, _, _, Error error -> Error error)
        | Ok kind -> Error (Printf.sprintf "unknown chat queue receipt state: %s" kind)))
  | _ -> Error "chat queue receipt must be an object"

let parse_receipt_list json =
  match json with
  | `List values ->
    let seen = Hashtbl.create (List.length values) in
    let rec loop seen acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match stored_receipt_of_v2_yojson value with
         | Error _ as error -> error
         | Ok receipt ->
           let id = Receipt_id.to_string receipt.receipt_id in
           if Hashtbl.mem seen id
           then Error (Printf.sprintf "duplicate chat queue receipt_id: %s" id)
           else (
             Hashtbl.add seen id ();
             loop seen (receipt :: acc) rest))
    in
    loop seen [] values
  | _ -> Error "chat queue receipts must be an array"

let parse_v2 json =
  match parse_revision json, required_member json "receipts" with
  | Ok revision, Ok receipts_json ->
    (match parse_receipt_list receipts_json with
     | Error _ as error -> error
     | Ok receipts ->
       let inflight =
         List.filter_map
           (fun receipt ->
              match receipt.state with
              | Stored_inflight { lease_id; message; _ } ->
                Some (lease_id, message)
              | Stored_pending _ | Stored_delivered _ | Stored_failed _ -> None)
           receipts
       in
       (match inflight with
        | [] -> Ok (revision, receipts)
        | (first_lease_id, first_message) :: rest ->
          if
            List.for_all
              (fun (lease_id, message) ->
                 String.equal lease_id first_lease_id
                 && same_source message.source first_message.source)
              rest
          then Ok (revision, receipts)
          else
            Error
              "chat queue v2 permits at most one same-source inflight lease per keeper"))
  | Error error, _ | _, Error error -> Error error

let parse_message_list json =
  match json with
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match queued_message_of_yojson_with_source source_of_v1_yojson value with
         | Error _ as error -> error
         | Ok message -> loop (message :: acc) rest)
    in
    loop [] values
  | _ -> Error "legacy chat queue items must be an array"

let parse_v1_inflight json =
  match Json_util.assoc_member_opt "inflight" json with
  | None | Some `Null -> Ok []
  | Some (`Assoc _ as inflight) ->
    (match required_string inflight "lease_id", required_member inflight "items" with
     | Ok lease_id, Ok items_json when String.trim lease_id <> "" -> parse_message_list items_json
     | Ok _, Ok _ -> Error "legacy inflight lease_id must be non-empty"
     | Error error, _ | _, Error error -> Error error)
  | Some _ -> Error "legacy chat queue inflight must be null or an object"

let parse_v1_for_migration json =
  match required_member json "items", parse_v1_inflight json with
  | Ok items_json, Ok inflight ->
    Result.map (fun pending -> inflight @ pending) (parse_message_list items_json)
  | Error error, _ | _, Error error -> Error error

let migrate_v1_to_v2 path json =
  match parse_v1_for_migration json with
  | Error error -> Error (`Parse error)
  | Ok messages ->
    let receipts =
      List.map
        (fun message ->
           { receipt_id = Receipt_id.generate (); state = Stored_pending message })
        messages
    in
    let revision = 1L in
    (match persist_snapshot_to_path path ~revision receipts with
     | Ok () -> Ok (revision, receipts)
     | Error error -> Error (`Persist error))

type loaded_snapshot = {
  revision : int64;
  receipts : stored_receipt list;
  migrated : bool;
  recovered_count : int;
}

let load_error kind ?path message = { kind; path; message }

let recovered_queue_terminal ~base_path ~keeper_name receipts =
  let inflight_ids =
    List.filter_map
      (fun receipt ->
         match receipt.state with
         | Stored_inflight _ -> Some receipt.receipt_id
         | Stored_pending _ | Stored_delivered _ | Stored_failed _ -> None)
      receipts
  in
  match Keeper_chat_delivery_identity.Receipt_ids.of_list inflight_ids with
  | Error Keeper_chat_delivery_identity.Receipt_ids.Empty -> Ok None
  | Ok receipt_ids ->
    let delivery_key =
      Keeper_chat_delivery_identity.Queue_receipts receipt_ids
    in
    (match
       Keeper_chat_delivery_journal.load
         ~base_path
         ~keeper_name
         delivery_key
     with
     | Error (Keeper_chat_delivery_journal.Not_found _) -> Ok None
     | Error error ->
       Error
         (Keeper_chat_delivery_journal.error_to_string error)
     | Ok
         { Keeper_chat_delivery_journal.phase =
             Keeper_chat_delivery_journal.Final { terminal; _ }
         ; updated_at
         ; _
         } ->
       (* The journal proves transcript commit, not Discord/Slack delivery.
          If the queue snapshot is still Inflight, no durable connector receipt
          exists. Fail explicitly and never redispatch inference; #24180's
          connector outbox is the boundary that can later make outbound delivery
          itself resumable. *)
       let detail =
         if terminal.ok
         then
           "queue transcript committed before restart, but terminal connector delivery was not durably proven"
         else terminal.poll_body
       in
       Ok
         (Some
            (Stored_failed
               { completed_at = updated_at
               ; kind = Recovery_interrupted
               ; detail
               ; outcome_ref = None
               }))
     | Ok journal ->
       Error
         (Printf.sprintf
            "queue delivery journal remained non-final after startup recovery: %s"
            (Keeper_chat_delivery_journal.phase_to_string journal.phase)))

let recover_inflight ~base_path ~keeper_name path ~revision receipts =
  let recovered_count =
    List.fold_left
      (fun count receipt ->
         match receipt.state with
         | Stored_inflight _ -> count + 1
         | Stored_pending _ | Stored_delivered _ | Stored_failed _ -> count)
      0 receipts
  in
  if recovered_count = 0
  then Ok { revision; receipts; migrated = false; recovered_count = 0 }
  else
    let recovered_terminal =
      recovered_queue_terminal ~base_path ~keeper_name receipts
    in
    let receipts =
      Result.map
        (fun recovered_terminal ->
           List.map
             (fun receipt ->
                match receipt.state, recovered_terminal with
                | Stored_inflight _, Some terminal_state ->
                  { receipt with state = terminal_state }
                | Stored_inflight { message; _ }, None ->
                  { receipt with state = Stored_pending message }
                | (Stored_pending _ | Stored_delivered _ | Stored_failed _), _ ->
                  receipt)
             receipts)
        recovered_terminal
    in
    if Int64.compare revision max_revision >= 0
    then
      Error
        (load_error Recovery_failed ~path
           "cannot persist restart recovery: chat queue revision domain is exhausted")
    else
      let revision = Int64.succ revision in
      match receipts with
      | Error error ->
        Error
          (load_error Recovery_failed ~path
             ("failed to reconcile delivery journal: " ^ error))
      | Ok receipts ->
        (match persist_snapshot_to_path path ~revision receipts with
         | Ok () -> Ok { revision; receipts; migrated = false; recovered_count }
         | Error error ->
           Error
             (load_error Recovery_failed ~path
                ("failed to persist restart recovery: " ^ error)))

let load_snapshot ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name with
  | Error message -> Error (load_error Invalid_path message)
  | Ok path ->
    (match Fs_compat.path_kind path with
     | Fs_compat.Missing -> Ok None
     | Fs_compat.Directory | Fs_compat.Other ->
      match Safe_ops.read_json_file_safe path with
      | Error message -> Error (load_error Read_failed ~path message)
      | Ok json ->
        (match required_string json "schema" with
         | Error message -> Error (load_error Parse_failed ~path message)
         | Ok schema when String.equal schema schema_v2 ->
           (match parse_v2 json with
            | Error message -> Error (load_error Parse_failed ~path message)
            | Ok (revision, receipts) ->
              Result.map Option.some
                (recover_inflight
                   ~base_path
                   ~keeper_name
                   path
                   ~revision
                   receipts))
         | Ok schema when String.equal schema schema_v1 ->
           (match migrate_v1_to_v2 path json with
            | Ok (revision, receipts) ->
              Ok (Some { revision; receipts; migrated = true; recovered_count = 0 })
            | Error (`Parse message) ->
              Error (load_error Parse_failed ~path message)
            | Error (`Persist message) ->
              Error
                (load_error Migration_failed ~path
                   ("failed to persist v1 migration: " ^ message)))
         | Ok schema ->
           Error
             (load_error Parse_failed ~path
                (Printf.sprintf "unsupported chat queue schema: %s" schema))))

let create_entry ?(revision = 0L) ?(receipts = []) ?(load_errors = []) () =
  { mutex = Eio.Mutex.create (); revision; receipts; load_errors }

let with_registry_rw f = Eio.Mutex.use_rw ~protect:true registry_mutex f

let find_entry keeper_name =
  with_registry_rw (fun () -> Hashtbl.find_opt registry keeper_name)

let get_or_create_entry keeper_name =
  with_registry_rw (fun () ->
      match Hashtbl.find_opt registry keeper_name with
      | Some entry -> entry
      | None ->
        let entry = create_entry () in
        Hashtbl.add registry keeper_name entry;
        entry)

let with_entry_lock entry f =
  match
    Eio.Mutex.use_rw ~protect:true entry.mutex (fun () ->
        try Ok (f ()) with
        | exception_ -> Error (exception_, Printexc.get_raw_backtrace ()))
  with
  | Ok value -> value
  | Error (exception_, backtrace) ->
    Printexc.raise_with_backtrace exception_ backtrace

let persistence_configured () = Option.is_some (Atomic.get persistence_base_path)

let first_snapshot_error entry =
  match entry.load_errors with
  | error :: _ -> Some error
  | [] ->
    (match Atomic.get global_load_errors with
     | error :: _ -> Some error
     | [] -> None)

let mutation_entry ~keeper_name ~create =
  match Atomic.get persistence_base_path with
  | None -> Error Persistence_not_configured
  | Some base_path ->
    (match snapshot_path ~base_path ~keeper_name with
     | Error message ->
       Error (Snapshot_unavailable (load_error Invalid_path message))
     | Ok path ->
       let entry =
         match find_entry keeper_name, create with
         | Some entry, _ -> Some entry
         | None, true -> Some (get_or_create_entry keeper_name)
         | None, false -> None
       in
       match entry with
       | None -> Ok (base_path, path, None)
       | Some entry ->
         (match first_snapshot_error entry with
          | Some error -> Error (Snapshot_unavailable error)
          | None -> Ok (base_path, path, Some entry)))

let pending_receipts receipts =
  List.filter_map
    (fun receipt ->
       match receipt.state with
       | Stored_pending message -> Some { receipt_id = receipt.receipt_id; message }
       | Stored_inflight _ | Stored_delivered _ | Stored_failed _ -> None)
    receipts

let inflight_receipts receipts =
  List.filter_map
    (fun receipt ->
       match receipt.state with
       | Stored_inflight { message; _ } ->
         Some { receipt_id = receipt.receipt_id; message }
       | Stored_pending _ | Stored_delivered _ | Stored_failed _ -> None)
    receipts

let commit (entry : queue_entry) ~path receipts =
  let before_receipts = entry.receipts in
  let before_revision = entry.revision in
  if Int64.compare before_revision max_revision >= 0
  then Error Revision_exhausted
  else
    let revision = Int64.succ before_revision in
    entry.receipts <- receipts;
    entry.revision <- revision;
    match persist_snapshot_to_path path ~revision receipts with
    | Ok () -> Ok revision
    | Error message ->
      entry.receipts <- before_receipts;
      entry.revision <- before_revision;
      Error (Persist_failed message)
    | exception (Eio.Cancel.Cancelled _ as exception_) ->
      entry.receipts <- before_receipts;
      entry.revision <- before_revision;
      raise exception_

let enqueue ~keeper_name message =
  let receipt_id = Receipt_id.generate () in
  match canonical_queued_message message with
  | Error message -> Error (Invalid_input message)
  | Ok message ->
  match mutation_entry ~keeper_name ~create:true with
  | Error _ as error -> error
  | Ok (_, _, None) ->
    Error (Persist_failed "chat queue entry creation did not produce an entry")
  | Ok (_, path, Some entry) ->
    let result =
      with_entry_lock entry (fun () ->
          let receipt = { receipt_id; state = Stored_pending message } in
          let receipts = entry.receipts @ [ receipt ] in
          match commit entry ~path receipts with
          | Error _ as error -> error
          | Ok revision ->
            Ok
              { receipt_id
              ; revision
              ; pending_count = List.length (pending_receipts receipts)
              ; inflight_count = List.length (inflight_receipts receipts)
              })
    in
    (match result with
     | Ok receipt ->
       notify_transition ~keeper_name ~revision:receipt.revision;
       Ok receipt
     | Error _ as error -> error)

let lease_id () = Random_id.prefixed ~prefix:"lease_" ~bytes:16

module Receipt_id_string_set = Set.Make (String)

let take_same_source_run (items : leased_message list) =
  match items with
  | [] -> []
  | first :: rest ->
    let rec loop (acc : leased_message list) (remaining : leased_message list) =
      match remaining with
      | next :: tail when same_source first.message.source next.message.source ->
        loop (next :: acc) tail
      | _ -> List.rev acc
    in
    first :: loop [] rest

let lease_batch ~keeper_name =
  match mutation_entry ~keeper_name ~create:false with
  | Error error -> `Error error
  | Ok (_, _, None) -> `Empty
  | Ok (_, path, Some entry) ->
    let result =
      with_entry_lock entry (fun () ->
          match inflight_receipts entry.receipts with
          | { receipt_id = _; message = _ } :: _ ->
            let outstanding =
              List.find_map
                (fun receipt ->
                   match receipt.state with
                   | Stored_inflight { lease_id; _ } -> Some lease_id
                   | Stored_pending _ | Stored_delivered _ | Stored_failed _ -> None)
                entry.receipts
            in
            (match outstanding with
             | Some lease_id -> `Already_leased lease_id
             | None ->
               `Error
                 (Persist_failed
                    "inflight receipt exists without a lease id"))
          | [] ->
            let items = take_same_source_run (pending_receipts entry.receipts) in
            if items = []
            then `Empty
            else
              let lease_id = lease_id () in
              let started_at = Time_compat.now () in
              let leased_ids =
                List.fold_left
                  (fun ids (item : leased_message) ->
                     Receipt_id_string_set.add
                       (Receipt_id.to_string item.receipt_id)
                       ids)
                  Receipt_id_string_set.empty
                  items
              in
              let receipts =
                List.map
                  (fun receipt ->
                     match receipt.state with
                     | Stored_pending message
                       when Receipt_id_string_set.mem
                              (Receipt_id.to_string receipt.receipt_id)
                              leased_ids ->
                       { receipt with
                         state = Stored_inflight { lease_id; started_at; message }
                       }
                     | Stored_pending _ | Stored_inflight _
                     | Stored_delivered _ | Stored_failed _ -> receipt)
                  entry.receipts
              in
              match commit entry ~path receipts with
              | Error error -> `Error error
              | Ok revision -> `Leased ({ lease_id; items }, revision))
    in
    (match result with
     | `Leased (lease, revision) ->
       notify_transition ~keeper_name ~revision;
       `Leased lease
     | `Empty -> `Empty
     | `Already_leased lease_id -> `Already_leased lease_id
     | `Error error -> `Error error)

let canonical_optional_ref = function
  | None -> Ok None
  | Some value ->
    let value = String.trim value in
    if value = "" then Error "terminal outcome_ref must be non-empty when present"
    else if not (String.is_valid_utf_8 value) then Error "terminal outcome_ref contains malformed UTF-8"
    else Ok (Some value)

let canonical_terminal_state = function
  | Mark_delivered completion when Float.is_finite completion.completed_at ->
    Result.map
      (fun outcome_ref -> Stored_delivered { completion with outcome_ref })
      (canonical_optional_ref completion.outcome_ref)
  | Mark_delivered _ -> Error "terminal completed_at must be finite"
  | Mark_failed failure when not (Float.is_finite failure.completed_at) ->
    Error "terminal completed_at must be finite"
  | Mark_failed failure ->
    let detail = String.trim failure.detail in
    if detail = "" then Error "terminal failure detail must be non-empty"
    else if not (String.is_valid_utf_8 detail) then Error "terminal failure detail contains malformed UTF-8"
    else
      Result.map
        (fun outcome_ref -> Stored_failed { failure with detail; outcome_ref })
        (canonical_optional_ref failure.outcome_ref)

let finalize ~keeper_name ~lease_id ~outcome =
  match canonical_terminal_state outcome with
  | Error message -> `Error (Invalid_input message)
  | Ok terminal_state ->
  match mutation_entry ~keeper_name ~create:false with
  | Error error -> `Error error
  | Ok (_, _, None) -> `Unknown_lease
  | Ok (_, path, Some entry) ->
    let result =
      with_entry_lock entry (fun () ->
          let matched =
            List.filter_map
              (fun receipt ->
                 match receipt.state with
                 | Stored_inflight current when String.equal current.lease_id lease_id ->
                   Some receipt.receipt_id
                 | Stored_pending _ | Stored_inflight _
                 | Stored_delivered _ | Stored_failed _ -> None)
              entry.receipts
          in
          if matched = []
          then `Unknown_lease
          else
            let receipts =
              List.map
                (fun receipt ->
                   match receipt.state with
                   | Stored_inflight current when String.equal current.lease_id lease_id ->
                     { receipt with state = terminal_state }
                   | Stored_pending _ | Stored_inflight _
                   | Stored_delivered _ | Stored_failed _ -> receipt)
                entry.receipts
            in
            match commit entry ~path receipts with
            | Error error -> `Error error
            | Ok revision -> `Finalized (matched, revision))
    in
    (match result with
     | `Finalized (receipts, revision) ->
       notify_transition ~keeper_name ~revision;
       `Finalized receipts
     | `Unknown_lease -> `Unknown_lease
     | `Error error -> `Error error)

let nack ~keeper_name ~lease_id =
  match mutation_entry ~keeper_name ~create:false with
  | Error error -> `Error error
  | Ok (_, _, None) -> `Unknown_lease
  | Ok (_, path, Some entry) ->
    let result =
      with_entry_lock entry (fun () ->
          let matched =
            List.filter_map
              (fun receipt ->
                 match receipt.state with
                 | Stored_inflight current when String.equal current.lease_id lease_id ->
                   Some receipt.receipt_id
                 | Stored_pending _ | Stored_inflight _
                 | Stored_delivered _ | Stored_failed _ -> None)
              entry.receipts
          in
          if matched = []
          then `Unknown_lease
          else
            let receipts =
              List.map
                (fun receipt ->
                   match receipt.state with
                   | Stored_inflight current when String.equal current.lease_id lease_id ->
                     { receipt with state = Stored_pending current.message }
                   | Stored_pending _ | Stored_inflight _
                   | Stored_delivered _ | Stored_failed _ -> receipt)
                entry.receipts
            in
            match commit entry ~path receipts with
            | Error error -> `Error error
            | Ok revision -> `Requeued (matched, revision))
    in
    (match result with
     | `Requeued (receipts, revision) ->
       notify_transition ~keeper_name ~revision;
       `Requeued receipts
     | `Unknown_lease -> `Unknown_lease
     | `Error error -> `Error error)

let merge_batch (items : leased_message list) =
  match items with
  | [] -> None
  | [ item ] -> Some item.message
  | first :: _ ->
    Some
      { content =
          String.concat "\n\n"
            (List.map
               (fun (item : leased_message) -> item.message.content)
               items)
      ; user_blocks =
          List.concat_map
            (fun (item : leased_message) -> item.message.user_blocks)
            items
      ; attachments =
          List.concat_map
            (fun (item : leased_message) -> item.message.attachments)
            items
      ; timestamp = first.message.timestamp
      ; source = first.message.source
      }

let pending_count ~keeper_name =
  match mutation_entry ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) -> Ok 0
  | Ok (_, _, Some entry) ->
    with_entry_lock entry (fun () -> Ok (List.length (pending_receipts entry.receipts)))

let inflight_count ~keeper_name =
  match mutation_entry ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) -> Ok 0
  | Ok (_, _, Some entry) ->
    with_entry_lock entry (fun () -> Ok (List.length (inflight_receipts entry.receipts)))

let has_active_receipts ~keeper_name =
  match mutation_entry ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) -> Ok false
  | Ok (_, _, Some entry) ->
    with_entry_lock entry (fun () ->
        Ok
          (List.exists
             (fun receipt ->
                match receipt.state with
                | Stored_pending _ | Stored_inflight _ -> true
                | Stored_delivered _ | Stored_failed _ -> false)
             entry.receipts))

let receipt_state_of_stored = function
  | Stored_pending _ -> Pending
  | Stored_inflight { lease_id; started_at; _ } -> Inflight { lease_id; started_at }
  | Stored_delivered completion -> Delivered completion
  | Stored_failed failure -> Failed failure

let snapshot ~keeper_name =
  match find_entry keeper_name with
  | None ->
    { revision = 0L
    ; pending = []
    ; inflight = []
    ; terminal = []
    ; load_errors = Atomic.get global_load_errors
    }
  | Some entry ->
    with_entry_lock entry (fun () ->
        let pending, inflight, terminal =
          List.fold_left
            (fun (pending, inflight, terminal) receipt ->
               match receipt.state with
               | Stored_pending message ->
                 ( { receipt_id = receipt.receipt_id; message; state = Pending } :: pending
                 , inflight
                 , terminal )
               | Stored_inflight ({ message; _ } as state) ->
                 ( pending
                 , { receipt_id = receipt.receipt_id
                   ; message
                   ; state = receipt_state_of_stored (Stored_inflight state)
                   }
                   :: inflight
                 , terminal )
               | Stored_delivered _ | Stored_failed _ ->
                 ( pending
                 , inflight
                 , ({ receipt_id = receipt.receipt_id
                    ; state = receipt_state_of_stored receipt.state
                    } : receipt_view)
                   :: terminal ))
            ([], [], []) entry.receipts
        in
        { revision = entry.revision
        ; pending = List.rev pending
        ; inflight = List.rev inflight
        ; terminal = List.rev terminal
        ; load_errors = entry.load_errors @ Atomic.get global_load_errors
        })

let lookup_receipt ~keeper_name ~receipt_id =
  match mutation_entry ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) -> Ok { revision = 0L; receipt = None }
  | Ok (_, _, Some entry) ->
    with_entry_lock entry (fun () ->
        let receipt =
          List.find_map
            (fun receipt ->
               if Receipt_id.equal receipt.receipt_id receipt_id
               then
                 Some
                   ({ receipt_id = receipt.receipt_id
                    ; state = receipt_state_of_stored receipt.state
                    } : receipt_view)
               else None)
            entry.receipts
        in
        Ok { revision = entry.revision; receipt })

let all_keeper_names () =
  with_registry_rw (fun () ->
      Hashtbl.fold (fun keeper_name _ names -> keeper_name :: names) registry [])

let configure_persistence ~base_path =
  Atomic.set persistence_base_path None;
  Atomic.set global_load_errors [];
  (* BasePath is the queue ownership boundary. A reconfiguration must not make
     an in-memory entry from the previous workspace appear in the new one. *)
  with_registry_rw (fun () -> Hashtbl.clear registry);
  let restored_keeper_count = ref 0 in
  let migrated_keeper_count = ref 0 in
  let recovered_receipt_count = ref 0 in
  let load_errors = ref [] in
  let restored_mutations = ref [] in
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  let keeper_names =
    let inventory_error kind reason =
      let error =
        load_error kind ~path:keepers_dir
          ("failed to discover keeper chat queue snapshots: " ^ reason)
      in
      load_errors := (None, error) :: !load_errors;
      Atomic.set global_load_errors [ error ];
      []
    in
    (match
       try Ok (Fs_compat.path_kind keepers_dir) with
       | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
       | exception_ -> Error exception_
     with
     | Error exception_ ->
       inventory_error Read_failed (Printexc.to_string exception_)
     | Ok Fs_compat.Missing -> []
     | Ok Fs_compat.Other ->
       inventory_error Invalid_path "keeper runtime inventory is not a directory"
     | Ok Fs_compat.Directory ->
       (try Fs_compat.read_dir keepers_dir with
        | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
        | exception_ -> inventory_error Read_failed (Printexc.to_string exception_)))
  in
  List.iter
    (fun keeper_name ->
       let keeper_dir = Filename.concat keepers_dir keeper_name in
       let path = Filename.concat keeper_dir persistence_file in
       match
         try Ok (Fs_compat.path_kind keeper_dir) with
         | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
         | exception_ ->
           Error
             (load_error Read_failed ~path:keeper_dir (Printexc.to_string exception_))
       with
       | Error error ->
         load_errors := (Some keeper_name, error) :: !load_errors
       | Ok (Fs_compat.Missing | Fs_compat.Other) -> ()
       | Ok Fs_compat.Directory ->
         (match
            try Ok (Fs_compat.path_kind path) with
            | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
            | exception_ ->
              Error
                (load_error Read_failed ~path (Printexc.to_string exception_))
          with
          | Error error ->
            load_errors := (Some keeper_name, error) :: !load_errors
          | Ok Fs_compat.Missing -> ()
          | Ok (Fs_compat.Directory | Fs_compat.Other) ->
         if not (valid_keeper_name keeper_name)
         then
           let error =
             load_error Invalid_path ~path
               (Printf.sprintf "invalid snapshot-bearing keeper name: %s" keeper_name)
           in
           load_errors := (Some keeper_name, error) :: !load_errors
         else
           match load_snapshot ~base_path ~keeper_name with
           | Ok None -> ()
           | Ok (Some loaded) ->
             incr restored_keeper_count;
             if loaded.migrated then incr migrated_keeper_count;
             recovered_receipt_count :=
               !recovered_receipt_count + loaded.recovered_count;
             with_registry_rw (fun () ->
               Hashtbl.replace registry keeper_name
                 (create_entry ~revision:loaded.revision
                    ~receipts:loaded.receipts ()));
             if loaded.migrated || loaded.recovered_count > 0
             then
               restored_mutations :=
                 (keeper_name, loaded.revision) :: !restored_mutations
           | Error error ->
             load_errors := (Some keeper_name, error) :: !load_errors;
             with_registry_rw (fun () ->
               Hashtbl.replace registry keeper_name
                 (create_entry ~load_errors:[ error ] ()))))
    keeper_names;
  Atomic.set persistence_base_path (Some base_path);
  List.rev !restored_mutations
  |> List.iter (fun (keeper_name, revision) ->
         notify_transition ~keeper_name ~revision);
  { restored_keeper_count = !restored_keeper_count
  ; migrated_keeper_count = !migrated_keeper_count
  ; recovered_receipt_count = !recovered_receipt_count
  ; load_errors = List.rev !load_errors
  }

module For_testing = struct
  let reset () =
    Atomic.set fail_next_persist_for_testing false;
    Atomic.set persistence_base_path None;
    Atomic.set global_load_errors [];
    Atomic.set transition_observer None;
    with_registry_rw (fun () -> Hashtbl.clear registry)

  let fail_next_persist () = Atomic.set fail_next_persist_for_testing true
  let failure_kind_of_string = failure_kind_of_string
  let snapshot_path = snapshot_path
end
