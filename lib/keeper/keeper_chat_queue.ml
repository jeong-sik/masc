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

type transcript_context =
  { surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; speaker : Keeper_chat_store.speaker
  ; extra_mentions : Keeper_identity.Keeper_id.t list
  }

type transcript_ownership =
  | Queue_owned
  | Upstream_recorded

type queued_message = {
  content : string;
  user_blocks : Keeper_multimodal_input.user_input_block list;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
  transcript_context : transcript_context option;
  transcript_ownership : transcript_ownership;
}

module Receipt_id = struct
  type t = string

  let prefix = "chatq_"
  (* Random UUID bits are an opaque durable identity salt. They are persisted
     before acceptance and never choose lifecycle policy or control flow. *)
  (* NDT-OK: identity entropy only; never a lifecycle decision input. *)
  let rng = Random.State.make_self_init ()
  let rng_mutex = Stdlib.Mutex.create ()

  let generate () =
    let uuid =
      Stdlib.Mutex.protect rng_mutex (fun () -> Uuidm.v4_gen rng ())
    in
    prefix ^ Uuidm.to_string uuid

  let of_string raw =
    let prefix_len = String.length prefix in
    if String.length raw <= prefix_len
       || not (String.equal (String.sub raw 0 prefix_len) prefix)
    then Error "chat queue receipt id must start with chatq_"
    else
      let uuid = String.sub raw prefix_len (String.length raw - prefix_len) in
      match Uuidm.of_string uuid with
      | Some _ -> Ok raw
      | None -> Error "chat queue receipt id must contain a UUID"

  let to_string id = id
  let equal = String.equal
end

type completion = {
  completed_at : float;
  outcome_ref : string option;
}

type failure_kind =
  | Turn_failed
  | Timed_out
  | No_visible_reply
  | Transcript_persist_failed
  | Connector_unavailable
  | Delivery_failed
  | Ambiguous_delivery
  | Cancelled
  | Internal_error

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
  reused : bool;
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
  | Stored_failed of
      { failure : failure
      ; retained_message : queued_message option
      }

type stored_receipt = {
  receipt_id : Receipt_id.t;
  dedupe_fingerprint : string option;
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
let schema_v3 = "keeper_chat_queue.v3"
(* Revisions cross the JSON/JavaScript dashboard boundary as numbers. Keep the
   persisted domain within IEEE-754's exact integer range instead of accepting
   all int64 values and silently losing identity in the browser. *)
let max_revision = 9_007_199_254_740_991L
let persistence_file = "chat-queue.json"
let persistence_keepers_dir : string option Atomic.t = Atomic.make None
let global_load_errors : snapshot_load_error list Atomic.t = Atomic.make []
let fail_next_persist_for_testing = Atomic.make false
let before_persist_for_testing : (path:string -> unit) option Atomic.t =
  Atomic.make None
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

let snapshot_path ~keepers_dir ~keeper_name =
  if valid_keeper_name keeper_name
  then
    Ok
      (Filename.concat
         (Filename.concat keepers_dir keeper_name)
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

let speaker_authority_to_string = function
  | Keeper_chat_store.Owner -> "owner"
  | Keeper_chat_store.External -> "external"

let speaker_authority_of_string = function
  | "owner" -> Ok Keeper_chat_store.Owner
  | "external" -> Ok Keeper_chat_store.External
  | value ->
    Error (Printf.sprintf "unknown chat queue speaker authority: %s" value)

let speaker_to_yojson (speaker : Keeper_chat_store.speaker) =
  `Assoc
    [ ( "speaker_id"
      , Option.fold ~none:`Null ~some:(fun value -> `String value)
          speaker.speaker_id )
    ; ( "speaker_name"
      , Option.fold ~none:`Null ~some:(fun value -> `String value)
          speaker.speaker_name )
    ; ( "speaker_authority"
      , `String (speaker_authority_to_string speaker.speaker_authority) )
    ]

let transcript_context_to_yojson
    (context : transcript_context) =
  `Assoc
    [ "surface", Surface_ref.to_json context.surface
    ; ( "conversation_id"
      , Option.fold ~none:`Null ~some:(fun value -> `String value)
          context.conversation_id )
    ; ( "external_message_id"
      , Option.fold ~none:`Null ~some:(fun value -> `String value)
          context.external_message_id )
    ; "speaker", speaker_to_yojson context.speaker
    ; ( "extra_mentions"
      , `List
          (List.map
             (fun mention ->
                `String (Keeper_identity.Keeper_id.to_string mention))
             context.extra_mentions) )
    ]

let transcript_ownership_to_string = function
  | Queue_owned -> "queue_owned"
  | Upstream_recorded -> "upstream_recorded"

let transcript_ownership_of_string = function
  | "queue_owned" -> Ok Queue_owned
  | "upstream_recorded" -> Ok Upstream_recorded
  | value ->
    Error (Printf.sprintf "unknown transcript ownership: %s" value)

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

let speaker_of_yojson json =
  match
    optional_string json "speaker_id",
    optional_string json "speaker_name",
    required_string json "speaker_authority"
  with
  | Ok speaker_id, Ok speaker_name, Ok authority ->
    Result.map
      (fun speaker_authority ->
         ({ speaker_id; speaker_name; speaker_authority }
          : Keeper_chat_store.speaker))
      (speaker_authority_of_string authority)
  | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error

let mentions_of_yojson = function
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest ->
        (match Keeper_identity.Keeper_id.of_string value with
         | Some mention -> loop (mention :: acc) rest
         | None -> Error "chat queue transcript mention must be a Keeper id")
      | _ :: _ -> Error "chat queue transcript mentions must be strings"
    in
    loop [] values
  | _ -> Error "chat queue transcript mentions must be an array"

let transcript_context_of_yojson json =
  match
    required_member json "surface",
    optional_string json "conversation_id",
    optional_string json "external_message_id",
    required_member json "speaker",
    required_member json "extra_mentions"
  with
  | Ok surface_json, Ok conversation_id, Ok external_message_id,
    Ok speaker_json, Ok mentions_json ->
    (match
       Surface_ref.of_json surface_json,
       speaker_of_yojson speaker_json,
       mentions_of_yojson mentions_json
     with
     | Ok surface, Ok speaker, Ok extra_mentions ->
       Ok
         { surface
         ; conversation_id
         ; external_message_id
         ; speaker
         ; extra_mentions
         }
     | Error error, _, _ | _, Error error, _ | _, _, Error error ->
       Error error)
  | Error error, _, _, _, _
  | _, Error error, _, _, _
  | _, _, Error error, _, _
  | _, _, _, Error error, _
  | _, _, _, _, Error error -> Error error

let optional_transcript_context json =
  match Json_util.assoc_member_opt "transcript_context" json with
  | None | Some `Null -> Ok None
  | Some value -> Result.map Option.some (transcript_context_of_yojson value)

let external_speaker_matches user_id
    (speaker : Keeper_chat_store.speaker) =
  match speaker.speaker_authority, speaker.speaker_id with
  | Keeper_chat_store.External, Some speaker_id ->
    String.equal speaker_id user_id
  | Keeper_chat_store.Owner, _ | Keeper_chat_store.External, None -> false

let validate_transcript_context_for_source
    (message : queued_message) =
  match
    message.source,
    message.transcript_context,
    message.transcript_ownership
  with
  | Dashboard, None, Queue_owned -> Ok ()
  | Dashboard, Some context, Queue_owned ->
    (match context.surface, context.speaker.speaker_authority with
     | Surface_ref.Dashboard _, Keeper_chat_store.Owner -> Ok ()
     | _ ->
       Error
         "dashboard chat queue transcript context must use Dashboard surface and Owner speaker")
  | Dashboard, (None | Some _), Upstream_recorded ->
    Error "dashboard chat queue receipts cannot be upstream-recorded"
  | (Discord _ | Slack _), None, (Queue_owned | Upstream_recorded) ->
    Error
      "connector receipt requires exact transcript_context for either ownership decision"
  | Discord { channel_id; user_id }, Some context,
    (Queue_owned | Upstream_recorded) ->
    (match context.surface with
     | Surface_ref.Discord surface
       when String.equal surface.channel_id channel_id
            && external_speaker_matches user_id context.speaker -> Ok ()
     | _ ->
       Error
         "Discord queue source and transcript surface/speaker must identify the same channel and external user")
  | Slack { channel_id; user_id; team_id; thread_ts; _ }, Some context,
    (Queue_owned | Upstream_recorded) ->
    (match context.surface with
     | Surface_ref.Slack surface
       when String.equal surface.channel_id channel_id
            && Option.equal String.equal surface.team_id team_id
            && Option.equal String.equal surface.thread_ts thread_ts
            && external_speaker_matches user_id context.speaker -> Ok ()
     | _ ->
       Error
         "Slack queue source and transcript surface/speaker must identify the same channel, thread, team, and external user")

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
    ; ( "transcript_context"
      , Option.fold ~none:`Null ~some:transcript_context_to_yojson
          message.transcript_context )
    ; ( "transcript_ownership"
      , `String (transcript_ownership_to_string message.transcript_ownership) )
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

let queued_message_of_yojson_with_source_and_ownership source_parser
    ownership_parser json =
  match json with
  | `Assoc _ ->
    (match
       required_string json "content",
       required_float json "timestamp",
       required_member json "user_blocks",
       required_member json "attachments",
       required_member json "source",
       optional_transcript_context json
     with
     | Ok content, Ok timestamp, Ok _, Ok attachments_json, Ok source_json,
       Ok transcript_context ->
       (match
          Keeper_multimodal_input.parse_user_blocks json,
          attachments_of_yojson attachments_json,
          source_parser source_json
        with
        | Ok user_blocks, Ok attachments, Ok source ->
          Result.bind (ownership_parser json source transcript_context)
            (fun transcript_ownership ->
               let message =
                 { content
                 ; user_blocks
                 ; attachments
                 ; timestamp
                 ; source
                 ; transcript_context
                 ; transcript_ownership
                 }
               in
               Result.map (fun () -> message)
                 (validate_transcript_context_for_source message))
        | Error error, _, _ | _, Error error, _ | _, _, Error error ->
          Error error)
     | Error error, _, _, _, _, _
     | _, Error error, _, _, _, _
     | _, _, Error error, _, _, _
     | _, _, _, Error error, _, _
     | _, _, _, _, Error error, _
     | _, _, _, _, _, Error error -> Error error)
  | _ -> Error "chat queue message must be a JSON object"

let required_transcript_ownership json _source _context =
  Result.bind (required_string json "transcript_ownership")
    transcript_ownership_of_string

let legacy_transcript_ownership json source _transcript_context =
  match source with
  | Dashboard ->
    (match Json_util.assoc_member_opt "transcript_ownership" json with
     | None -> Ok Queue_owned
     | Some _ -> required_transcript_ownership json source None)
  | Discord _ | Slack _ ->
    (match Json_util.assoc_member_opt "transcript_ownership" json with
     | None ->
       Error
         "legacy active connector receipt requires an explicit transcript_ownership and exact transcript_context before queue consumption"
     | Some _ -> required_transcript_ownership json source None)

let queued_message_of_yojson json =
  queued_message_of_yojson_with_source_and_ownership source_of_yojson
    required_transcript_ownership json

let legacy_queued_message_of_yojson_with_source source_parser json =
  queued_message_of_yojson_with_source_and_ownership source_parser
    legacy_transcript_ownership json

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
  | Timed_out -> "timed_out"
  | No_visible_reply -> "no_visible_reply"
  | Transcript_persist_failed -> "transcript_persist_failed"
  | Connector_unavailable -> "connector_unavailable"
  | Delivery_failed -> "delivery_failed"
  | Ambiguous_delivery -> "ambiguous_delivery"
  | Cancelled -> "cancelled"
  | Internal_error -> "internal_error"

let failure_kind_of_string = function
  | "turn_failed" -> Ok Turn_failed
  | "timed_out" -> Ok Timed_out
  | "no_visible_reply" -> Ok No_visible_reply
  | "transcript_persist_failed" -> Ok Transcript_persist_failed
  | "connector_unavailable" -> Ok Connector_unavailable
  | "delivery_failed" -> Ok Delivery_failed
  | "ambiguous_delivery" -> Ok Ambiguous_delivery
  | "cancelled" -> Ok Cancelled
  | "internal_error" -> Ok Internal_error
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
  | Stored_failed { failure; _ } ->
    `Assoc
      (("kind", `String "failed")
       :: ("failure_kind", `String (failure_kind_to_string failure.kind))
       :: ("detail", `String failure.detail)
       :: completion_fields
            { completed_at = failure.completed_at; outcome_ref = failure.outcome_ref })

let stored_receipt_to_yojson receipt =
  let fields =
    [ "receipt_id", `String (Receipt_id.to_string receipt.receipt_id)
    ; ( "dedupe_fingerprint"
      , Option.fold ~none:`Null ~some:(fun value -> `String value)
          receipt.dedupe_fingerprint )
    ; "state", state_to_yojson receipt.state
    ]
  in
  let fields =
    match receipt.state with
    | Stored_pending message | Stored_inflight { message; _ }
    | Stored_failed { retained_message = Some message; _ } ->
      fields @ [ "message", queued_message_to_yojson message ]
    | Stored_delivered _
    | Stored_failed { retained_message = None; _ } -> fields
  in
  `Assoc fields

let snapshot_to_yojson ~revision receipts =
  `Assoc
    [ "schema", `String schema_v3
    ; "revision", `Intlit (Int64.to_string revision)
    ; "receipts", `List (List.map stored_receipt_to_yojson receipts)
    ]

let save_json_atomic path json =
  Fs_compat.mkdir_p (Filename.dirname path);
  json
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic_private path

let persist_snapshot_to_path path ~revision receipts =
  try
    Option.iter (fun before_persist -> before_persist ~path)
      (Atomic.get before_persist_for_testing);
    if Atomic.exchange fail_next_persist_for_testing false
    then Error "injected chat queue persist failure"
    else save_json_atomic path (snapshot_to_yojson ~revision receipts)
  with
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

let optional_dedupe_fingerprint json =
  match optional_string json "dedupe_fingerprint" with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) ->
    let value = String.trim value in
    if String.length value = 64
       && String.for_all
            (function
              | '0' .. '9' | 'a' .. 'f' -> true
              | _ -> false)
            value
    then Ok (Some value)
    else
      Error
        "chat queue dedupe_fingerprint must be a lowercase SHA-256 hex value"

let reject_terminal_message json =
  match Json_util.assoc_member_opt "message" json with
  | None -> Ok ()
  | Some _ -> Error "terminal chat queue receipts must not retain message bodies"

let retained_failed_message ~message_parser json =
  match Json_util.assoc_member_opt "message" json with
  | None -> Ok None
  | Some message_json -> Result.map Option.some (message_parser message_json)

let stored_receipt_of_yojson ~message_parser json =
  match json with
  | `Assoc _ ->
    (match
       parse_receipt_id json,
       optional_dedupe_fingerprint json,
       required_member json "state"
     with
     | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error
     | Ok receipt_id, Ok dedupe_fingerprint, Ok state_json ->
       (match required_string state_json "kind" with
        | Error _ as error -> error
        | Ok "pending" ->
          (match required_member json "message" with
           | Error _ as error -> error
           | Ok message_json ->
             Result.map
               (fun message ->
                  { receipt_id; dedupe_fingerprint; state = Stored_pending message })
               (message_parser message_json))
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
                  ; dedupe_fingerprint
                  ; state = Stored_inflight { lease_id; started_at; message }
                  })
               (message_parser message_json)
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
             Ok
               { receipt_id
               ; dedupe_fingerprint
               ; state = Stored_delivered { completed_at; outcome_ref }
               }
           | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error)
        | Ok "failed" ->
          (match
             required_float state_json "completed_at",
             required_string state_json "failure_kind",
             required_string state_json "detail",
             optional_string state_json "outcome_ref"
           with
           | Ok completed_at, Ok kind_label, Ok detail, Ok outcome_ref
             when String.trim detail <> "" ->
             Result.bind (failure_kind_of_string kind_label) (fun kind ->
               Result.map
                 (fun retained_message ->
                    { receipt_id
                    ; dedupe_fingerprint
                    ; state =
                        Stored_failed
                          { failure =
                              { completed_at; kind; detail; outcome_ref }
                          ; retained_message
                          }
                    })
                 (retained_failed_message ~message_parser json))
           | Ok _, Ok _, Ok _, Ok _ ->
             Error "failed chat queue receipt detail must be non-empty"
           | Error error, _, _, _
           | _, Error error, _, _
           | _, _, Error error, _
           | _, _, _, Error error -> Error error)
        | Ok kind -> Error (Printf.sprintf "unknown chat queue receipt state: %s" kind)))
  | _ -> Error "chat queue receipt must be an object"

let parse_receipt_list ~message_parser json =
  match json with
  | `List values ->
    let seen = Hashtbl.create (List.length values) in
    let seen_dedupe = Hashtbl.create (List.length values) in
    let rec loop seen acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match stored_receipt_of_yojson ~message_parser value with
         | Error _ as error -> error
         | Ok receipt ->
           let id = Receipt_id.to_string receipt.receipt_id in
           if Hashtbl.mem seen id
           then Error (Printf.sprintf "duplicate chat queue receipt_id: %s" id)
           else
             (match receipt.dedupe_fingerprint with
              | Some fingerprint when Hashtbl.mem seen_dedupe fingerprint ->
                Error
                  (Printf.sprintf
                     "duplicate chat queue dedupe_fingerprint: %s"
                     fingerprint)
              | fingerprint ->
                Hashtbl.add seen id ();
                Option.iter
                  (fun value -> Hashtbl.add seen_dedupe value ())
                  fingerprint;
                loop seen (receipt :: acc) rest))
    in
    loop seen [] values
  | _ -> Error "chat queue receipts must be an array"

let parse_snapshot ~message_parser json =
  match parse_revision json, required_member json "receipts" with
  | Ok revision, Ok receipts_json ->
    (match parse_receipt_list ~message_parser receipts_json with
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
              "chat queue snapshot permits at most one same-source inflight lease per keeper"))
  | Error error, _ | _, Error error -> Error error

let parse_message_list json =
  match json with
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match
           legacy_queued_message_of_yojson_with_source source_of_v1_yojson value
         with
         | Error _ as error -> error
         | Ok message -> loop (message :: acc) rest)
    in
    loop [] values
  | _ -> Error "legacy chat queue items must be an array"

let recovery_completed_at () =
  let now = Time_compat.now () in
  if Float.is_finite now then now else 0.0

let ambiguous_delivery_failure ~lease_id ~started_at =
  let lease_detail =
    match started_at with
    | None -> Printf.sprintf "lease=%s" lease_id
    | Some started_at ->
      Printf.sprintf "lease=%s started_at=%.17g" lease_id started_at
  in
  { completed_at = recovery_completed_at ()
  ; kind = Ambiguous_delivery
  ; detail =
      Printf.sprintf
        "process restarted with an unfinalized inflight %s; transcript or connector effects may already be durable, so automatic replay is suppressed"
        lease_detail
  ; outcome_ref = None
  }

let parse_v1_inflight json =
  match Json_util.assoc_member_opt "inflight" json with
  | None | Some `Null -> Ok None
  | Some (`Assoc _ as inflight) ->
    (match required_string inflight "lease_id", required_member inflight "items" with
     | Ok lease_id, Ok items_json when String.trim lease_id <> "" ->
       Result.map
         (fun messages -> Some (lease_id, messages))
         (parse_message_list items_json)
     | Ok _, Ok _ -> Error "legacy inflight lease_id must be non-empty"
     | Error error, _ | _, Error error -> Error error)
  | Some _ -> Error "legacy chat queue inflight must be null or an object"

let parse_v1_for_migration json =
  match required_member json "items", parse_v1_inflight json with
  | Ok items_json, Ok inflight ->
    Result.map (fun pending -> inflight, pending) (parse_message_list items_json)
  | Error error, _ | _, Error error -> Error error

let migrate_v1_to_v3 path json =
  match parse_v1_for_migration json with
  | Error error -> Error (`Parse error)
  | Ok (inflight, pending) ->
    let receipt state =
      { receipt_id = Receipt_id.generate (); dedupe_fingerprint = None; state }
    in
    let inflight_receipts, recovered_count =
      match inflight with
      | None -> [], 0
      | Some (lease_id, messages) ->
        ( List.map
            (fun message ->
               receipt
                 (Stored_failed
                    { failure =
                        ambiguous_delivery_failure ~lease_id
                          ~started_at:None
                    ; retained_message = Some message
                    }))
            messages
        , List.length messages )
    in
    let receipts =
      inflight_receipts
      @ List.map (fun message -> receipt (Stored_pending message)) pending
    in
    let revision = 1L in
    (match persist_snapshot_to_path path ~revision receipts with
     | Ok () -> Ok (revision, receipts, recovered_count)
     | Error error -> Error (`Persist error))

type loaded_snapshot = {
  revision : int64;
  receipts : stored_receipt list;
  migrated : bool;
  recovered_count : int;
}

let load_error kind ?path message = { kind; path; message }

let recover_inflight path ~revision receipts =
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
    let receipts =
      List.map
        (fun receipt ->
           match receipt.state with
           | Stored_inflight { lease_id; started_at; message } ->
             { receipt with
               state =
                 Stored_failed
                   { failure =
                       ambiguous_delivery_failure ~lease_id
                         ~started_at:(Some started_at)
                   ; retained_message = Some message
                   }
             }
           | Stored_pending _ | Stored_delivered _ | Stored_failed _ -> receipt)
        receipts
    in
    if Int64.compare revision max_revision >= 0
    then
      Error
        (load_error Recovery_failed ~path
           "cannot persist restart recovery: chat queue revision domain is exhausted")
    else
      let revision = Int64.succ revision in
      match persist_snapshot_to_path path ~revision receipts with
      | Ok () -> Ok { revision; receipts; migrated = false; recovered_count }
      | Error error ->
        Error
          (load_error Recovery_failed ~path
             ("failed to persist restart recovery: " ^ error))

let migrate_snapshot_to_v3 path ~revision receipts =
  let has_inflight =
    List.exists
      (fun receipt ->
         match receipt.state with
         | Stored_inflight _ -> true
         | Stored_pending _ | Stored_delivered _ | Stored_failed _ -> false)
      receipts
  in
  if has_inflight
  then
    Result.map
      (fun loaded -> { loaded with migrated = true })
      (recover_inflight path ~revision receipts)
  else
    match persist_snapshot_to_path path ~revision receipts with
    | Ok () ->
      Ok { revision; receipts; migrated = true; recovered_count = 0 }
    | Error error ->
      Error
        (load_error Migration_failed ~path
           ("failed to persist chat queue v3 migration: " ^ error))

let source_json_is_connector (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String ("discord" | "slack")) -> true
     | Some (`String _) | Some _ | None -> false)
  | _ -> false

let message_json_has_ambiguous_legacy_connector (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let context_absent =
      match List.assoc_opt "transcript_context" fields with
      | None | Some `Null -> true
      | Some _ -> false
    in
    let ownership_absent =
      match List.assoc_opt "transcript_ownership" fields with
      | None | Some `Null -> true
      | Some _ -> false
    in
    (context_absent || ownership_absent)
    && (match List.assoc_opt "source" fields with
        | Some source -> source_json_is_connector source
        | None -> false)
  | _ -> false

let v2_has_ambiguous_active_connector (json : Yojson.Safe.t) =
  match Json_util.assoc_member_opt "receipts" json with
  | Some (`List receipts) ->
    List.exists
      (fun (receipt_json : Yojson.Safe.t) ->
        match receipt_json with
        | `Assoc fields ->
          let active =
            match List.assoc_opt "state" fields with
            | Some (`Assoc state_fields) ->
              (match List.assoc_opt "kind" state_fields with
               | Some (`String ("pending" | "inflight")) -> true
               | Some (`String _) | Some _ | None -> false)
            | Some _ | None -> false
          in
          active
          && (match List.assoc_opt "message" fields with
              | Some message ->
                message_json_has_ambiguous_legacy_connector message
              | None -> false)
        | _ -> false)
      receipts
  | Some _ | None -> false

let v1_has_ambiguous_active_connector (json : Yojson.Safe.t) =
  let messages_from = function
    | Some (`List messages) -> messages
    | Some _ | None -> []
  in
  let pending =
    messages_from (Json_util.assoc_member_opt "items" json)
  in
  let inflight =
    match Json_util.assoc_member_opt "inflight" json with
    | Some (`Assoc fields) -> messages_from (List.assoc_opt "items" fields)
    | Some _ | None -> []
  in
  List.exists message_json_has_ambiguous_legacy_connector (pending @ inflight)

let load_snapshot ~keepers_dir ~keeper_name =
  match snapshot_path ~keepers_dir ~keeper_name with
  | Error message -> Error (load_error Invalid_path message)
  | Ok path ->
    if not (Sys.file_exists path)
    then Ok None
    else
      match Safe_ops.read_file_safe path with
      | Error message -> Error (load_error Read_failed ~path message)
      | Ok content ->
        (match Safe_ops.parse_json_safe ~context:path content with
         | Error message -> Error (load_error Parse_failed ~path message)
         | Ok json ->
        (match required_string json "schema" with
         | Error message -> Error (load_error Parse_failed ~path message)
         | Ok schema when String.equal schema schema_v3 ->
           (match parse_snapshot ~message_parser:queued_message_of_yojson json with
            | Error message -> Error (load_error Parse_failed ~path message)
            | Ok (revision, receipts) ->
              Result.map Option.some (recover_inflight path ~revision receipts))
         | Ok schema when String.equal schema schema_v2 ->
           if v2_has_ambiguous_active_connector json
           then
             Error
               (load_error Migration_failed ~path
                  "legacy v2 contains active connector receipts without both an exact transcript_context and explicit transcript_ownership; reconcile each before startup")
           else
             (match
                parse_snapshot
                  ~message_parser:
                    (legacy_queued_message_of_yojson_with_source source_of_yojson)
                  json
              with
              | Error message -> Error (load_error Parse_failed ~path message)
              | Ok (revision, receipts) ->
                Result.map Option.some
                  (migrate_snapshot_to_v3 path ~revision receipts))
         | Ok schema when String.equal schema schema_v1 ->
           if v1_has_ambiguous_active_connector json
           then
             Error
               (load_error Migration_failed ~path
                  "legacy v1 contains active connector messages without both an exact transcript_context and explicit transcript_ownership; reconcile them before startup")
           else
           (match migrate_v1_to_v3 path json with
            | Ok (revision, receipts, recovered_count) ->
              Ok (Some { revision; receipts; migrated = true; recovered_count })
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

let persistence_configured () = Option.is_some (Atomic.get persistence_keepers_dir)

let persistence_matches_config ~config =
  match Atomic.get persistence_keepers_dir with
  | None -> false
  | Some configured_dir ->
    String.equal configured_dir (Workspace.keepers_runtime_dir config)

let first_snapshot_error entry =
  match entry.load_errors with
  | error :: _ -> Some error
  | [] -> None

let mutation_entry ~keeper_name ~create =
  match Atomic.get persistence_keepers_dir with
  | None -> Error Persistence_not_configured
  | Some keepers_dir ->
    (match snapshot_path ~keepers_dir ~keeper_name with
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
       | None -> Ok (keepers_dir, path, None)
       | Some entry ->
         (match first_snapshot_error entry with
          | Some error -> Error (Snapshot_unavailable error)
          | None -> Ok (keepers_dir, path, Some entry)))

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

let dedupe_source_scope = function
  | Dashboard -> `Assoc [ "kind", `String "dashboard" ]
  | Discord { channel_id; user_id } ->
    `Assoc
      [ "kind", `String "discord"
      ; "channel_id", `String channel_id
      ; "user_id", `String user_id
      ]
  | Slack { channel_id; user_id; team_id; thread_ts; _ } ->
    `Assoc
      [ "kind", `String "slack"
      ; "channel_id", `String channel_id
      ; "user_id", `String user_id
      ; ( "team_id"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) team_id )
      ; ( "thread_ts"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) thread_ts )
      ]

let dedupe_fingerprint ~keeper_name ~source idempotency_key =
  let idempotency_key = String.trim idempotency_key in
  if idempotency_key = ""
  then Error "idempotency_key must be non-empty when present"
  else if not (String.is_valid_utf_8 idempotency_key)
  then Error "idempotency_key contains malformed UTF-8"
  else
    let canonical =
      `Assoc
        [ "keeper_name", `String keeper_name
        ; "source", dedupe_source_scope source
        ; "idempotency_key", `String idempotency_key
        ]
      |> Yojson.Safe.to_string
    in
    Ok (Digestif.SHA256.(digest_string canonical |> to_hex))

let enqueue ?idempotency_key ~keeper_name message =
  let receipt_id = Receipt_id.generate () in
  match canonical_queued_message message with
  | Error message -> Error (Invalid_input message)
  | Ok message ->
  let dedupe_fingerprint =
    match idempotency_key with
    | None -> Ok None
    | Some key ->
      Result.map Option.some
        (dedupe_fingerprint ~keeper_name ~source:message.source key)
  in
  (match dedupe_fingerprint with
  | Error message -> Error (Invalid_input message)
  | Ok dedupe_fingerprint ->
  match mutation_entry ~keeper_name ~create:true with
  | Error _ as error -> error
  | Ok (_, _, None) ->
    Error (Persist_failed "chat queue entry creation did not produce an entry")
  | Ok (_, path, Some entry) ->
    let result =
      with_entry_lock entry (fun () ->
          let existing =
            Option.bind dedupe_fingerprint (fun fingerprint ->
                List.find_opt
                  (fun receipt ->
                     Option.equal String.equal receipt.dedupe_fingerprint
                       (Some fingerprint))
                  entry.receipts)
          in
          match existing with
          | Some existing ->
            Ok
              { receipt_id = existing.receipt_id
              ; revision = entry.revision
              ; pending_count = List.length (pending_receipts entry.receipts)
              ; inflight_count = List.length (inflight_receipts entry.receipts)
              ; reused = true
              }
          | None ->
            let receipt =
              { receipt_id; dedupe_fingerprint; state = Stored_pending message }
            in
            let receipts = entry.receipts @ [ receipt ] in
            (match commit entry ~path receipts with
             | Error _ as error -> error
             | Ok revision ->
               Ok
                 { receipt_id
                 ; revision
                 ; pending_count = List.length (pending_receipts receipts)
                 ; inflight_count = List.length (inflight_receipts receipts)
                 ; reused = false
                 }))
    in
    (match result with
     | Ok receipt when not receipt.reused ->
       notify_transition ~keeper_name ~revision:receipt.revision;
       Ok receipt
     | Ok receipt -> Ok receipt
     | Error _ as error -> error))

let lease_id () =
  "lease_"
  ^ Uuidm.to_string
      (Stdlib.Mutex.protect Receipt_id.rng_mutex (fun () ->
           Uuidm.v4_gen Receipt_id.rng ()))

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
                List.map
                  (fun (item : leased_message) ->
                     Receipt_id.to_string item.receipt_id)
                  items
              in
              let receipts =
                List.map
                  (fun receipt ->
                     match receipt.state with
                     | Stored_pending message
                       when List.mem
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
        (fun outcome_ref ->
           Stored_failed
             { failure = { failure with detail; outcome_ref }
             ; retained_message = None
             })
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
                     let state =
                       match terminal_state with
                       | Stored_failed failed ->
                         Stored_failed
                           { failed with retained_message = Some current.message }
                       | Stored_pending _ | Stored_inflight _
                       | Stored_delivered _ -> terminal_state
                     in
                     { receipt with state }
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
      ; transcript_context = first.message.transcript_context
      ; transcript_ownership = first.message.transcript_ownership
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
  | Stored_failed { failure; _ } -> Failed failure

let snapshot ~keeper_name =
  match find_entry keeper_name with
  | None ->
    { revision = 0L
    ; pending = []
    ; inflight = []
    ; terminal = []
    ; load_errors = []
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
        ; load_errors = entry.load_errors
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

let configuration_errors () = Atomic.get global_load_errors

let discover_keeper_entries keepers_dir =
  if not (Sys.file_exists keepers_dir)
  then Ok []
  else
    try Ok (Array.to_list (Sys.readdir keepers_dir)) with
    | exception_ ->
      Error
        (load_error Read_failed ~path:keepers_dir
           ("failed to discover keeper chat queue snapshots: "
            ^ Printexc.to_string exception_))
;;

let configure_persistence ~config =
  Atomic.set persistence_keepers_dir None;
  Atomic.set global_load_errors [];
  (* The canonical cluster Keeper root is the queue ownership boundary. A
     reconfiguration must not make an in-memory entry from the previous
     workspace/cluster appear in the new one. *)
  with_registry_rw (fun () -> Hashtbl.clear registry);
  let restored_keeper_count = ref 0 in
  let migrated_keeper_count = ref 0 in
  let recovered_receipt_count = ref 0 in
  let load_errors = ref [] in
  let global_errors = ref [] in
  let restored_mutations = ref [] in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let fail_configuration error =
    Atomic.set global_load_errors [ error ];
    { restored_keeper_count = 0
    ; migrated_keeper_count = 0
    ; recovered_receipt_count = 0
    ; load_errors = [ None, error ]
    }
  in
  match discover_keeper_entries keepers_dir with
  | Error error -> fail_configuration error
  | Ok keeper_names ->
    (* [keepers_dir] is already the explicit workspace/cluster ownership
       decision. Never inspect or infer from the default cluster's legacy root:
       a non-default cluster starts from its own canonical namespace, and any
       operator migration is an out-of-band exact copy into that namespace. *)
    List.iter
      (fun keeper_name ->
         let path =
           Filename.concat
             (Filename.concat keepers_dir keeper_name)
             persistence_file
         in
         if Sys.file_exists path
         then if not (valid_keeper_name keeper_name)
           then
             let error =
               load_error Invalid_path ~path
                 (Printf.sprintf
                    "invalid snapshot-bearing keeper name: %s"
                    keeper_name)
             in
             load_errors := (Some keeper_name, error) :: !load_errors;
             global_errors := error :: !global_errors
           else
             match load_snapshot ~keepers_dir ~keeper_name with
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
                     (create_entry ~load_errors:[ error ] ())))
      keeper_names;
    Atomic.set global_load_errors (List.rev !global_errors);
    Atomic.set persistence_keepers_dir (Some keepers_dir);
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
    Atomic.set before_persist_for_testing None;
    Atomic.set persistence_keepers_dir None;
    Atomic.set global_load_errors [];
    Atomic.set transition_observer None;
    with_registry_rw (fun () -> Hashtbl.clear registry)

  let fail_next_persist () = Atomic.set fail_next_persist_for_testing true
  let set_before_persist callback = Atomic.set before_persist_for_testing callback
end
