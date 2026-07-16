(** Durable per-Keeper chat receipt queue. *)

type message_source =
  | Dashboard of { thread_id : string }
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
  user_row_origin : Keeper_chat_store.user_row_origin;
}

module Receipt_id = Keeper_chat_delivery_identity.Receipt_id

type completion = {
  completed_at : float;
  outcome_ref : string option;
}

type failure_kind =
  | Turn_failed
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
  | Recovery_required of { lease_id : string; started_at : float }
  | Delivered of completion
  | Failed of failure

type leased_message = {
  receipt_id : Receipt_id.t;
  message : queued_message;
}

type lease = {
  lease_id : string;
  item : leased_message;
}

type recovery_evidence = {
  receipt_id : Receipt_id.t;
  lease_id : string;
  started_at : float;
}

type finalization =
  | Mark_delivered of completion
  | Mark_failed of failure

type snapshot_load_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Recovery_failed
  | Durability_uncertain
  | Reconciliation_failed
  | Configuration_conflict

type snapshot_load_error = {
  kind : snapshot_load_error_kind;
  path : string option;
  message : string;
}

type persistence_publication =
  | Not_published
  | Enqueue_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      }
  | Lease_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Finalize_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Nack_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Startup_recovery_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Recovery_requeue_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Recovery_cancel_indeterminate of
      { revision : int64
      ; receipt_id : Receipt_id.t
      ; lease_id : string
      }

type persistence_failure =
  { publication : persistence_publication
  ; detail : string
  }

type mutation_error =
  | Persistence_not_configured
  | Snapshot_unavailable of snapshot_load_error
  | Invalid_input of string
  | Receipt_already_terminal of
      { receipt_id : Receipt_id.t
      ; state : receipt_state
      }
  | Receipt_not_recovery_required of
      { receipt_id : Receipt_id.t
      ; observed_state : receipt_state option
      }
  | Recovery_revision_mismatch of
      { receipt_id : Receipt_id.t
      ; expected_revision : int64
      ; observed_revision : int64
      }
  | Recovery_lease_mismatch of
      { receipt_id : Receipt_id.t
      ; expected_lease_id : string
      ; observed_lease_id : string
      }
  | Revision_exhausted
  | Persist_failed of persistence_failure

let snapshot_load_error_kind_to_string = function
  | Invalid_path -> "invalid_path"
  | Read_failed -> "read_failed"
  | Parse_failed -> "parse_failed"
  | Recovery_failed -> "recovery_failed"
  | Durability_uncertain -> "durability_uncertain"
  | Reconciliation_failed -> "reconciliation_failed"
  | Configuration_conflict -> "configuration_conflict"

type persistence_transition =
  | Enqueue_transition of { receipt_id : Receipt_id.t }
  | Lease_transition of { receipt_id : Receipt_id.t; lease_id : string }
  | Finalize_transition of { receipt_id : Receipt_id.t; lease_id : string }
  | Nack_transition of { receipt_id : Receipt_id.t; lease_id : string }
  | Startup_recovery_transition of
      { receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Recovery_requeue_transition of
      { receipt_id : Receipt_id.t
      ; lease_id : string
      }
  | Recovery_cancel_transition of
      { receipt_id : Receipt_id.t
      ; lease_id : string
      }

let persistence_transition_to_string = function
  | Enqueue_transition _ -> "enqueue"
  | Lease_transition _ -> "lease"
  | Finalize_transition _ -> "finalize"
  | Nack_transition _ -> "nack"
  | Startup_recovery_transition _ -> "startup_recovery"
  | Recovery_requeue_transition _ -> "recovery_requeue"
  | Recovery_cancel_transition _ -> "recovery_cancel"

let transition_receipt_id = function
  | Enqueue_transition { receipt_id }
  | Lease_transition { receipt_id; _ }
  | Finalize_transition { receipt_id; _ }
  | Nack_transition { receipt_id; _ }
  | Startup_recovery_transition { receipt_id; _ }
  | Recovery_requeue_transition { receipt_id; _ }
  | Recovery_cancel_transition { receipt_id; _ } -> receipt_id

let publication_transition = function
  | Not_published -> None
  | Enqueue_indeterminate _ -> Some "enqueue"
  | Lease_indeterminate _ -> Some "lease"
  | Finalize_indeterminate _ -> Some "finalize"
  | Nack_indeterminate _ -> Some "nack"
  | Startup_recovery_indeterminate _ -> Some "startup_recovery"
  | Recovery_requeue_indeterminate _ -> Some "recovery_requeue"
  | Recovery_cancel_indeterminate _ -> Some "recovery_cancel"

let publication_evidence = function
  | Not_published -> None
  | Enqueue_indeterminate { revision; receipt_id }
  | Lease_indeterminate { revision; receipt_id; _ }
  | Finalize_indeterminate { revision; receipt_id; _ }
  | Nack_indeterminate { revision; receipt_id; _ }
  | Startup_recovery_indeterminate { revision; receipt_id; _ }
  | Recovery_requeue_indeterminate { revision; receipt_id; _ }
  | Recovery_cancel_indeterminate { revision; receipt_id; _ } ->
    Some (revision, receipt_id)

let publication_lease_id = function
  | Lease_indeterminate { lease_id; _ }
  | Finalize_indeterminate { lease_id; _ }
  | Nack_indeterminate { lease_id; _ }
  | Startup_recovery_indeterminate { lease_id; _ }
  | Recovery_requeue_indeterminate { lease_id; _ }
  | Recovery_cancel_indeterminate { lease_id; _ } -> Some lease_id
  | Not_published | Enqueue_indeterminate _ -> None

let receipt_state_kind_to_string = function
  | Pending -> "pending"
  | Inflight _ -> "inflight"
  | Recovery_required _ -> "recovery_required"
  | Delivered _ -> "delivered"
  | Failed _ -> "failed"

let persistence_failure_to_string failure =
  match failure.publication with
  | Not_published -> "not published: " ^ failure.detail
  | publication ->
    (match publication_transition publication, publication_evidence publication with
     | Some transition, Some (revision, receipt_id) ->
       Printf.sprintf
         "transition %s published with indeterminate durability at revision %Ld for receipt %s; do not resubmit, reconcile by receipt id: %s"
         transition
         revision
         (Receipt_id.to_string receipt_id)
         failure.detail
     | None, None -> "not published: " ^ failure.detail
     | None, Some _ | Some _, None ->
       "invalid persistence publication evidence: " ^ failure.detail)

let mutation_error_to_string = function
  | Persistence_not_configured -> "chat queue persistence is not configured"
  | Invalid_input message -> "chat queue input is invalid: " ^ message
  | Receipt_already_terminal { receipt_id; state } ->
    Printf.sprintf
      "chat queue receipt %s is already terminal (%s)"
      (Receipt_id.to_string receipt_id)
      (receipt_state_kind_to_string state)
  | Receipt_not_recovery_required { receipt_id; observed_state } ->
    Printf.sprintf
      "chat queue receipt %s is not recovery-required (observed=%s)"
      (Receipt_id.to_string receipt_id)
      (match observed_state with
       | None -> "absent"
       | Some state -> receipt_state_kind_to_string state)
  | Recovery_revision_mismatch
      { receipt_id; expected_revision; observed_revision } ->
    Printf.sprintf
      "chat queue recovery revision mismatch for receipt %s (expected=%Ld observed=%Ld)"
      (Receipt_id.to_string receipt_id)
      expected_revision
      observed_revision
  | Recovery_lease_mismatch
      { receipt_id; expected_lease_id; observed_lease_id } ->
    Printf.sprintf
      "chat queue recovery lease mismatch for receipt %s (expected=%s observed=%s)"
      (Receipt_id.to_string receipt_id)
      expected_lease_id
      observed_lease_id
  | Revision_exhausted -> "chat queue revision domain is exhausted"
  | Persist_failed failure ->
    "chat queue persistence failed: " ^ persistence_failure_to_string failure
  | Snapshot_unavailable error ->
    Printf.sprintf
      "chat queue snapshot unavailable (%s): %s"
      (snapshot_load_error_kind_to_string error.kind)
      error.message

let mutation_error_to_json = function
  | Persistence_not_configured ->
    `Assoc
      [ "error", `String "chat_queue_persistence_not_configured"
      ; "message", `String "chat queue persistence is not configured"
      ]
  | Invalid_input message ->
    `Assoc
      [ "error", `String "chat_queue_invalid_input"
      ; "message", `String message
      ]
  | Receipt_already_terminal { receipt_id; state } ->
    `Assoc
      [ "error", `String "chat_queue_receipt_already_terminal"
      ; "receipt_id", `String (Receipt_id.to_string receipt_id)
      ; "state", `String (receipt_state_kind_to_string state)
      ; "message", `String "chat queue receipt is already terminal"
      ]
  | Receipt_not_recovery_required { receipt_id; observed_state } ->
    `Assoc
      [ "error", `String "chat_queue_receipt_not_recovery_required"
      ; "receipt_id", `String (Receipt_id.to_string receipt_id)
      ; ( "observed_state"
        , match observed_state with
          | None -> `Null
          | Some state -> `String (receipt_state_kind_to_string state) )
      ; "message", `String "chat queue receipt is not recovery-required"
      ]
  | Recovery_revision_mismatch
      { receipt_id; expected_revision; observed_revision } ->
    `Assoc
      [ "error", `String "chat_queue_recovery_revision_mismatch"
      ; "receipt_id", `String (Receipt_id.to_string receipt_id)
      ; "expected_revision", `String (Int64.to_string expected_revision)
      ; "observed_revision", `String (Int64.to_string observed_revision)
      ; "message", `String "chat queue recovery decision is stale"
      ]
  | Recovery_lease_mismatch
      { receipt_id; expected_lease_id; observed_lease_id } ->
    `Assoc
      [ "error", `String "chat_queue_recovery_lease_mismatch"
      ; "receipt_id", `String (Receipt_id.to_string receipt_id)
      ; "expected_lease_id", `String expected_lease_id
      ; "observed_lease_id", `String observed_lease_id
      ; "message", `String "chat queue recovery lease evidence differs"
      ]
  | Revision_exhausted ->
    `Assoc
      [ "error", `String "chat_queue_revision_exhausted"
      ; "message", `String "chat queue revision domain is exhausted"
      ]
  | Snapshot_unavailable error ->
    `Assoc
      [ "error", `String "chat_queue_snapshot_unavailable"
      ; "kind", `String (snapshot_load_error_kind_to_string error.kind)
      ; "path", Json_util.string_opt_to_json error.path
      ; "message", `String error.message
      ]
  | Persist_failed { publication = Not_published; detail } ->
    `Assoc
      [ "error", `String "chat_queue_persistence_failed"
      ; "published", `Bool false
      ; "message", `String detail
      ]
  | Persist_failed { publication; detail } ->
    (match publication_transition publication, publication_evidence publication with
     | Some transition, Some (revision, receipt_id) ->
       let fields =
         [ "error", `String "chat_queue_acceptance_uncertain"
         ; "status", `String "acceptance_uncertain"
         ; "published", `Bool true
         ; "durability", `String "indeterminate"
         ; "reconciliation_required", `Bool true
         ; "revision", `String (Int64.to_string revision)
         ; "transition", `String transition
         ; "receipt_id", `String (Receipt_id.to_string receipt_id)
         ; "message", `String detail
         ]
       in
       let fields =
         match publication_lease_id publication with
         | None -> fields
         | Some lease_id -> ("lease_id", `String lease_id) :: fields
       in
       `Assoc fields
     | None, None ->
       `Assoc
         [ "error", `String "chat_queue_persistence_failed"
         ; "published", `Bool false
         ; "message", `String detail
         ]
     | None, Some _ | Some _, None ->
       `Assoc
         [ "error", `String "chat_queue_invalid_publication_evidence"
         ; "published", `Bool true
         ; "message", `String detail
         ])

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
  recovery_required : active_receipt list;
  terminal_count : int64;
  load_errors : snapshot_load_error list;
}

type enqueue_receipt = {
  receipt_id : Receipt_id.t;
  revision : int64;
  pending_count : int;
  inflight_count : int;
  recovery_required_count : int;
}

type configure_report = {
  restored_keeper_count : int;
  recovery_required_receipt_count : int;
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
  | Stored_recovery_required of
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

type stored_row = {
  fifo_sequence : int64;
  receipt : stored_receipt;
}

module Sequence_map = Map.Make (Int64)

type transaction_stage =
  | Transaction_begun
  | Mutation_applied
  | Before_commit
  | Commit_invoked
  | Commit_returned
  | Before_rollback
  | Before_close

type commit_failure =
  | Commit_busy
  | Commit_io_error

type reconciliation_plan = {
  before_revision : int64;
  target_revision : int64;
  before_next_sequence : int64;
  target_next_sequence : int64;
  before_terminal_count : int64;
  target_terminal_count : int64;
  before_row : stored_row option;
  target_row : stored_row option;
  transition : persistence_transition;
}

type queue_entry = {
  mutex : Eio.Mutex.t;
  mutable revision : int64;
  mutable next_sequence : int64;
  mutable pending : stored_row Sequence_map.t;
  mutable pending_count : int;
  mutable inflight : stored_row option;
  mutable recovery_required : stored_row option;
  mutable terminal_count : int64;
  mutable load_errors : snapshot_load_error list;
  mutable reconciliation_plan : reconciliation_plan option;
}

type persistence_configuration =
  | Unconfigured
  | Configuring
  | Configured of string
  | Configuration_failed of snapshot_load_error

let database_schema = "keeper_chat_queue.sqlite.v2"
let database_user_version = 2L
let database_application_id = 0x4d435151L
let max_revision = Int64.max_int
let database_file = "chat-queue.sqlite3"

let persistence_configuration = Atomic.make Unconfigured
let global_load_errors : snapshot_load_error list Atomic.t = Atomic.make []
let transaction_failures_for_testing : transaction_stage list Atomic.t =
  Atomic.make []
let commit_failure_for_testing : commit_failure option Atomic.t = Atomic.make None
let transaction_observer_for_testing :
    (transaction_stage -> unit) option Atomic.t =
  Atomic.make None
let before_entry_lock_observer_for_testing : (string -> unit) option Atomic.t =
  Atomic.make None
let inventory_classified_observer_for_testing : (unit -> unit) option Atomic.t =
  Atomic.make None
let transition_observer : transition_observer option Atomic.t = Atomic.make None

let registry_mutex = Eio.Mutex.create ()
let registry : (string, queue_entry) Hashtbl.t = Hashtbl.create 16

let continuation_channel_of_message_source = function
  | Dashboard { thread_id } ->
    Keeper_continuation_channel.Dashboard { thread_id }
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
     | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
     | exn ->
       Log.Keeper.warn
         "chat_queue_transition_observer: keeper=%s revision=%Ld failed: %s"
         keeper_name revision (Printexc.to_string exn))

let valid_keeper_name name =
  Safe_identifier.is_portable_name name

let keeper_directory ~base_path ~keeper_name =
  Filename.concat
    (Common.keepers_runtime_dir_of_base ~base_path)
    keeper_name

let path_for_file ~base_path ~keeper_name file =
  if valid_keeper_name keeper_name
  then Ok (Filename.concat (keeper_directory ~base_path ~keeper_name) file)
  else Error (Printf.sprintf "invalid keeper name for chat queue: %s" keeper_name)

let snapshot_path ~base_path ~keeper_name =
  path_for_file ~base_path ~keeper_name database_file

let load_error kind ?path message = { kind; path; message }

let source_to_yojson = function
  | Dashboard { thread_id } ->
    `Assoc [ "kind", `String "dashboard"; "thread_id", `String thread_id ]
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
      ; ( "thread_ts"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) thread_ts )
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
    if String.equal (String.trim value) ""
    then
      Error
        (Printf.sprintf
           "chat queue JSON field %s must be non-empty when present"
           key)
    else Ok (Some value)
  | Some _ ->
    Error (Printf.sprintf "chat queue JSON field %s must be string or null" key)

let source_of_yojson json =
  match required_string json "kind" with
  | Error _ as error -> error
  | Ok "dashboard" ->
    (match required_string json "thread_id" with
     | Ok thread_id when not (String.equal (String.trim thread_id) "") ->
       Ok (Dashboard { thread_id })
     | Ok _ -> Error "dashboard chat queue source requires a non-empty thread_id"
     | Error _ as error -> error)
  | Ok "discord" ->
    (match required_string json "channel_id", required_string json "user_id" with
     | Ok channel_id, Ok user_id
       when not (String.equal (String.trim channel_id) "")
            && not (String.equal (String.trim user_id) "") ->
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
       when not (String.equal (String.trim channel_id) "")
            && not (String.equal (String.trim user_id) "")
            && not (String.equal (String.trim user_name) "") ->
       Ok (Slack { channel_id; user_id; user_name; team_id; thread_ts })
     | Ok _, Ok _, Ok _, Ok _, Ok _ ->
       Error "slack chat queue source requires non-empty channel/user identity"
     | Error error, _, _, _, _
     | _, Error error, _, _, _
     | _, _, Error error, _, _
     | _, _, _, Error error, _
     | _, _, _, _, Error error -> Error error)
  | Ok kind -> Error (Printf.sprintf "unsupported chat queue source kind: %s" kind)

let user_row_origin_to_yojson = function
  | Keeper_chat_store.Needs_append ->
    `Assoc [ "kind", `String "needs_append" ]
  | Keeper_chat_store.Already_persisted { row_id } ->
    `Assoc
      [ "kind", `String "already_persisted"
      ; "row_id", `String row_id
      ]
  | Keeper_chat_store.Already_persisted_upstream ->
    `Assoc [ "kind", `String "already_persisted_upstream" ]

let user_row_origin_of_yojson json =
  match required_string json "kind" with
  | Ok "needs_append" -> Ok Keeper_chat_store.Needs_append
  | Ok "already_persisted" ->
    (match required_string json "row_id" with
     | Ok row_id when not (String.equal (String.trim row_id) "") ->
       Ok (Keeper_chat_store.Already_persisted { row_id })
     | Ok _ -> Error "persisted user row origin requires a non-empty row_id"
     | Error _ as error -> error)
  | Ok "already_persisted_upstream" ->
    Ok Keeper_chat_store.Already_persisted_upstream
  | Ok kind -> Error (Printf.sprintf "unknown user row origin: %s" kind)
  | Error _ as error -> error

let queued_message_to_yojson (message : queued_message) =
  `Assoc
    [ "content", `String message.content
    ; "user_blocks", Keeper_multimodal_input.user_blocks_to_yojson message.user_blocks
    ; "attachments", Keeper_multimodal_input.attachments_to_yojson message.attachments
    ; "timestamp", `Float message.timestamp
    ; "source", source_to_yojson message.source
    ; "user_row_origin", user_row_origin_to_yojson message.user_row_origin
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
       when not (String.equal (String.trim id) "") && not (String.equal data "") ->
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

let queued_message_of_yojson json =
  match json with
  | `Assoc _ ->
    (match
       required_string json "content",
       required_float json "timestamp",
       required_member json "user_blocks",
       required_member json "attachments",
       required_member json "source",
       required_member json "user_row_origin"
     with
     | ( Ok content
       , Ok timestamp
       , Ok _
       , Ok attachments_json
       , Ok source_json
       , Ok user_row_origin_json ) ->
       (match
          Keeper_multimodal_input.parse_user_blocks json,
          attachments_of_yojson attachments_json,
          source_of_yojson source_json,
          user_row_origin_of_yojson user_row_origin_json
        with
        | Ok user_blocks, Ok attachments, Ok source, Ok user_row_origin ->
          Ok
            { content
            ; user_blocks
            ; attachments
            ; timestamp
            ; source
            ; user_row_origin
            }
        | Error error, _, _, _ | _, Error error, _, _ | _, _, Error error, _ ->
          Error error
        | _, _, _, Error error -> Error error)
     | Error error, _, _, _, _, _
     | _, Error error, _, _, _, _
     | _, _, Error error, _, _, _
     | _, _, _, Error error, _, _
     | _, _, _, _, Error error, _
     | _, _, _, _, _, Error error -> Error error)
  | _ -> Error "chat queue message must be a JSON object"

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

let canonical_message_wire message =
  let json = queued_message_to_yojson message in
  Result.bind (validate_json_utf8 "message" json) (fun () ->
      Result.map
        (fun canonical -> Yojson.Safe.to_string (queued_message_to_yojson canonical))
        (queued_message_of_yojson json))

let canonical_delivery_payload_wire message =
  let json =
    `Assoc
      [ "content", `String message.content
      ; "user_blocks", Keeper_multimodal_input.user_blocks_to_yojson message.user_blocks
      ; "attachments", Keeper_multimodal_input.attachments_to_yojson message.attachments
      ; "source", source_to_yojson message.source
      ; "user_row_origin", user_row_origin_to_yojson message.user_row_origin
      ]
  in
  Result.map
    (fun () -> Yojson.Safe.to_string json)
    (validate_json_utf8 "message" json)

let canonical_queued_message message =
  Result.bind (canonical_message_wire message) (fun wire ->
      try queued_message_of_yojson (Yojson.Safe.from_string wire) with
      | exn -> Error (Printexc.to_string exn))

let failure_kind_to_string = function
  | Turn_failed -> "turn_failed"
  | No_visible_reply -> "no_visible_reply"
  | Transcript_persist_failed -> "transcript_persist_failed"
  | Connector_unavailable -> "connector_unavailable"
  | Delivery_failed -> "delivery_failed"
  | Cancelled -> "cancelled"
  | Internal_error -> "internal_error"
  | Recovery_interrupted -> "recovery_interrupted"

let failure_kind_of_string = function
  | "turn_failed" -> Ok Turn_failed
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
  | Stored_recovery_required { lease_id; started_at; _ } ->
    `Assoc
      [ "kind", `String "recovery_required"
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
    | Stored_pending message
    | Stored_inflight { message; _ }
    | Stored_recovery_required { message; _ } ->
      fields @ [ "message", queued_message_to_yojson message ]
    | Stored_delivered _ | Stored_failed _ -> fields
  in
  `Assoc fields

let stored_receipt_wire receipt =
  Yojson.Safe.to_string (stored_receipt_to_yojson receipt)

let parse_receipt_id json =
  match required_string json "receipt_id" with
  | Error _ as error -> error
  | Ok value -> Receipt_id.of_string value

let reject_terminal_message json =
  match Json_util.assoc_member_opt "message" json with
  | None -> Ok ()
  | Some _ -> Error "terminal chat queue receipts must not retain message bodies"

let stored_receipt_of_yojson json =
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
             when not (String.equal (String.trim lease_id) "") ->
             Result.map
               (fun message ->
                  { receipt_id
                  ; state = Stored_inflight { lease_id; started_at; message }
                  })
               (queued_message_of_yojson message_json)
           | Ok _, Ok _, Ok _ ->
             Error "chat queue inflight lease_id must be non-empty"
           | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error)
        | Ok "recovery_required" ->
          (match
             required_string state_json "lease_id",
             required_float state_json "started_at",
             required_member json "message"
           with
           | Ok lease_id, Ok started_at, Ok message_json
             when not (String.equal (String.trim lease_id) "") ->
             Result.map
               (fun message ->
                  { receipt_id
                  ; state =
                      Stored_recovery_required
                        { lease_id; started_at; message }
                  })
               (queued_message_of_yojson message_json)
           | Ok _, Ok _, Ok _ ->
             Error "chat queue recovery lease_id must be non-empty"
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
             when not (String.equal (String.trim detail) "") ->
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

let strict_stored_receipt_of_wire wire =
  try
    let json = Yojson.Safe.from_string wire in
    Result.bind (validate_json_utf8 "receipt" json) (fun () ->
        Result.bind (stored_receipt_of_yojson json) (fun receipt ->
            let canonical = stored_receipt_wire receipt in
            if String.equal canonical wire
            then Ok receipt
            else Error "chat queue receipt JSON is not canonical or has unknown fields"))
  with exn -> Error ("chat queue receipt JSON decode failed: " ^ Printexc.to_string exn)

let state_kind_and_lease = function
  | Stored_pending _ -> "pending", None
  | Stored_inflight { lease_id; _ } -> "inflight", Some lease_id
  | Stored_recovery_required { lease_id; _ } ->
    "recovery_required", Some lease_id
  | Stored_delivered _ -> "delivered", None
  | Stored_failed _ -> "failed", None

let receipt_state_of_stored = function
  | Stored_pending _ -> Pending
  | Stored_inflight { lease_id; started_at; _ } -> Inflight { lease_id; started_at }
  | Stored_recovery_required { lease_id; started_at; _ } ->
    Recovery_required { lease_id; started_at }
  | Stored_delivered completion -> Delivered completion
  | Stored_failed failure -> Failed failure

let stored_state_is_terminal = function
  | Stored_delivered _ | Stored_failed _ -> true
  | Stored_pending _ | Stored_inflight _ | Stored_recovery_required _ -> false

let stored_row_equal left right =
  Int64.equal left.fifo_sequence right.fifo_sequence
  && String.equal
       (stored_receipt_wire left.receipt)
       (stored_receipt_wire right.receipt)

let option_stored_row_equal left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> stored_row_equal left right
  | None, Some _ | Some _, None -> false

let revision_in_domain revision = Int64.compare revision 0L >= 0

let succ_revision revision =
  if Int64.compare revision max_revision >= 0
  then Error Revision_exhausted
  else Ok (Int64.succ revision)

let succ_sequence sequence =
  if Int64.compare sequence Int64.max_int >= 0
  then Error (Invalid_input "chat queue FIFO sequence domain is exhausted")
  else Ok (Int64.succ sequence)

let ( let* ) = Result.bind

let transaction_stage_to_string = function
  | Transaction_begun -> "transaction_begun"
  | Mutation_applied -> "mutation_applied"
  | Before_commit -> "before_commit"
  | Commit_invoked -> "commit_invoked"
  | Commit_returned -> "commit_returned"
  | Before_rollback -> "before_rollback"
  | Before_close -> "before_close"

let rec remove_first_stage target prefix = function
  | [] -> None
  | stage :: rest when stage = target -> Some (List.rev_append prefix rest)
  | stage :: rest -> remove_first_stage target (stage :: prefix) rest

let consume_transaction_failure stage =
  let rec loop () =
    let observed = Atomic.get transaction_failures_for_testing in
    match remove_first_stage stage [] observed with
    | None -> false
    | Some remaining ->
      if Atomic.compare_and_set
           transaction_failures_for_testing
           observed
           remaining
      then true
      else loop ()
  in
  loop ()

let visit_transaction_stage stage =
  Option.iter (fun observer -> observer stage)
    (Atomic.get transaction_observer_for_testing);
  if consume_transaction_failure stage
  then
    failwith
      ("injected chat queue transaction failure at "
       ^ transaction_stage_to_string stage)

let injected_commit_failure_to_string = function
  | Commit_busy -> "injected SQLite COMMIT result: SQLITE_BUSY"
  | Commit_io_error -> "injected SQLite COMMIT result: SQLITE_IOERR"

let directory_chain_error_to_string = function
  | Keeper_fs_durable_directory.Non_directory_ancestor { path } ->
    Printf.sprintf "directory path is occupied by a non-directory: %s" path
  | Keeper_fs_durable_directory.Outside_ownership_root { ownership_root; path } ->
    Printf.sprintf
      "directory path %s is outside ownership root %s"
      path
      ownership_root
  | Keeper_fs_durable_directory.Missing_root { path } ->
    Printf.sprintf "cannot create filesystem root: %s" path
  | Keeper_fs_durable_directory.Creation_not_observed { path } ->
    Printf.sprintf
      "directory creation returned without a visible directory: %s"
      path

let durable_directory_failure_to_string = function
  | Keeper_fs_durable_directory.Directory_chain_failed error ->
    directory_chain_error_to_string error
  | Keeper_fs_durable_directory.Operation_failed (exn, _) ->
    Printexc.to_string exn

type regular_path_observation =
  | Path_absent
  | Regular_path of Unix.stats

let unix_file_kind_to_string = function
  | Unix.S_REG -> "regular"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character_device"
  | Unix.S_BLK -> "block_device"
  | Unix.S_LNK -> "symbolic_link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"

let inspect_regular_or_absent path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Path_absent
  | exception exn ->
    Error
      (Printf.sprintf
         "failed to inspect owned chat queue path %s: %s"
         path
         (Printexc.to_string exn))
  | { Unix.st_kind = Unix.S_REG; _ } as stat -> Ok (Regular_path stat)
  | { Unix.st_kind; _ } ->
    Error
      (Printf.sprintf
         "owned chat queue path is not a regular file: path=%s kind=%s"
         path
         (unix_file_kind_to_string st_kind))

let same_regular_identity left right =
  left.Unix.st_kind = Unix.S_REG
  && right.Unix.st_kind = Unix.S_REG
  && left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino

let validate_owned_parent ~ownership_root path =
  let parent = Filename.dirname path in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root parent with
  | Ok (Fs_compat.Owned_directory _) -> Ok ()
  | Ok Fs_compat.Owned_directory_missing ->
    Error (Printf.sprintf "owned chat queue parent directory is absent: %s" parent)
  | Error rejection ->
    Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)

let ensure_owned_parent ~ownership_root path =
  let parent = Filename.dirname path in
  match
    Keeper_fs_durable_directory.ensure
      ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ())
      ~ownership_root
      parent
  with
  | Ok _ -> validate_owned_parent ~ownership_root path
  | Error error -> Error (durable_directory_failure_to_string error)

let prepare_database_parent ~ownership_root ~path ~create_if_missing =
  if create_if_missing
  then ensure_owned_parent ~ownership_root path
  else Ok ()

let database_sidecars path = [ path ^ "-journal"; path ^ "-wal"; path ^ "-shm" ]

let validate_database_paths ~ownership_root path =
  let* () = validate_owned_parent ~ownership_root path in
  let* database = inspect_regular_or_absent path in
  let* () =
    List.fold_left
      (fun result sidecar ->
         let* () = result in
         let* _ = inspect_regular_or_absent sidecar in
         Ok ())
      (Ok ())
      (database_sidecars path)
  in
  Ok database

let sqlite_error ~operation db rc =
  Printf.sprintf
    "SQLite %s failed: rc=%s error=%s"
    operation
    (Sqlite3.Rc.to_string rc)
    (Sqlite3.errmsg db)

let sqlite_exec db ~operation sql =
  let rc = Sqlite3.exec db sql in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (sqlite_error ~operation db rc)

let sqlite_bind db stmt ~operation index value =
  let rc = Sqlite3.bind stmt index value in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (sqlite_error ~operation db rc)

let sqlite_bind_text db stmt ~operation index value =
  let rc = Sqlite3.bind_text stmt index value in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (sqlite_error ~operation db rc)

let sqlite_bind_int64 db stmt ~operation index value =
  let rc = Sqlite3.bind_int64 stmt index value in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (sqlite_error ~operation db rc)

let sqlite_expect_done db stmt ~operation =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> Error (sqlite_error ~operation db rc)

let sqlite_finalize db stmt =
  let rc = Sqlite3.finalize stmt in
  if Sqlite3.Rc.is_success rc
  then Ok ()
  else Error (sqlite_error ~operation:"statement finalize" db rc)

let combine_cleanup_error primary cleanup =
  match primary, cleanup with
  | Ok value, Ok () -> Ok value
  | Error detail, Ok () -> Error detail
  | Ok _, Error detail -> Error detail
  | Error primary, Error cleanup ->
    Error (primary ^ "; cleanup also failed: " ^ cleanup)

let with_statement db sql body =
  match
    try Ok (Sqlite3.prepare db sql) with
    | exn -> Error ("SQLite statement prepare failed: " ^ Printexc.to_string exn)
  with
  | Error _ as error -> error
  | Ok stmt ->
    let body_result =
      try body stmt with
      | Eio.Cancel.Cancelled _ as exception_ ->
        (match sqlite_finalize db stmt with
         | Ok () -> ()
         | Error detail ->
           Log.Keeper.error
             "chat queue statement finalize failed during cancellation: %s"
             detail);
        raise exception_
      | exn -> Error (Printexc.to_string exn)
    in
    combine_cleanup_error body_result (sqlite_finalize db stmt)

let queue_meta_table_sql =
  "CREATE TABLE queue_meta (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version TEXT NOT NULL, revision INTEGER NOT NULL CHECK (revision >= 0), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0), terminal_count INTEGER NOT NULL CHECK (terminal_count >= 0)) STRICT"

let receipts_table_sql =
  "CREATE TABLE receipts (receipt_id TEXT PRIMARY KEY NOT NULL, fifo_sequence INTEGER NOT NULL CHECK (fifo_sequence >= 0), state_kind TEXT NOT NULL CHECK (state_kind IN ('pending', 'inflight', 'recovery_required', 'delivered', 'failed')), lease_id TEXT, receipt_json TEXT NOT NULL CHECK (length(receipt_json) > 0), CHECK ((state_kind IN ('inflight', 'recovery_required') AND lease_id IS NOT NULL AND length(lease_id) > 0) OR (state_kind NOT IN ('inflight', 'recovery_required') AND lease_id IS NULL))) STRICT, WITHOUT ROWID"

let fifo_index_sql =
  "CREATE UNIQUE INDEX receipts_fifo_sequence ON receipts (fifo_sequence)"

let active_fifo_index_sql =
  "CREATE INDEX receipts_active_fifo ON receipts (fifo_sequence) WHERE state_kind IN ('pending', 'inflight', 'recovery_required')"

let active_lease_index_sql =
  "CREATE UNIQUE INDEX receipts_single_active_lease ON receipts ((CASE WHEN state_kind IN ('inflight', 'recovery_required') THEN 1 END))"

let expected_schema_objects =
  [ "index", "receipts_active_fifo", active_fifo_index_sql
  ; "index", "receipts_fifo_sequence", fifo_index_sql
  ; "index", "receipts_single_active_lease", active_lease_index_sql
  ; "table", "queue_meta", queue_meta_table_sql
  ; "table", "receipts", receipts_table_sql
  ]

let sqlite_single_int64 db ~operation sql =
  with_statement db sql (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let value = Sqlite3.column_int64 stmt 0 in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok value
         | rc -> Error (sqlite_error ~operation db rc))
      | rc -> Error (sqlite_error ~operation db rc))

let sqlite_single_text db ~operation sql =
  with_statement db sql (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let value = Sqlite3.column_text stmt 0 in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok value
         | rc -> Error (sqlite_error ~operation db rc))
      | rc -> Error (sqlite_error ~operation db rc))

let configure_sqlite_connection db =
  let* mode =
    sqlite_single_text db ~operation:"set DELETE journal mode" "PRAGMA journal_mode=DELETE"
  in
  let* () =
    if String.equal mode "delete"
    then Ok ()
    else Error (Printf.sprintf "SQLite refused DELETE journal mode: %s" mode)
  in
  let* () = sqlite_exec db ~operation:"set FULL synchronous" "PRAGMA synchronous=FULL" in
  let* () = sqlite_exec db ~operation:"enable foreign keys" "PRAGMA foreign_keys=ON" in
  let* synchronous =
    sqlite_single_int64 db ~operation:"read synchronous mode" "PRAGMA synchronous"
  in
  let* foreign_keys =
    sqlite_single_int64 db ~operation:"read foreign key mode" "PRAGMA foreign_keys"
  in
  if not (Int64.equal synchronous 2L)
  then Error (Printf.sprintf "SQLite synchronous mode is %Ld, expected FULL(2)" synchronous)
  else if not (Int64.equal foreign_keys 1L)
  then Error "SQLite foreign key enforcement could not be enabled"
  else Ok ()

let initialize_database db path =
  let* () = sqlite_exec db ~operation:"begin schema transaction" "BEGIN EXCLUSIVE" in
  let body =
    let* () = sqlite_exec db ~operation:"create queue_meta" queue_meta_table_sql in
    let* () = sqlite_exec db ~operation:"create receipts" receipts_table_sql in
    let* () = sqlite_exec db ~operation:"create FIFO index" fifo_index_sql in
    let* () =
      sqlite_exec db ~operation:"create active FIFO index" active_fifo_index_sql
    in
    let* () =
      sqlite_exec db ~operation:"create active lease index" active_lease_index_sql
    in
    let* () =
      with_statement db
        "INSERT INTO queue_meta(singleton, schema_version, revision, next_sequence, terminal_count) VALUES (1, ?, 0, 0, 0)"
        (fun stmt ->
          let* () =
            sqlite_bind_text db stmt ~operation:"bind schema version" 1 database_schema
          in
          sqlite_expect_done db stmt ~operation:"insert queue metadata")
    in
    let* () =
      sqlite_exec db ~operation:"set application id"
        (Printf.sprintf "PRAGMA application_id=%Ld" database_application_id)
    in
    let* () =
      sqlite_exec db ~operation:"set user version"
        (Printf.sprintf "PRAGMA user_version=%Ld" database_user_version)
    in
    sqlite_exec db ~operation:"commit schema transaction" "COMMIT"
  in
  match body with
  | Ok () ->
    (try
       Keeper_fs_durable_directory.fsync_directory (Filename.dirname path);
       Ok ()
     with exn ->
       Error
         ("failed to durably publish chat queue database file: "
          ^ Printexc.to_string exn))
  | Error detail ->
    let rollback = sqlite_exec db ~operation:"rollback schema transaction" "ROLLBACK" in
    (match rollback with
     | Ok () -> Error detail
     | Error rollback_detail ->
       Error (detail ^ "; schema rollback also failed: " ^ rollback_detail))

let read_schema_objects db =
  with_statement db
    "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
    (fun stmt ->
      let rec loop acc =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE -> Ok (List.rev acc)
        | Sqlite3.Rc.ROW ->
          if Sqlite3.column_is_null stmt 2
          then Error "chat queue schema contains an object without canonical SQL"
          else
            loop
              (( Sqlite3.column_text stmt 0
               , Sqlite3.column_text stmt 1
               , Sqlite3.column_text stmt 2 )
               :: acc)
        | rc -> Error (sqlite_error ~operation:"read schema objects" db rc)
      in
      loop [])

let validate_database_identity db =
  let* application_id =
    sqlite_single_int64 db ~operation:"read application id" "PRAGMA application_id"
  in
  let* user_version =
    sqlite_single_int64 db ~operation:"read user version" "PRAGMA user_version"
  in
  let* schema_version =
    sqlite_single_text db ~operation:"read schema version"
      "SELECT schema_version FROM queue_meta WHERE singleton = 1"
  in
  let* meta_rows =
    sqlite_single_int64 db ~operation:"count metadata rows"
      "SELECT COUNT(*) FROM queue_meta"
  in
  if not (Int64.equal application_id database_application_id)
  then
    Error
      (Printf.sprintf
         "unsupported chat queue database application_id=%Ld"
         application_id)
  else if not (Int64.equal user_version database_user_version)
  then
    Error
      (Printf.sprintf
         "unsupported chat queue database user_version=%Ld"
         user_version)
  else if not (String.equal schema_version database_schema)
  then Error ("unsupported chat queue schema version: " ^ schema_version)
  else if not (Int64.equal meta_rows 1L)
  then Error "chat queue database must contain exactly one metadata row"
  else Ok ()

let validate_database_schema db =
  let* () = validate_database_identity db in
  let* objects = read_schema_objects db in
  if objects = expected_schema_objects
  then Ok ()
  else Error "chat queue database schema does not exactly match the supported schema"

type schema_validation =
  | Validate_transaction_preconditions
  | Validate_full_schema

type open_database = {
  db : Sqlite3.db;
  path : string;
  ownership_root : string;
  initial_identity : Unix.stats option;
}

let close_database handle =
  let close_result =
    try
      if Sqlite3.db_close handle.db
      then Ok ()
      else Error "SQLite database close reported a busy handle"
    with exn -> Error ("SQLite database close failed: " ^ Printexc.to_string exn)
  in
  let identity_result =
    let* () = validate_owned_parent ~ownership_root:handle.ownership_root handle.path in
    match inspect_regular_or_absent handle.path with
    | Error _ as error -> error
    | Ok Path_absent -> Error "chat queue database disappeared while its handle was open"
    | Ok (Regular_path final_stat) ->
      (match handle.initial_identity with
       | None -> Ok ()
       | Some initial when same_regular_identity initial final_stat -> Ok ()
       | Some _ -> Error "chat queue database identity changed while its handle was open")
  in
  combine_cleanup_error close_result identity_result

let open_database ~ownership_root ~path ~create_if_missing ~schema_validation =
  (* This function runs inside [Eio_guard.run_in_systhread]. Keep it limited
     to blocking SQLite/Unix operations: directory creation is Eio-aware and
     must be completed by [prepare_database_parent] before this boundary. *)
  let* () = validate_owned_parent ~ownership_root path in
  let* initial = validate_database_paths ~ownership_root path in
  let missing = initial = Path_absent in
  if missing && not create_if_missing
  then Error "chat queue database is absent"
  else
    let db_result =
      try
        Ok
          (match missing with
           | true -> Sqlite3.db_open ~mutex:`FULL path
           | false -> Sqlite3.db_open ~mode:`NO_CREATE ~mutex:`FULL path)
      with exn -> Error ("SQLite database open failed: " ^ Printexc.to_string exn)
    in
    match db_result with
    | Error _ as error -> error
    | Ok db ->
      let handle =
        { db
        ; path
        ; ownership_root
        ; initial_identity =
            (match initial with
             | Path_absent -> None
             | Regular_path stat -> Some stat)
        }
      in
      let prepared =
        try
          let* () = configure_sqlite_connection db in
          if missing
          then initialize_database db path
          else
            match schema_validation with
            | Validate_transaction_preconditions -> Ok ()
            | Validate_full_schema -> validate_database_schema db
        with
        | Eio.Cancel.Cancelled _ as exception_ ->
          (match close_database handle with
           | Ok () -> ()
           | Error detail ->
             Log.Keeper.error
               "chat queue database close failed during open cancellation: %s"
               detail);
          raise exception_
        | exn ->
          Error
            ("SQLite database preparation failed: " ^ Printexc.to_string exn)
      in
      (match prepared with
       | Ok () -> Ok handle
       | Error detail ->
         let closed = close_database handle in
         (match closed with
          | Ok () -> Error detail
          | Error close_detail ->
            Error (detail ^ "; database close also failed: " ^ close_detail)))

let with_database
    ?(schema_validation = Validate_transaction_preconditions)
    ~ownership_root
    ~path
    ~create_if_missing
    body =
  let* () = prepare_database_parent ~ownership_root ~path ~create_if_missing in
  Eio_guard.run_in_systhread (fun () ->
      try
        let* handle =
          open_database
            ~ownership_root
            ~path
            ~create_if_missing
            ~schema_validation
        in
        let body_result =
          try body handle.db with
          | Eio.Cancel.Cancelled _ as exception_ ->
            (match close_database handle with
             | Ok () -> ()
             | Error detail ->
               Log.Keeper.error
                 "chat queue database close failed during cancellation: %s"
                 detail);
            raise exception_
          | exn -> Error (Printexc.to_string exn)
        in
        combine_cleanup_error body_result (close_database handle)
      with
      | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
      | exn -> Error (Printexc.to_string exn))

let read_meta db =
  with_statement db
    "SELECT revision, next_sequence, terminal_count FROM queue_meta WHERE singleton = 1"
    (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let revision = Sqlite3.column_int64 stmt 0 in
        let next_sequence = Sqlite3.column_int64 stmt 1 in
        let terminal_count = Sqlite3.column_int64 stmt 2 in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE when revision_in_domain revision
                              && Int64.compare next_sequence 0L >= 0
                              && Int64.compare terminal_count 0L >= 0 ->
           Ok (revision, next_sequence, terminal_count)
         | Sqlite3.Rc.DONE -> Error "chat queue metadata is outside the int64 domain"
         | rc -> Error (sqlite_error ~operation:"read queue metadata" db rc))
      | rc -> Error (sqlite_error ~operation:"read queue metadata" db rc))

let decode_stored_row ~fifo_sequence ~state_kind ~lease_id ~receipt_wire =
  if Int64.compare fifo_sequence 0L < 0
  then Error "chat queue FIFO sequence must be non-negative"
  else
    let* receipt = strict_stored_receipt_of_wire receipt_wire in
    let expected_kind, expected_lease = state_kind_and_lease receipt.state in
    if not (String.equal state_kind expected_kind)
    then Error "chat queue indexed state does not match its canonical receipt"
    else if lease_id <> expected_lease
    then Error "chat queue indexed lease does not match its canonical receipt"
    else Ok { fifo_sequence; receipt }

let decode_row_columns stmt =
  let fifo_sequence = Sqlite3.column_int64 stmt 0 in
  let state_kind = Sqlite3.column_text stmt 1 in
  let lease_id =
    if Sqlite3.column_is_null stmt 2
    then None
    else Some (Sqlite3.column_text stmt 2)
  in
  let receipt_wire = Sqlite3.column_text stmt 3 in
  decode_stored_row ~fifo_sequence ~state_kind ~lease_id ~receipt_wire

let read_row_by_receipt_id db receipt_id =
  with_statement db
    "SELECT fifo_sequence, state_kind, lease_id, receipt_json FROM receipts WHERE receipt_id = ?"
    (fun stmt ->
      let* () =
        sqlite_bind_text db stmt ~operation:"bind receipt lookup" 1
          (Receipt_id.to_string receipt_id)
      in
      match Sqlite3.step stmt with
      | Sqlite3.Rc.DONE -> Ok None
      | Sqlite3.Rc.ROW ->
        let* row = decode_row_columns stmt in
        if not (Receipt_id.equal row.receipt.receipt_id receipt_id)
        then Error "chat queue receipt primary key differs from its canonical payload"
        else
          (match Sqlite3.step stmt with
           | Sqlite3.Rc.DONE -> Ok (Some row)
           | rc -> Error (sqlite_error ~operation:"finish receipt lookup" db rc))
      | rc -> Error (sqlite_error ~operation:"lookup receipt" db rc))

type loaded_database = {
  loaded_revision : int64;
  loaded_next_sequence : int64;
  loaded_pending : stored_row Sequence_map.t;
  loaded_inflight : stored_row option;
  loaded_recovery_required : stored_row option;
  loaded_terminal_count : int64;
}

let read_active_rows db =
  with_statement db
    "SELECT fifo_sequence, state_kind, lease_id, receipt_json FROM receipts INDEXED BY receipts_active_fifo WHERE state_kind IN ('pending', 'inflight', 'recovery_required') ORDER BY fifo_sequence"
    (fun stmt ->
      let rec loop pending inflight recovery_required =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.DONE -> Ok (pending, inflight, recovery_required)
        | Sqlite3.Rc.ROW ->
          let* row = decode_row_columns stmt in
          (match row.receipt.state, inflight, recovery_required with
           | Stored_pending _, _, _ ->
             if Sequence_map.mem row.fifo_sequence pending
             then Error "chat queue contains duplicate FIFO positions"
             else
               loop
                 (Sequence_map.add row.fifo_sequence row pending)
                 inflight
                 recovery_required
           | Stored_inflight _, None, None -> loop pending (Some row) None
           | Stored_recovery_required _, None, None ->
             loop pending None (Some row)
           | (Stored_inflight _ | Stored_recovery_required _), _, _ ->
             Error "chat queue contains more than one active lease receipt"
           | (Stored_delivered _ | Stored_failed _), _, _ ->
             Error "chat queue active index returned a terminal receipt")
        | rc -> Error (sqlite_error ~operation:"read active receipts" db rc)
      in
      loop Sequence_map.empty None None)

let read_last_sequence db =
  with_statement db
    "SELECT MAX(fifo_sequence) FROM receipts INDEXED BY receipts_fifo_sequence"
    (fun stmt ->
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let sequence =
          if Sqlite3.column_is_null stmt 0
          then None
          else Some (Sqlite3.column_int64 stmt 0)
        in
        (match Sqlite3.step stmt with
         | Sqlite3.Rc.DONE -> Ok sequence
         | rc -> Error (sqlite_error ~operation:"finish FIFO summary" db rc))
      | rc -> Error (sqlite_error ~operation:"read FIFO summary" db rc))

let read_loaded_database db =
  let* () = sqlite_exec db ~operation:"begin load transaction" "BEGIN" in
  let body =
    let* loaded_revision, loaded_next_sequence, loaded_terminal_count =
      read_meta db
    in
    let* loaded_pending, loaded_inflight, loaded_recovery_required =
      read_active_rows db
    in
    let* max_sequence = read_last_sequence db in
    let active_count =
      Sequence_map.cardinal loaded_pending
      + (if Option.is_some loaded_inflight then 1 else 0)
      + (if Option.is_some loaded_recovery_required then 1 else 0)
    in
    let projected_row_count =
      Int64.add loaded_terminal_count (Int64.of_int active_count)
    in
    let sequence_is_contiguous =
      match projected_row_count, max_sequence with
      | 0L, None -> Int64.equal loaded_next_sequence 0L
      | count, Some max_sequence
        when Int64.compare count 0L > 0
             && Int64.compare max_sequence Int64.max_int < 0 ->
        Int64.equal loaded_next_sequence (Int64.succ max_sequence)
        && Int64.equal count loaded_next_sequence
      | 0L, Some _ | _, None | _, Some _ -> false
    in
    if not sequence_is_contiguous
    then Error "chat queue FIFO sequence metadata is not contiguous"
    else
      let* () = sqlite_exec db ~operation:"commit load transaction" "COMMIT" in
      Ok
        { loaded_revision
        ; loaded_next_sequence
        ; loaded_pending
        ; loaded_inflight
        ; loaded_recovery_required
        ; loaded_terminal_count
        }
  in
  match body with
  | Ok _ as result -> result
  | Error detail ->
    let rollback = sqlite_exec db ~operation:"rollback load transaction" "ROLLBACK" in
    (match rollback with
     | Ok () -> Error detail
     | Error rollback_detail ->
       Error (detail ^ "; load rollback also failed: " ^ rollback_detail))

let read_meta_and_row db receipt_id =
  let* () = sqlite_exec db ~operation:"begin receipt observation" "BEGIN" in
  let body =
    let* revision, next_sequence, terminal_count = read_meta db in
    let* row = read_row_by_receipt_id db receipt_id in
    let* () = sqlite_exec db ~operation:"commit receipt observation" "COMMIT" in
    Ok (revision, next_sequence, terminal_count, row)
  in
  match body with
  | Ok _ as result -> result
  | Error detail ->
    let rollback = sqlite_exec db ~operation:"rollback receipt observation" "ROLLBACK" in
    (match rollback with
     | Ok () -> Error detail
     | Error rollback_detail ->
       Error (detail ^ "; receipt observation rollback also failed: " ^ rollback_detail))

exception Sqlite_operation_failed of string

let require_sqlite = function
  | Ok value -> value
  | Error detail -> raise (Sqlite_operation_failed detail)

let bind_row db stmt row =
  let state_kind, lease_id = state_kind_and_lease row.receipt.state in
  require_sqlite
    (sqlite_bind_text db stmt ~operation:"bind receipt id" 1
       (Receipt_id.to_string row.receipt.receipt_id));
  require_sqlite
    (sqlite_bind_int64 db stmt ~operation:"bind FIFO sequence" 2 row.fifo_sequence);
  require_sqlite
    (sqlite_bind_text db stmt ~operation:"bind receipt state" 3 state_kind);
  require_sqlite
    (sqlite_bind db stmt ~operation:"bind receipt lease" 4
       (match lease_id with
        | None -> Sqlite3.Data.NULL
        | Some lease_id -> Sqlite3.Data.TEXT lease_id));
  require_sqlite
    (sqlite_bind_text db stmt ~operation:"bind canonical receipt" 5
       (stored_receipt_wire row.receipt))

let insert_row db row =
  require_sqlite
    (with_statement db
       "INSERT INTO receipts(receipt_id, fifo_sequence, state_kind, lease_id, receipt_json) VALUES (?, ?, ?, ?, ?)"
       (fun stmt ->
         bind_row db stmt row;
         sqlite_expect_done db stmt ~operation:"insert receipt"))

let update_row db row =
  require_sqlite
    (with_statement db
       "UPDATE receipts SET fifo_sequence = ?, state_kind = ?, lease_id = ?, receipt_json = ? WHERE receipt_id = ?"
       (fun stmt ->
         let state_kind, lease_id = state_kind_and_lease row.receipt.state in
         let receipt_id = Receipt_id.to_string row.receipt.receipt_id in
         let* () =
           sqlite_bind_int64 db stmt ~operation:"bind updated FIFO sequence" 1
             row.fifo_sequence
         in
         let* () =
           sqlite_bind_text db stmt ~operation:"bind updated receipt state" 2 state_kind
         in
         let* () =
           sqlite_bind db stmt ~operation:"bind updated receipt lease" 3
             (match lease_id with
              | None -> Sqlite3.Data.NULL
              | Some lease_id -> Sqlite3.Data.TEXT lease_id)
         in
         let* () =
           sqlite_bind_text db stmt ~operation:"bind updated canonical receipt" 4
             (stored_receipt_wire row.receipt)
         in
         let* () =
           sqlite_bind_text db stmt ~operation:"bind updated receipt id" 5 receipt_id
         in
         let* () = sqlite_expect_done db stmt ~operation:"update receipt" in
         if Sqlite3.changes db = 1
         then Ok ()
         else Error "chat queue receipt update did not affect exactly one row"))

let update_meta db plan =
  require_sqlite
    (with_statement db
       "UPDATE queue_meta SET revision = ?, next_sequence = ?, terminal_count = ? WHERE singleton = 1 AND revision = ? AND next_sequence = ? AND terminal_count = ?"
       (fun stmt ->
         let* () =
           sqlite_bind_int64 db stmt ~operation:"bind target revision" 1
             plan.target_revision
         in
         let* () =
           sqlite_bind_int64 db stmt ~operation:"bind target FIFO cursor" 2
             plan.target_next_sequence
         in
         let* () =
           sqlite_bind_int64 db stmt ~operation:"bind target terminal count" 3
             plan.target_terminal_count
         in
         let* () =
           sqlite_bind_int64 db stmt ~operation:"bind expected revision" 4
             plan.before_revision
         in
         let* () =
           sqlite_bind_int64 db stmt ~operation:"bind expected FIFO cursor" 5
             plan.before_next_sequence
         in
         let* () =
           sqlite_bind_int64 db stmt ~operation:"bind expected terminal count" 6
             plan.before_terminal_count
         in
         let* () = sqlite_expect_done db stmt ~operation:"update queue metadata" in
         if Sqlite3.changes db = 1
         then Ok ()
         else Error "chat queue metadata compare-and-set did not affect exactly one row"))

let validate_plan_shape plan =
  if Int64.compare plan.before_revision 0L < 0
     || Int64.compare plan.target_revision 0L < 0
     || Int64.compare plan.before_next_sequence 0L < 0
     || Int64.compare plan.target_next_sequence 0L < 0
     || Int64.compare plan.before_terminal_count 0L < 0
     || Int64.compare plan.target_terminal_count 0L < 0
  then Error "chat queue transaction plan contains a negative counter"
  else
    let validate_row row =
      if Int64.compare row.fifo_sequence 0L < 0
      then Error "chat queue transaction plan contains a negative FIFO sequence"
      else
        let wire = stored_receipt_wire row.receipt in
        let* decoded = strict_stored_receipt_of_wire wire in
        if String.equal wire (stored_receipt_wire decoded)
        then Ok ()
        else Error "chat queue transaction plan contains a non-canonical receipt"
    in
    let* () =
      match plan.before_row with
      | None -> Ok ()
      | Some row -> validate_row row
    in
    let* () =
      match plan.target_row with
      | None -> Ok ()
      | Some row -> validate_row row
    in
    let* receipt_id =
      match plan.before_row, plan.target_row with
      | Some row, _ | None, Some row -> Ok row.receipt.receipt_id
      | None, None -> Error "chat queue transaction plan has no row mutation"
    in
    if not (Receipt_id.equal receipt_id (transition_receipt_id plan.transition))
    then Error "chat queue transition evidence differs from its receipt mutation"
    else
    match plan.before_row, plan.target_row with
    | Some before, Some target
      when not (Receipt_id.equal before.receipt.receipt_id target.receipt.receipt_id) ->
      Error "chat queue transaction plan changes receipt identity"
    | None, None -> Error "chat queue transaction plan has no row mutation"
    | Some _, None -> Error "chat queue receipts are append-only and cannot be deleted"
    | None, Some _ | Some _, Some _ -> Ok ()

let apply_plan_in_transaction db plan =
  require_sqlite (validate_plan_shape plan);
  let observed_revision, observed_next_sequence, observed_terminal_count =
    require_sqlite (read_meta db)
  in
  if not (Int64.equal observed_revision plan.before_revision)
     || not (Int64.equal observed_next_sequence plan.before_next_sequence)
  then
    raise
      (Sqlite_operation_failed
         "chat queue metadata differs from the transaction plan precondition");
  if not (Int64.equal observed_terminal_count plan.before_terminal_count)
  then
    raise
      (Sqlite_operation_failed
         "chat queue terminal count differs from the transaction plan precondition");
  let receipt_id =
    match plan.before_row, plan.target_row with
    | Some row, _ | None, Some row -> row.receipt.receipt_id
    | None, None ->
      raise
        (Sqlite_operation_failed
           "chat queue transaction plan has no receipt identity")
  in
  let observed_row = require_sqlite (read_row_by_receipt_id db receipt_id) in
  if not (option_stored_row_equal observed_row plan.before_row)
  then
    raise
      (Sqlite_operation_failed
         "chat queue receipt differs from the transaction plan precondition");
  (match plan.before_row, plan.target_row with
   | None, Some target -> insert_row db target
   | Some _, Some target -> update_row db target
   | Some _, None ->
     raise
       (Sqlite_operation_failed
          "chat queue receipts are append-only and cannot be deleted")
   | None, None ->
     raise
       (Sqlite_operation_failed
          "chat queue transaction plan has no row mutation"));
  update_meta db plan

type transaction_execution =
  | Transaction_committed
  | Transaction_failed of persistence_failure
  | Transaction_cancelled of
      { failure : persistence_failure
      ; exception_ : exn
      }

let not_published_failure detail =
  { publication = Not_published; detail }

let indeterminate_publication revision = function
  | Enqueue_transition { receipt_id } ->
    Enqueue_indeterminate { revision; receipt_id }
  | Lease_transition { receipt_id; lease_id } ->
    Lease_indeterminate { revision; receipt_id; lease_id }
  | Finalize_transition { receipt_id; lease_id } ->
    Finalize_indeterminate { revision; receipt_id; lease_id }
  | Nack_transition { receipt_id; lease_id } ->
    Nack_indeterminate { revision; receipt_id; lease_id }
  | Startup_recovery_transition { receipt_id; lease_id } ->
    Startup_recovery_indeterminate { revision; receipt_id; lease_id }
  | Recovery_requeue_transition { receipt_id; lease_id } ->
    Recovery_requeue_indeterminate { revision; receipt_id; lease_id }
  | Recovery_cancel_transition { receipt_id; lease_id } ->
    Recovery_cancel_indeterminate { revision; receipt_id; lease_id }

let published_indeterminate_failure plan detail =
  { publication =
      indeterminate_publication plan.target_revision plan.transition
  ; detail
  }

let run_transaction ~ownership_root ~path ~create_if_missing plan =
  let testing_active =
    Atomic.get transaction_failures_for_testing <> []
    || Option.is_some (Atomic.get transaction_observer_for_testing)
    || Option.is_some (Atomic.get commit_failure_for_testing)
  in
  let visit stage =
    if testing_active then visit_transaction_stage stage
  in
  match prepare_database_parent ~ownership_root ~path ~create_if_missing with
  | Error detail -> Transaction_failed (not_published_failure detail)
  | Ok () ->
    Eio_guard.run_in_systhread (fun () ->
      let protect_result f =
        try f () with
        | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
        | exn -> Error (Printexc.to_string exn)
      in
      match
        protect_result (fun () ->
          open_database
            ~ownership_root
            ~path
            ~create_if_missing
            ~schema_validation:Validate_transaction_preconditions)
      with
      | Error detail -> Transaction_failed (not_published_failure detail)
      | Ok handle ->
           let transaction_started = ref false in
           let commit_invoked = ref false in
           let committed = ref false in
           let cancelled : exn option ref = ref None in
           let primary_error = ref None in
           let rollback_error = ref None in
           let close_error = ref None in
           let record target detail =
             match !target with
             | None -> target := Some detail
             | Some previous -> target := Some (previous ^ "; " ^ detail)
           in
           (try
              require_sqlite
                (sqlite_exec handle.db ~operation:"begin mutation" "BEGIN IMMEDIATE");
              transaction_started := true;
              visit Transaction_begun;
              apply_plan_in_transaction handle.db plan;
              visit Mutation_applied;
              visit Before_commit;
              commit_invoked := true;
              visit Commit_invoked;
              (match
                 if testing_active
                 then Atomic.exchange commit_failure_for_testing None
                 else None
               with
               | Some failure ->
                 raise
                   (Sqlite_operation_failed
                      (injected_commit_failure_to_string failure))
               | None ->
                 require_sqlite
                   (sqlite_exec handle.db ~operation:"commit mutation" "COMMIT"));
              committed := true;
              visit Commit_returned
            with
            | Eio.Cancel.Cancelled _ as exception_ ->
              cancelled := Some exception_;
              primary_error := Some (Printexc.to_string exception_)
            | Sqlite_operation_failed detail -> record primary_error detail
            | exn -> record primary_error (Printexc.to_string exn));
           if !transaction_started && not !committed
           then (
             (try visit Before_rollback with
              | exn -> record rollback_error (Printexc.to_string exn));
             (match sqlite_exec handle.db ~operation:"rollback mutation" "ROLLBACK" with
              | Ok () -> ()
              | Error detail -> record rollback_error detail));
           (try visit Before_close with
            | exn -> record close_error (Printexc.to_string exn));
           (match close_database handle with
            | Ok () -> ()
            | Error detail -> record close_error detail);
           let details =
             [ !primary_error; !rollback_error; !close_error ]
             |> List.filter_map Fun.id
             |> String.concat "; "
           in
           let outcome =
             if !committed && Option.is_none !primary_error && Option.is_none !close_error
             then Transaction_committed
             else if !committed || !commit_invoked
             then Transaction_failed (published_indeterminate_failure plan details)
             else if Option.is_some !rollback_error
             then Transaction_failed (published_indeterminate_failure plan details)
             else Transaction_failed (not_published_failure details)
           in
           match !cancelled, outcome with
           | None, outcome -> outcome
           | Some exception_, Transaction_failed failure ->
             Transaction_cancelled { failure; exception_ }
           | Some exception_, Transaction_committed ->
             Transaction_cancelled
               { failure = published_indeterminate_failure plan details
               ; exception_
               }
           | Some _, (Transaction_cancelled _ as outcome) -> outcome)

let with_registry_rw f = Eio.Mutex.use_rw ~protect:true registry_mutex f

let create_entry
    ?(revision = 0L)
    ?(next_sequence = 0L)
    ?(pending = Sequence_map.empty)
    ?pending_count
    ?inflight
    ?recovery_required
    ?(terminal_count = 0L)
    ?(load_errors = [])
    ?reconciliation_plan
    () =
  let pending_count =
    Option.value pending_count ~default:(Sequence_map.cardinal pending)
  in
  { mutex = Eio.Mutex.create ()
  ; revision
  ; next_sequence
  ; pending
  ; pending_count
  ; inflight
  ; recovery_required
  ; terminal_count
  ; load_errors
  ; reconciliation_plan
  }

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

(* Cancellation must not poison the entry mutex. The transaction runner
   converts an in-flight Cancelled into a coherent [Transaction_cancelled]
   value (rollback/close bookkeeping done, entry state set by
   [apply_transaction_result]) and only then re-raises per the Eio
   protocol; letting that re-raise cross [Eio.Mutex.use_rw] would poison
   the mutex and wedge every later operation on this keeper's queue with
   [Eio_mutex.Poisoned]. Catch Cancelled inside the locked region, close
   the lock normally, and re-raise outside. Any other exception still
   poisons — protected state may genuinely be torn there. *)
let with_entry_lock keeper_name entry f =
  Option.iter (fun observer -> observer keeper_name)
    (Atomic.get before_entry_lock_observer_for_testing);
  let outcome =
    Eio.Mutex.use_rw ~protect:true entry.mutex (fun () ->
      match f () with
      | value -> Ok value
      | exception (Eio.Cancel.Cancelled _ as exception_) -> Error exception_)
  in
  match outcome with
  | Ok value -> value
  | Error exception_ -> raise exception_

let persistence_configured () =
  match Atomic.get persistence_configuration with
  | Configured _ -> true
  | Unconfigured | Configuring | Configuration_failed _ -> false

let first_blocking_error entry =
  match entry.load_errors with
  | error :: _ -> Some error
  | [] ->
    (match Atomic.get global_load_errors with
     | error :: _ -> Some error
     | [] -> None)

let configured_base_path () =
  match Atomic.get persistence_configuration with
  | Unconfigured | Configuring -> Error Persistence_not_configured
  | Configuration_failed error -> Error (Snapshot_unavailable error)
  | Configured base_path -> Ok base_path

let mutation_context ~keeper_name ~create =
  if not (valid_keeper_name keeper_name)
  then Error (Invalid_input (Printf.sprintf "invalid keeper name: %s" keeper_name))
  else
    let* base_path = configured_base_path () in
    match Atomic.get global_load_errors with
    | error :: _ -> Error (Snapshot_unavailable error)
    | [] ->
      let entry = if create then Some (get_or_create_entry keeper_name) else find_entry keeper_name in
      let* path =
        snapshot_path ~base_path ~keeper_name
        |> Result.map_error (fun detail ->
          Snapshot_unavailable (load_error Invalid_path detail))
      in
      Ok (base_path, path, entry)

let remove_active_row entry row =
  if Sequence_map.mem row.fifo_sequence entry.pending
  then (
    entry.pending <- Sequence_map.remove row.fifo_sequence entry.pending;
    entry.pending_count <- entry.pending_count - 1);
  (match entry.inflight with
   | Some current
     when Receipt_id.equal current.receipt.receipt_id row.receipt.receipt_id ->
     entry.inflight <- None
   | None | Some _ -> ())
  ;
  (match entry.recovery_required with
   | Some current
     when Receipt_id.equal current.receipt.receipt_id row.receipt.receipt_id ->
     entry.recovery_required <- None
   | None | Some _ -> ())

let add_active_row entry row =
  match row.receipt.state with
  | Stored_pending _ ->
    if not (Sequence_map.mem row.fifo_sequence entry.pending)
    then entry.pending_count <- entry.pending_count + 1;
    entry.pending <- Sequence_map.add row.fifo_sequence row entry.pending
  | Stored_inflight _ -> entry.inflight <- Some row
  | Stored_recovery_required _ -> entry.recovery_required <- Some row
  | Stored_delivered _ | Stored_failed _ -> ()

let set_entry_projection entry ~from_row ~to_row ~revision ~next_sequence
    ~terminal_count =
  Option.iter (remove_active_row entry) from_row;
  Option.iter (add_active_row entry) to_row;
  entry.revision <- revision;
  entry.next_sequence <- next_sequence;
  entry.terminal_count <- terminal_count

let set_entry_to_plan_target entry plan =
  set_entry_projection entry
    ~from_row:plan.before_row
    ~to_row:plan.target_row
    ~revision:plan.target_revision
    ~next_sequence:plan.target_next_sequence
    ~terminal_count:plan.target_terminal_count

let set_entry_to_plan_before entry plan =
  set_entry_projection entry
    ~from_row:plan.target_row
    ~to_row:plan.before_row
    ~revision:plan.before_revision
    ~next_sequence:plan.before_next_sequence
    ~terminal_count:plan.before_terminal_count

let durability_error ~path plan detail =
  load_error Durability_uncertain ~path
    (Printf.sprintf
       "transition %s at revision %Ld requires explicit reconciliation: %s"
       (persistence_transition_to_string plan.transition)
       plan.target_revision
       detail)

let apply_transaction_result ~path entry plan = function
  | Transaction_committed ->
    set_entry_to_plan_target entry plan;
    entry.load_errors <- [];
    entry.reconciliation_plan <- None;
    Ok plan.target_revision
  | Transaction_failed failure ->
    (match failure.publication with
     | Not_published -> Error (Persist_failed failure)
     | _ ->
       set_entry_to_plan_target entry plan;
       entry.load_errors <- [ durability_error ~path plan failure.detail ];
       entry.reconciliation_plan <- Some plan;
       Error (Persist_failed failure))
  | Transaction_cancelled { failure; exception_ } ->
    (match failure.publication with
     | Not_published -> raise exception_
     | _ ->
       set_entry_to_plan_target entry plan;
       entry.load_errors <- [ durability_error ~path plan failure.detail ];
       entry.reconciliation_plan <- Some plan;
       raise exception_)

let notify_indeterminate ~keeper_name = function
  | Error (Persist_failed { publication; _ }) ->
    (match publication_evidence publication with
     | Some (revision, _) -> notify_transition ~keeper_name ~revision
     | None -> ())
  | Ok _ | Error _ -> ()

type lane_store_presence =
  | Store_absent
  | Store_present

let observe_lane_store_blocking ~ownership_root ~path =
  let parent = Filename.dirname path in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root parent with
  | Error rejection ->
    Error
      (load_error Invalid_path ~path
         (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  | Ok Fs_compat.Owned_directory_missing -> Ok Store_absent
  | Ok (Fs_compat.Owned_directory _) ->
    (match validate_database_paths ~ownership_root path with
     | Error detail -> Error (load_error Invalid_path ~path detail)
     | Ok Path_absent -> Ok Store_absent
     | Ok (Regular_path _) -> Ok Store_present)

let observe_lane_store ~ownership_root ~path =
  Eio_guard.run_in_systhread (fun () ->
      try observe_lane_store_blocking ~ownership_root ~path with
      | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
      | exn -> Error (load_error Read_failed ~path (Printexc.to_string exn)))

let quarantine_entry entry error =
  entry.load_errors <- [ error ];
  Error (Snapshot_unavailable error)

let check_entry_store ~base_path ~path entry ~allow_absent =
  match first_blocking_error entry with
  | Some error -> Error (Snapshot_unavailable error)
  | None ->
    (match observe_lane_store ~ownership_root:base_path ~path with
     | Error error -> quarantine_entry entry error
     | Ok Store_present -> Ok Store_present
     | Ok Store_absent
       when allow_absent
            && Int64.equal entry.revision 0L
            && Int64.equal entry.next_sequence 0L
            && entry.pending_count = 0
            && Option.is_none entry.inflight
            && Option.is_none entry.recovery_required
            && Int64.equal entry.terminal_count 0L ->
       Ok Store_absent
     | Ok Store_absent ->
       quarantine_entry entry
         (load_error Read_failed ~path
            "chat queue database disappeared while the lane retained durable state"))

let observe_receipt_in_store ~base_path ~path receipt_id =
  with_database ~ownership_root:base_path ~path ~create_if_missing:false
    (fun db -> read_meta_and_row db receipt_id)

let cache_matches_meta entry revision next_sequence terminal_count =
  Int64.equal entry.revision revision
  && Int64.equal entry.next_sequence next_sequence
  && Int64.equal entry.terminal_count terminal_count

let canonical_message_of_stored_state = function
  | Stored_pending message
  | Stored_inflight { message; _ }
  | Stored_recovery_required { message; _ } -> Some message
  | Stored_delivered _ | Stored_failed _ -> None

let make_plan entry ~before_row ~target_row ~target_next_sequence
    ~target_terminal_count ~transition =
  let* target_revision = succ_revision entry.revision in
  Ok
    { before_revision = entry.revision
    ; target_revision
    ; before_next_sequence = entry.next_sequence
    ; target_next_sequence
    ; before_terminal_count = entry.terminal_count
    ; target_terminal_count
    ; before_row
    ; target_row
    ; transition
    }

let enqueue_with_receipt ~keeper_name ~receipt_id message =
  match canonical_queued_message message with
  | Error detail -> Error (Invalid_input detail)
  | Ok message ->
    (match mutation_context ~keeper_name ~create:true with
     | Error _ as error -> error
     | Ok (_, _, None) ->
       Error
         (Persist_failed
            (not_published_failure
               "chat queue entry creation did not produce a lane"))
     | Ok (base_path, path, Some entry) ->
       let result =
         with_entry_lock keeper_name entry (fun () ->
             match
               check_entry_store ~base_path ~path entry
                 ~allow_absent:true
             with
             | Error _ as error -> error
             | Ok presence ->
               let observed =
                 match presence with
                 | Store_absent -> Ok (0L, 0L, 0L, None)
                 | Store_present ->
                   observe_receipt_in_store ~base_path ~path receipt_id
                   |> Result.map_error (fun detail ->
                     Snapshot_unavailable (load_error Read_failed ~path detail))
               in
               (match observed with
                | Error (Snapshot_unavailable error) -> quarantine_entry entry error
                | Error _ as error -> error
                | Ok (revision, next_sequence, terminal_count, existing) ->
                  if not
                       (cache_matches_meta
                          entry
                          revision
                          next_sequence
                          terminal_count)
                  then
                    quarantine_entry entry
                      (load_error Reconciliation_failed ~path
                         "chat queue database metadata diverged from its in-memory projection")
                  else
                    (match existing with
                     | Some row when stored_state_is_terminal row.receipt.state ->
                       Error
                         (Receipt_already_terminal
                            { receipt_id
                            ; state = receipt_state_of_stored row.receipt.state
                            })
                     | Some row ->
                       (match canonical_message_of_stored_state row.receipt.state with
                        | None ->
                          quarantine_entry entry
                            (load_error Parse_failed ~path
                               "active receipt has no canonical message payload")
                        | Some stored_message ->
                          (match
                             canonical_delivery_payload_wire stored_message,
                             canonical_delivery_payload_wire message
                           with
                           | Ok stored, Ok requested when String.equal stored requested ->
                             Ok
                               ( { receipt_id
                                 ; revision = entry.revision
                                 ; pending_count = entry.pending_count
                                 ; inflight_count =
                                     (if Option.is_some entry.inflight then 1 else 0)
                                 ; recovery_required_count =
                                     (if Option.is_some entry.recovery_required
                                      then 1
                                      else 0)
                                 }
                               , false )
                           | Ok _, Ok _ ->
                             Error
                               (Invalid_input
                                  "active chat queue receipt already belongs to a different canonical payload")
                           | Error detail, _ | _, Error detail ->
                             quarantine_entry entry
                               (load_error Parse_failed ~path detail)))
                     | None ->
                       (match
                          succ_sequence entry.next_sequence,
                          succ_revision entry.revision
                        with
                        | Error error, _ | _, Error error -> Error error
                        | Ok target_next_sequence, Ok _ ->
                          let target_row =
                            { fifo_sequence = entry.next_sequence
                            ; receipt = { receipt_id; state = Stored_pending message }
                            }
                          in
                          (match
                             make_plan entry
                               ~before_row:None
                               ~target_row:(Some target_row)
                               ~target_next_sequence
                               ~target_terminal_count:entry.terminal_count
                               ~transition:(Enqueue_transition { receipt_id })
                           with
                           | Error _ as error -> error
                           | Ok plan ->
                             let execution =
                               run_transaction
                                 ~ownership_root:base_path
                                 ~path
                                 ~create_if_missing:(presence = Store_absent)
                                 plan
                             in
                             Result.map
                               (fun revision ->
                                  ( { receipt_id
                                    ; revision
                                    ; pending_count = entry.pending_count
                                    ; inflight_count =
                                        (if Option.is_some entry.inflight then 1 else 0)
                                    ; recovery_required_count =
                                        (if Option.is_some entry.recovery_required
                                         then 1
                                         else 0)
                                    }
                                  , true ))
                               (apply_transaction_result ~path entry plan execution))))))
       in
       (match result with
        | Ok (({ revision; _ } as receipt), mutated) ->
          if mutated then notify_transition ~keeper_name ~revision;
          Ok receipt
        | Error _ as error ->
          notify_indeterminate ~keeper_name error;
          error))

let enqueue ~keeper_name message =
  enqueue_with_receipt
    ~keeper_name
    ~receipt_id:(Receipt_id.generate ())
    message

let lease_id () = Random_id.prefixed ~prefix:"lease_" ~bytes:16

let lease_next ~keeper_name =
  match mutation_context ~keeper_name ~create:false with
  | Error error -> `Error error
  | Ok (_, _, None) -> `Empty
  | Ok (base_path, path, Some entry) ->
    let result =
      with_entry_lock keeper_name entry (fun () ->
          match
            check_entry_store ~base_path ~path entry
              ~allow_absent:false
          with
          | Error error -> `Error error
          | Ok Store_absent ->
            `Error
              (Snapshot_unavailable
                 (load_error Read_failed ~path
                    "chat queue database is absent during lease"))
          | Ok Store_present ->
            (match entry.recovery_required, entry.inflight with
             | ( Some
                   { receipt =
                       { receipt_id
                       ; state =
                           Stored_recovery_required
                             { lease_id; started_at; _ }
                       }
                   ; _
                   }
               , None ) ->
               `Recovery_required
                 ({ receipt_id; lease_id; started_at } : recovery_evidence)
             | Some _, _ ->
               `Error
                 (Snapshot_unavailable
                    (load_error Parse_failed ~path
                       "in-memory recovery index contains an invalid active lease"))
             | None, Some { receipt = { state = Stored_inflight { lease_id; _ }; _ }; _ } ->
               `Already_leased lease_id
             | None, Some _ ->
               `Error
                 (Snapshot_unavailable
                    (load_error Parse_failed ~path
                       "in-memory inflight index contains a non-inflight receipt"))
             | None, None ->
               (match Sequence_map.min_binding_opt entry.pending with
                | None -> `Empty
                | Some (_, row) ->
                  (match row.receipt.state with
                   | Stored_pending message ->
                     let lease_id = lease_id () in
                     let target_row =
                       { row with
                         receipt =
                           { row.receipt with
                             state =
                               Stored_inflight
                                 { lease_id
                                 ; started_at = Time_compat.now ()
                                 ; message
                                 }
                           }
                       }
                     in
                     (match
                        make_plan entry
                          ~before_row:(Some row)
                          ~target_row:(Some target_row)
                          ~target_next_sequence:entry.next_sequence
                          ~target_terminal_count:entry.terminal_count
                          ~transition:
                            (Lease_transition
                               { receipt_id = row.receipt.receipt_id; lease_id })
                      with
                      | Error error -> `Error error
                      | Ok plan ->
                        let execution =
                          run_transaction
                            ~ownership_root:base_path
                            ~path
                            ~create_if_missing:false
                            plan
                        in
                        (match apply_transaction_result ~path entry plan execution with
                         | Error error -> `Error error
                         | Ok revision ->
                           `Leased
                             ( { lease_id
                               ; item =
                                   { receipt_id = row.receipt.receipt_id; message }
                               }
                             , revision )))
                   | Stored_inflight _
                   | Stored_recovery_required _
                   | Stored_delivered _
                   | Stored_failed _ ->
                     `Error
                       (Snapshot_unavailable
                          (load_error Parse_failed ~path
                             "pending FIFO index contains a non-pending receipt"))))))
    in
    (match result with
     | `Leased (lease, revision) ->
       notify_transition ~keeper_name ~revision;
       `Leased lease
     | `Error error ->
       notify_indeterminate ~keeper_name (Error error);
       `Error error
     | `Empty -> `Empty
     | `Already_leased lease_id -> `Already_leased lease_id
     | `Recovery_required evidence -> `Recovery_required evidence)

let canonical_optional_ref = function
  | None -> Ok None
  | Some value ->
    if String.equal (String.trim value) ""
    then Error "terminal outcome_ref must be non-empty when present"
    else if not (String.is_valid_utf_8 value)
    then Error "terminal outcome_ref contains malformed UTF-8"
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
    let detail = failure.detail in
    if String.equal (String.trim detail) ""
    then Error "terminal failure detail must be non-empty"
    else if not (String.is_valid_utf_8 detail)
    then Error "terminal failure detail contains malformed UTF-8"
    else
      Result.map
        (fun outcome_ref -> Stored_failed { failure with detail; outcome_ref })
        (canonical_optional_ref failure.outcome_ref)

let finalize ~keeper_name ~lease_id ~outcome =
  match canonical_terminal_state outcome with
  | Error detail -> `Error (Invalid_input detail)
  | Ok terminal_state ->
    (match mutation_context ~keeper_name ~create:false with
     | Error error -> `Error error
     | Ok (_, _, None) -> `Unknown_lease
     | Ok (base_path, path, Some entry) ->
       let result =
         with_entry_lock keeper_name entry (fun () ->
             match
               check_entry_store ~base_path ~path entry
                 ~allow_absent:false
             with
             | Error error -> `Error error
             | Ok Store_absent ->
               `Error
                 (Snapshot_unavailable
                    (load_error Read_failed ~path
                       "chat queue database is absent during finalize"))
             | Ok Store_present ->
               (match entry.inflight with
                | Some
                    ({ receipt =
                         { receipt_id
                         ; state = Stored_inflight current
                         }
                     ; _
                     } as row)
                  when String.equal current.lease_id lease_id ->
                  if Int64.equal entry.terminal_count Int64.max_int
                  then `Error Revision_exhausted
                  else
                    let target_row =
                      { row with
                        receipt = { receipt_id; state = terminal_state }
                      }
                    in
                    (match
                       make_plan entry
                         ~before_row:(Some row)
                         ~target_row:(Some target_row)
                         ~target_next_sequence:entry.next_sequence
                         ~target_terminal_count:(Int64.succ entry.terminal_count)
                         ~transition:
                           (Finalize_transition { receipt_id; lease_id })
                     with
                     | Error error -> `Error error
                     | Ok plan ->
                       let execution =
                         run_transaction
                           ~ownership_root:base_path
                           ~path
                           ~create_if_missing:false
                           plan
                       in
                       (match apply_transaction_result ~path entry plan execution with
                        | Ok revision -> `Finalized (receipt_id, revision)
                        | Error error -> `Error error))
                | None | Some _ -> `Unknown_lease))
       in
       (match result with
        | `Finalized (receipt_id, revision) ->
          notify_transition ~keeper_name ~revision;
          `Finalized receipt_id
        | `Error error ->
          notify_indeterminate ~keeper_name (Error error);
          `Error error
        | `Unknown_lease -> `Unknown_lease))

let nack ~keeper_name ~lease_id =
  match mutation_context ~keeper_name ~create:false with
  | Error error -> `Error error
  | Ok (_, _, None) -> `Unknown_lease
  | Ok (base_path, path, Some entry) ->
    let result =
      with_entry_lock keeper_name entry (fun () ->
          match
            check_entry_store ~base_path ~path entry
              ~allow_absent:false
          with
          | Error error -> `Error error
          | Ok Store_absent ->
            `Error
              (Snapshot_unavailable
                 (load_error Read_failed ~path
                    "chat queue database is absent during nack"))
          | Ok Store_present ->
            (match entry.inflight with
             | Some
                 ({ receipt =
                      { receipt_id
                      ; state = Stored_inflight current
                      }
                  ; _
                  } as row)
               when String.equal current.lease_id lease_id ->
               let target_row =
                 { row with
                   receipt =
                     { receipt_id; state = Stored_pending current.message }
                 }
               in
               (match
                  make_plan entry
                    ~before_row:(Some row)
                    ~target_row:(Some target_row)
                    ~target_next_sequence:entry.next_sequence
                    ~target_terminal_count:entry.terminal_count
                    ~transition:(Nack_transition { receipt_id; lease_id })
                with
                | Error error -> `Error error
                | Ok plan ->
                  let execution =
                    run_transaction
                      ~ownership_root:base_path
                      ~path
                      ~create_if_missing:false
                      plan
                  in
                  (match apply_transaction_result ~path entry plan execution with
                   | Ok revision -> `Requeued (receipt_id, revision)
                   | Error error -> `Error error))
             | None | Some _ -> `Unknown_lease))
    in
    (match result with
     | `Requeued (receipt_id, revision) ->
       notify_transition ~keeper_name ~revision;
       `Requeued receipt_id
     | `Error error ->
       notify_indeterminate ~keeper_name (Error error);
       `Error error
     | `Unknown_lease -> `Unknown_lease)

let pending_count ~keeper_name =
  match mutation_context ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) -> Ok 0
  | Ok (_, _, Some entry) ->
    with_entry_lock keeper_name entry (fun () ->
        match first_blocking_error entry with
        | Some error -> Error (Snapshot_unavailable error)
        | None -> Ok entry.pending_count)

let inflight_count ~keeper_name =
  match mutation_context ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) -> Ok 0
  | Ok (_, _, Some entry) ->
    with_entry_lock keeper_name entry (fun () ->
        match first_blocking_error entry with
        | Some error -> Error (Snapshot_unavailable error)
        | None -> Ok (if Option.is_some entry.inflight then 1 else 0))

let has_active_receipts ~keeper_name =
  match mutation_context ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) -> Ok false
  | Ok (_, _, Some entry) ->
    with_entry_lock keeper_name entry (fun () ->
        match first_blocking_error entry with
        | Some error -> Error (Snapshot_unavailable error)
        | None ->
          Ok
            (entry.pending_count > 0
             || Option.is_some entry.inflight
             || Option.is_some entry.recovery_required))

type lane_health =
  | Ready
  | Persistence_reconciliation_required
  | Delivery_recovery_required of
      { receipt_id : Receipt_id.t
      ; lease_id : string
      ; started_at : float
      }
  | Unavailable of snapshot_load_error

type lane_status = {
  revision : int64;
  has_active : bool;
  health : lane_health;
}

let lane_status ~keeper_name =
  match mutation_context ~keeper_name ~create:false with
  | Error _ as error -> error
  | Ok (_, _, None) ->
    Ok { revision = 0L; has_active = false; health = Ready }
  | Ok (_, _, Some entry) ->
    with_entry_lock keeper_name entry (fun () ->
        let health =
          match
            entry.reconciliation_plan,
            entry.load_errors,
            entry.recovery_required
          with
          | Some _, _, _ -> Persistence_reconciliation_required
          | None, error :: _, _ -> Unavailable error
          | ( None
            , []
            , Some
                { receipt =
                    { receipt_id
                    ; state =
                        Stored_recovery_required
                          { lease_id; started_at; _ }
                    }
                ; _
                } ) ->
            Delivery_recovery_required { receipt_id; lease_id; started_at }
          | None, [], None -> Ready
          | None, [], Some _ ->
            Unavailable
              (load_error Parse_failed
                 "recovery index contains a non-recovery receipt")
        in
        Ok
          { revision = entry.revision
          ; has_active =
              entry.pending_count > 0
              || Option.is_some entry.inflight
              || Option.is_some entry.recovery_required
          ; health
          })

let active_receipt_of_row row =
  match row.receipt.state with
  | Stored_pending message ->
    Ok
      { receipt_id = row.receipt.receipt_id
      ; message
      ; state = Pending
      }
  | Stored_inflight ({ message; _ } as inflight) ->
    Ok
      { receipt_id = row.receipt.receipt_id
      ; message
      ; state = receipt_state_of_stored (Stored_inflight inflight)
      }
  | Stored_recovery_required ({ message; _ } as recovery) ->
    Ok
      { receipt_id = row.receipt.receipt_id
      ; message
      ; state = receipt_state_of_stored (Stored_recovery_required recovery)
      }
  | Stored_delivered _ | Stored_failed _ ->
    Error "active receipt projection contains a terminal state"

let snapshot ~keeper_name =
  match find_entry keeper_name with
  | None ->
    { revision = 0L
    ; pending = []
    ; inflight = []
    ; recovery_required = []
    ; terminal_count = 0L
    ; load_errors = Atomic.get global_load_errors
    }
  | Some entry ->
    with_entry_lock keeper_name entry (fun () ->
        let pending, pending_errors =
          Sequence_map.bindings entry.pending
          |> List.fold_left
               (fun (receipts, errors) (_, row) ->
                  match active_receipt_of_row row with
                  | Ok receipt -> receipt :: receipts, errors
                  | Error detail -> receipts, detail :: errors)
               ([], [])
        in
        let pending = List.rev pending in
        let inflight, inflight_errors =
          match entry.inflight with
          | None -> [], []
          | Some row ->
            (match active_receipt_of_row row with
             | Ok receipt -> [ receipt ], []
             | Error detail -> [], [ detail ])
        in
        let recovery_required, recovery_errors =
          match entry.recovery_required with
          | None -> [], []
          | Some row ->
            (match active_receipt_of_row row with
             | Ok receipt -> [ receipt ], []
             | Error detail -> [], [ detail ])
        in
        let projection_errors =
          List.concat [ pending_errors; inflight_errors; recovery_errors ]
          |> List.map (fun detail ->
            load_error Parse_failed
              ("in-memory active receipt projection is invalid: " ^ detail))
        in
        { revision = entry.revision
        ; pending
        ; inflight
        ; recovery_required
        ; terminal_count = entry.terminal_count
        ; load_errors =
            projection_errors
            @ entry.load_errors
            @ Atomic.get global_load_errors
        })

let observation_allowed entry =
  match entry.load_errors with
  | [] -> Ok ()
  | { kind = Durability_uncertain; _ } :: _ -> Ok ()
  | error :: _ -> Error (Snapshot_unavailable error)

let receipt_lookup_of_row revision = function
  | None -> { revision; receipt = None }
  | Some row ->
    { revision
    ; receipt =
        Some
          { receipt_id = row.receipt.receipt_id
          ; state = receipt_state_of_stored row.receipt.state
          }
    }

let lookup_receipt ~keeper_name ~receipt_id =
  if not (valid_keeper_name keeper_name)
  then Error (Invalid_input (Printf.sprintf "invalid keeper name: %s" keeper_name))
  else
    let* base_path = configured_base_path () in
    let* path =
      snapshot_path ~base_path ~keeper_name
      |> Result.map_error (fun detail ->
        Snapshot_unavailable (load_error Invalid_path detail))
    in
    match find_entry keeper_name with
    | None ->
      (match observe_lane_store ~ownership_root:base_path ~path with
       | Error error -> Error (Snapshot_unavailable error)
       | Ok Store_absent -> Ok { revision = 0L; receipt = None }
       | Ok Store_present ->
         Error
           (Snapshot_unavailable
              (load_error Reconciliation_failed ~path
                 "chat queue database exists without a configured in-memory lane")))
    | Some entry ->
      with_entry_lock keeper_name entry (fun () ->
          match observation_allowed entry with
          | Error _ as error -> error
          | Ok () ->
            (match
               observe_lane_store ~ownership_root:base_path ~path
             with
             | Error error -> Error (Snapshot_unavailable error)
             | Ok Store_absent ->
               Error
                 (Snapshot_unavailable
                    (load_error Read_failed ~path
                       "chat queue database is absent during receipt lookup"))
             | Ok Store_present ->
               (match observe_receipt_in_store ~base_path ~path receipt_id with
                | Error detail ->
                  Error
                    (Snapshot_unavailable (load_error Read_failed ~path detail))
                | Ok (revision, _, _, row) ->
                  Ok (receipt_lookup_of_row revision row))))

type reconciliation_outcome =
  | Already_consistent
  | Reconciled

type reconciliation_report =
  { outcome : reconciliation_outcome
  ; revision : int64
  }

type receipt_observation = {
  observed_revision : int64;
  observed_next_sequence : int64;
  observed_terminal_count : int64;
  observed_row : stored_row option;
}

let read_receipt_observation db receipt_id =
  let* () = sqlite_exec db ~operation:"begin reconciliation observation" "BEGIN" in
  let body =
    let* observed_revision, observed_next_sequence, observed_terminal_count =
      read_meta db
    in
    let* observed_row = read_row_by_receipt_id db receipt_id in
    let* () =
      sqlite_exec db ~operation:"commit reconciliation observation" "COMMIT"
    in
    Ok
      { observed_revision
      ; observed_next_sequence
      ; observed_terminal_count
      ; observed_row
      }
  in
  match body with
  | Ok _ as result -> result
  | Error detail ->
    let rollback =
      sqlite_exec db ~operation:"rollback reconciliation observation" "ROLLBACK"
    in
    (match rollback with
     | Ok () -> Error detail
     | Error rollback_detail ->
       Error (detail ^ "; reconciliation observation rollback also failed: "
              ^ rollback_detail))

let observe_plan_receipt ~base_path ~path plan =
  with_database ~ownership_root:base_path ~path ~create_if_missing:false
    (fun db ->
      read_receipt_observation db (transition_receipt_id plan.transition))

let observation_matches
    observation ~revision ~next_sequence ~terminal_count ~row =
  Int64.equal observation.observed_revision revision
  && Int64.equal observation.observed_next_sequence next_sequence
  && Int64.equal observation.observed_terminal_count terminal_count
  && option_stored_row_equal observation.observed_row row

let mark_reconciliation_conflict entry ~path detail =
  let error = load_error Reconciliation_failed ~path detail in
  entry.load_errors <- [ error ];
  Error (Snapshot_unavailable error)

let compensate_uncertain_lease entry plan =
  match plan.target_row with
  | Some
      ({ receipt =
           { receipt_id
           ; state = Stored_inflight inflight
           }
       ; _
       } as row) ->
    let target_row =
      { row with
        receipt = { receipt_id; state = Stored_pending inflight.message }
      }
    in
    let* target_revision = succ_revision plan.target_revision in
    Ok
      { before_revision = plan.target_revision
      ; target_revision
      ; before_next_sequence = plan.target_next_sequence
      ; target_next_sequence = plan.target_next_sequence
      ; before_terminal_count = plan.target_terminal_count
      ; target_terminal_count = plan.target_terminal_count
      ; before_row = plan.target_row
      ; target_row = Some target_row
      ; transition =
          Nack_transition
            { receipt_id; lease_id = inflight.lease_id }
      }
  | None
  | Some
      { receipt =
          { state =
              ( Stored_pending _
              | Stored_recovery_required _
              | Stored_delivered _
              | Stored_failed _ )
          ; _
          }
      ; _
      } ->
    Error
      (Invalid_input
         "uncertain lease reconciliation plan has no inflight target")

let reconcile_persistence ~keeper_name =
  if not (valid_keeper_name keeper_name)
  then Error (Invalid_input (Printf.sprintf "invalid keeper name: %s" keeper_name))
  else
    let* base_path = configured_base_path () in
    let* path =
      snapshot_path ~base_path ~keeper_name
      |> Result.map_error (fun detail ->
        Snapshot_unavailable (load_error Invalid_path detail))
    in
    match find_entry keeper_name with
    | None ->
      (match observe_lane_store ~ownership_root:base_path ~path with
       | Ok Store_absent -> Ok { outcome = Already_consistent; revision = 0L }
       | Error error -> Error (Snapshot_unavailable error)
       | Ok Store_present ->
         Error
           (Snapshot_unavailable
              (load_error Reconciliation_failed ~path
                 "chat queue database exists without a configured in-memory lane")))
    | Some entry ->
      let result =
        with_entry_lock keeper_name entry (fun () ->
            match entry.load_errors, entry.reconciliation_plan with
            | [], None ->
              Ok { outcome = Already_consistent; revision = entry.revision }
            | error :: _, None -> Error (Snapshot_unavailable error)
            | _, Some plan ->
              (match
                 observe_lane_store ~ownership_root:base_path ~path
               with
               | Error error -> mark_reconciliation_conflict entry ~path error.message
               | Ok Store_absent ->
                 mark_reconciliation_conflict entry ~path
                   "chat queue database is absent during reconciliation"
               | Ok Store_present ->
                 (match observe_plan_receipt ~base_path ~path plan with
                  | Error detail ->
                    mark_reconciliation_conflict entry ~path
                      ("failed to observe quarantined receipt: " ^ detail)
                  | Ok observation ->
                    let matches_before =
                      observation_matches observation
                        ~revision:plan.before_revision
                        ~next_sequence:plan.before_next_sequence
                        ~terminal_count:plan.before_terminal_count
                        ~row:plan.before_row
                    in
                    let matches_target =
                      observation_matches observation
                        ~revision:plan.target_revision
                        ~next_sequence:plan.target_next_sequence
                        ~terminal_count:plan.target_terminal_count
                        ~row:plan.target_row
                    in
                    (match plan.transition, matches_before, matches_target with
                     | Lease_transition _, true, false ->
                       set_entry_to_plan_before entry plan;
                       entry.load_errors <- [];
                       entry.reconciliation_plan <- None;
                       Ok { outcome = Reconciled; revision = plan.before_revision }
                     | Lease_transition _, false, true ->
                       (match compensate_uncertain_lease entry plan with
                        | Error _ as error -> error
                        | Ok compensation ->
                          let execution =
                            run_transaction
                              ~ownership_root:base_path
                              ~path
                              ~create_if_missing:false
                              compensation
                          in
                          (match
                             apply_transaction_result
                               ~path entry compensation execution
                           with
                           | Ok revision ->
                             Ok { outcome = Reconciled; revision }
                           | Error _ as error -> error))
                     | ( Enqueue_transition _
                       | Finalize_transition _
                       | Nack_transition _
                       | Startup_recovery_transition _
                       | Recovery_requeue_transition _
                       | Recovery_cancel_transition _ ), false, true ->
                       set_entry_to_plan_target entry plan;
                       entry.load_errors <- [];
                       entry.reconciliation_plan <- None;
                       Ok { outcome = Reconciled; revision = plan.target_revision }
                     | ( Enqueue_transition _
                       | Finalize_transition _
                       | Nack_transition _
                       | Startup_recovery_transition _
                       | Recovery_requeue_transition _
                       | Recovery_cancel_transition _ ), true, false ->
                       let execution =
                         run_transaction
                           ~ownership_root:base_path
                           ~path
                           ~create_if_missing:false
                           plan
                       in
                       (match apply_transaction_result ~path entry plan execution with
                        | Ok revision -> Ok { outcome = Reconciled; revision }
                        | Error _ as error -> error)
                     | _, true, true ->
                       mark_reconciliation_conflict entry ~path
                         "chat queue reconciliation plan has indistinguishable before and target projections"
                     | _, false, false ->
                       mark_reconciliation_conflict entry ~path
                         "chat queue database matches neither side of the quarantined transaction"))))
      in
      (match result with
       | Ok ({ outcome = Reconciled; revision } as report) ->
         notify_transition ~keeper_name ~revision;
         Ok report
       | Ok { outcome = Already_consistent; _ } as result -> result
       | Error _ as error ->
         notify_indeterminate ~keeper_name error;
         error)

type recovery_cancellation =
  { cancelled_at : float
  ; detail : string
  ; outcome_ref : string option
  }

type recovery_resolution =
  | Requeue_unconfirmed
  | Cancel_unconfirmed of recovery_cancellation

type recovery_resolution_report =
  { receipt_id : Receipt_id.t
  ; revision : int64
  ; state : receipt_state
  }

type canonical_recovery_resolution =
  | Canonical_requeue
  | Canonical_cancel of stored_state

let canonical_recovery_resolution = function
  | Requeue_unconfirmed -> Ok Canonical_requeue
  | Cancel_unconfirmed cancellation ->
    Result.map
      (fun state -> Canonical_cancel state)
      (canonical_terminal_state
         (Mark_failed
            { completed_at = cancellation.cancelled_at
            ; kind = Cancelled
            ; detail = cancellation.detail
            ; outcome_ref = cancellation.outcome_ref
            }))

let receipt_not_recovery_required
    ~base_path ~path entry ~receipt_id =
  match observe_receipt_in_store ~base_path ~path receipt_id with
  | Error detail ->
    quarantine_entry entry (load_error Read_failed ~path detail)
  | Ok (revision, next_sequence, terminal_count, row) ->
    if not (cache_matches_meta entry revision next_sequence terminal_count)
    then
      quarantine_entry entry
        (load_error Reconciliation_failed ~path
           "chat queue database metadata diverged during recovery resolution")
    else
      Error
        (Receipt_not_recovery_required
           { receipt_id
           ; observed_state =
               Option.map
                 (fun row -> receipt_state_of_stored row.receipt.state)
                 row
           })

let resolve_recovery_required
    ~keeper_name
    ~receipt_id
    ~expected_revision
    ~lease_id
    ~resolution =
  if Int64.compare expected_revision 0L < 0
  then Error (Invalid_input "recovery expected_revision must be non-negative")
  else if String.equal (String.trim lease_id) ""
  then Error (Invalid_input "recovery lease_id must be non-empty")
  else if not (String.is_valid_utf_8 lease_id)
  then Error (Invalid_input "recovery lease_id contains malformed UTF-8")
  else
    match canonical_recovery_resolution resolution with
    | Error detail -> Error (Invalid_input detail)
    | Ok resolution ->
      (match mutation_context ~keeper_name ~create:false with
       | Error _ as error -> error
       | Ok (_, _, None) ->
         Error
           (Receipt_not_recovery_required
              { receipt_id; observed_state = None })
       | Ok (base_path, path, Some entry) ->
         let result =
           with_entry_lock keeper_name entry (fun () ->
               match check_entry_store ~base_path ~path entry ~allow_absent:false with
               | Error _ as error -> error
               | Ok Store_absent ->
                 quarantine_entry entry
                   (load_error Read_failed ~path
                      "chat queue database is absent during recovery resolution")
               | Ok Store_present ->
                 if not (Int64.equal entry.revision expected_revision)
                 then
                   Error
                     (Recovery_revision_mismatch
                        { receipt_id
                        ; expected_revision
                        ; observed_revision = entry.revision
                        })
                 else
                   match entry.recovery_required with
                   | Some
                       ({ receipt =
                            { receipt_id = observed_receipt_id
                            ; state =
                                Stored_recovery_required
                                  ({ lease_id = observed_lease_id; _ } as recovery)
                            }
                        ; _
                        } as row)
                     when Receipt_id.equal receipt_id observed_receipt_id ->
                     if not (String.equal lease_id observed_lease_id)
                     then
                       Error
                         (Recovery_lease_mismatch
                            { receipt_id
                            ; expected_lease_id = lease_id
                            ; observed_lease_id
                            })
                     else if
                       (match resolution with
                        | Canonical_cancel _ ->
                          Int64.equal entry.terminal_count Int64.max_int
                        | Canonical_requeue -> false)
                     then Error Revision_exhausted
                     else
                       let target_state, target_terminal_count, transition =
                         match resolution with
                         | Canonical_requeue ->
                           ( Stored_pending recovery.message
                           , entry.terminal_count
                           , Recovery_requeue_transition
                               { receipt_id; lease_id } )
                         | Canonical_cancel terminal_state ->
                           ( terminal_state
                           , Int64.succ entry.terminal_count
                           , Recovery_cancel_transition
                               { receipt_id; lease_id } )
                       in
                       let target_row =
                           { row with
                             receipt = { receipt_id; state = target_state }
                           }
                       in
                       (match
                            make_plan entry
                              ~before_row:(Some row)
                              ~target_row:(Some target_row)
                              ~target_next_sequence:entry.next_sequence
                              ~target_terminal_count
                              ~transition
                          with
                          | Error _ as error -> error
                          | Ok plan ->
                            let execution =
                              run_transaction
                                ~ownership_root:base_path
                                ~path
                                ~create_if_missing:false
                                plan
                            in
                            Result.map
                              (fun revision ->
                                 { receipt_id
                                 ; revision
                                 ; state = receipt_state_of_stored target_state
                                 })
                              (apply_transaction_result
                                 ~path entry plan execution))
                   | Some _ | None ->
                     receipt_not_recovery_required
                       ~base_path ~path entry ~receipt_id)
         in
         (match result with
          | Ok ({ revision; _ } as report) ->
            notify_transition ~keeper_name ~revision;
            Ok report
          | Error _ as error ->
            notify_indeterminate ~keeper_name error;
            error))

let all_keeper_names () =
  with_registry_rw (fun () ->
      Hashtbl.fold (fun keeper_name _ names -> keeper_name :: names) registry []
      |> List.sort String.compare)

let recovery_required_state row =
  match row.receipt.state with
  | Stored_pending _
  | Stored_recovery_required _
  | Stored_delivered _
  | Stored_failed _ ->
    Error "startup recovery requires one inflight receipt"
  | Stored_inflight { lease_id; started_at; message } ->
    Ok
      ( Stored_recovery_required { lease_id; started_at; message }
      , lease_id )

type loaded_lane = {
  entry : queue_entry;
  recovery_required_count : int;
  recovery_revision : int64 option;
}

let entry_of_loaded_database loaded =
  create_entry
    ~revision:loaded.loaded_revision
    ~next_sequence:loaded.loaded_next_sequence
    ~pending:loaded.loaded_pending
    ?inflight:loaded.loaded_inflight
    ?recovery_required:loaded.loaded_recovery_required
    ~terminal_count:loaded.loaded_terminal_count
    ()

let load_keeper_lane ~base_path ~path =
  match
    with_database
      ~schema_validation:Validate_full_schema
      ~ownership_root:base_path
      ~path
      ~create_if_missing:false
      read_loaded_database
  with
  | Error detail -> Error (load_error Parse_failed ~path detail)
  | Ok loaded ->
    let entry = entry_of_loaded_database loaded in
    (match loaded.loaded_inflight, loaded.loaded_recovery_required with
     | None, None ->
       Ok
         { entry
         ; recovery_required_count = 0
         ; recovery_revision = None
         }
     | None, Some _ ->
       Ok
         { entry
         ; recovery_required_count = 1
         ; recovery_revision = None
         }
     | Some _, Some _ ->
       let error =
         load_error Recovery_failed ~path
           "chat queue contains both inflight and recovery-required receipts"
       in
       entry.load_errors <- [ error ];
       Ok
         { entry
         ; recovery_required_count = 1
         ; recovery_revision = None
         }
     | Some before_row, None ->
       (match recovery_required_state before_row with
        | Error detail ->
          let error =
            load_error Recovery_failed ~path
              ("failed to preserve inflight recovery evidence: " ^ detail)
          in
          entry.load_errors <- [ error ];
          Ok
            { entry
            ; recovery_required_count = 0
            ; recovery_revision = None
            }
        | Ok (target_state, lease_id) ->
          if Int64.equal entry.revision Int64.max_int
          then (
            let error =
              load_error Recovery_failed ~path
                "cannot persist startup recovery because the queue revision domain is exhausted"
            in
            entry.load_errors <- [ error ];
            Ok
              { entry
              ; recovery_required_count = 0
              ; recovery_revision = None
              })
          else
            let target_row =
              { before_row with
                receipt = { before_row.receipt with state = target_state }
              }
            in
            let target_terminal_count = entry.terminal_count in
            let plan =
              { before_revision = entry.revision
              ; target_revision = Int64.succ entry.revision
              ; before_next_sequence = entry.next_sequence
              ; target_next_sequence = entry.next_sequence
              ; before_terminal_count = entry.terminal_count
              ; target_terminal_count
              ; before_row = Some before_row
              ; target_row = Some target_row
              ; transition =
                  Startup_recovery_transition
                    { receipt_id = before_row.receipt.receipt_id
                    ; lease_id
                    }
              }
            in
            let execution =
              run_transaction
                ~ownership_root:base_path
                ~path
                ~create_if_missing:false
                plan
            in
            (match apply_transaction_result ~path entry plan execution with
             | Ok revision ->
               Ok
                 { entry
                 ; recovery_required_count = 1
                 ; recovery_revision = Some revision
                 }
             | Error (Persist_failed { publication; _ })
               when Option.is_some (publication_evidence publication) ->
               Ok
                 { entry
                 ; recovery_required_count = 1
                 ; recovery_revision = Some plan.target_revision
                 }
             | Error (Persist_failed { publication = Not_published; detail }) ->
               let error =
                 load_error Recovery_failed ~path
                   ("startup recovery was not published: " ^ detail)
               in
               entry.load_errors <- [ error ];
               entry.reconciliation_plan <- Some plan;
               Ok
                 { entry
                 ; recovery_required_count = 0
                 ; recovery_revision = None
                 }
             | Error error ->
               let load =
                 load_error Recovery_failed ~path
                   (mutation_error_to_string error)
               in
               entry.load_errors <- [ load ];
               entry.reconciliation_plan <- Some plan;
               Ok
                 { entry
                 ; recovery_required_count = 0
                 ; recovery_revision = None
                 })))

let inspect_owned_directory ~ownership_root path =
  try
    match Fs_compat.inspect_owned_directory_chain ~ownership_root path with
    | Ok observation -> Ok observation
    | Error rejection ->
      Error
        (load_error Invalid_path ~path
           (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  with
  | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
  | exn -> Error (load_error Read_failed ~path (Printexc.to_string exn))

let same_directory_identity left right =
  left.Unix.st_kind = Unix.S_DIR
  && right.Unix.st_kind = Unix.S_DIR
  && left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino

type keeper_directory_inventory =
  { keeper_names : string list
  ; rejected_entries : (string * snapshot_load_error) list
  ; observed_entries : (string * Unix.stats) list
  }

let classify_keeper_directory_entries_blocking entries_path entries =
  List.fold_left
    (fun inventory entry_name ->
       let entry_path = Filename.concat entries_path entry_name in
       match Unix.lstat entry_path with
       | ({ Unix.st_kind = Unix.S_DIR; _ } as stats) ->
         { inventory with
           keeper_names = entry_name :: inventory.keeper_names
         ; observed_entries = (entry_name, stats) :: inventory.observed_entries
         }
       | ({ Unix.st_kind = Unix.S_REG; _ } as stats) ->
         (* A regular file in the shared Keeper runtime root is not a chat
            queue lane. Other subsystems own their canonical artifacts and may
            retain operator-created backups or diagnostics here. Keep the
            inode in the inventory snapshot so replacement is still detected,
            but do not classify or reject a file outside this directory-only
            queue authority. *)
         { inventory with
           observed_entries = (entry_name, stats) :: inventory.observed_entries
         }
       | ({ Unix.st_kind = st_kind; _ } as stats) ->
         { inventory with
           rejected_entries =
             ( entry_name
             , load_error Invalid_path ~path:entry_path
                 (Printf.sprintf
                    "Keeper chat queue inventory entry has unsupported kind %s"
                    (unix_file_kind_to_string st_kind)) )
             :: inventory.rejected_entries
         ; observed_entries = (entry_name, stats) :: inventory.observed_entries
         }
       | exception exn ->
         { inventory with
           rejected_entries =
             ( entry_name
             , load_error Read_failed ~path:entry_path (Printexc.to_string exn) )
             :: inventory.rejected_entries
         })
    { keeper_names = []; rejected_entries = []; observed_entries = [] }
    entries
  |> fun inventory ->
  { keeper_names = List.rev inventory.keeper_names
  ; rejected_entries = List.rev inventory.rejected_entries
  ; observed_entries = List.rev inventory.observed_entries
  }
;;

let same_entry_identity before after =
  before.Unix.st_kind = after.Unix.st_kind
  && before.Unix.st_dev = after.Unix.st_dev
  && before.Unix.st_ino = after.Unix.st_ino
;;

let validate_keeper_directory_inventory_blocking path ~initial_entries inventory =
  let final_entries = Fs_compat.read_dir path in
  if
    not
      (List.equal
         String.equal
         (List.sort String.compare initial_entries)
         (List.sort String.compare final_entries))
  then Error "Keeper runtime root entries changed during queue inventory"
  else
    inventory.observed_entries
    |> List.find_map (fun (entry_name, before) ->
      let entry_path = Filename.concat path entry_name in
      match Unix.lstat entry_path with
      | after when same_entry_identity before after -> None
      | _ -> Some entry_path
      | exception _ -> Some entry_path)
    |> function
    | None -> Ok ()
    | Some entry_path ->
      Error
        (Printf.sprintf
           "Keeper runtime root entry identity changed during queue inventory: %s"
           entry_path)
;;

let read_keeper_directory_inventory ~ownership_root path =
  Eio_guard.run_in_systhread (fun () ->
    match inspect_owned_directory ~ownership_root path with
    | Error _ as error -> error
    | Ok Fs_compat.Owned_directory_missing -> Ok None
    | Ok (Fs_compat.Owned_directory before) ->
      let inventory =
        try
          let entries = Fs_compat.read_dir path in
          Ok (entries, classify_keeper_directory_entries_blocking path entries)
        with
        | exn -> Error (load_error Read_failed ~path (Printexc.to_string exn))
      in
      (match inventory with
       | Error _ as error -> error
       | Ok (initial_entries, inventory) ->
         Option.iter (fun observer -> observer ())
           (Atomic.get inventory_classified_observer_for_testing);
         let snapshot_validation =
           try
             validate_keeper_directory_inventory_blocking
               path
               ~initial_entries
               inventory
           with
           | exn -> Error (Printexc.to_string exn)
         in
         (match snapshot_validation with
          | Error detail -> Error (load_error Read_failed ~path detail)
          | Ok () ->
            (* Root identity is checked last, after the final entry-set and
               child inode/type validation. Per-lane database loading then
               performs its own owned-chain and regular-file identity checks. *)
            (match inspect_owned_directory ~ownership_root path with
             | Ok (Fs_compat.Owned_directory after)
               when same_directory_identity before after ->
               Ok (Some inventory)
             | Ok (Fs_compat.Owned_directory _ | Fs_compat.Owned_directory_missing) ->
               Error
                 (load_error Read_failed ~path
                    "owned Keeper directory identity changed during queue inventory")
             | Error _ as error -> error))))

let configure_persistence ~base_path =
  let claimed =
    let observed = Atomic.get persistence_configuration in
    match observed with
    | Unconfigured ->
      Atomic.compare_and_set persistence_configuration observed Configuring
    | Configuring | Configured _ | Configuration_failed _ -> false
  in
  if not claimed
  then
    let error =
      load_error Configuration_conflict ~path:base_path
        "chat queue persistence configuration is startup-only and has already been claimed"
    in
    { restored_keeper_count = 0
    ; recovery_required_receipt_count = 0
    ; load_errors = [ None, error ]
    }
  else (
    Atomic.set global_load_errors [];
    with_registry_rw (fun () -> Hashtbl.clear registry);
    match Config_dir_resolver.canonical_base_path base_path with
    | Error error ->
      let error =
        load_error Invalid_path ~path:base_path
          (Config_dir_resolver.canonical_base_path_error_to_string error)
      in
      Atomic.set global_load_errors [ error ];
      Atomic.set persistence_configuration (Configuration_failed error);
      { restored_keeper_count = 0
      ; recovery_required_receipt_count = 0
      ; load_errors = [ None, error ]
      }
    | Ok base_path ->
      let restored_keeper_count = ref 0 in
      let recovery_required_receipt_count = ref 0 in
      let reported_errors = ref [] in
      let recovered_mutations = ref [] in
      let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
      let quarantine keeper_name error =
        reported_errors := (Some keeper_name, error) :: !reported_errors;
        if valid_keeper_name keeper_name
        then
          with_registry_rw (fun () ->
              Hashtbl.replace registry keeper_name
                (create_entry ~load_errors:[ error ] ()))
      in
      let keeper_names =
        match
          read_keeper_directory_inventory
            ~ownership_root:base_path
            keepers_dir
        with
        | Ok None -> []
        | Ok (Some inventory) ->
          List.iter
            (fun (entry_name, error) ->
               reported_errors :=
                 (Some entry_name, error) :: !reported_errors)
            inventory.rejected_entries;
          List.sort String.compare inventory.keeper_names
        | Error error ->
          let error =
            { error with
              message =
                "failed to discover Keeper chat queue databases: " ^ error.message
            }
          in
          reported_errors := [ None, error ];
          Atomic.set global_load_errors [ error ];
          []
      in
      List.iter
        (fun keeper_name ->
           if not (valid_keeper_name keeper_name)
           then
             reported_errors :=
               ( None
               , load_error Invalid_path
                   ~path:(Filename.concat keepers_dir keeper_name)
                   (Printf.sprintf
                      "invalid Keeper name in chat queue inventory: %s"
                      keeper_name) )
               :: !reported_errors
           else
             match snapshot_path ~base_path ~keeper_name with
             | Error detail ->
               quarantine keeper_name (load_error Invalid_path detail)
             | Ok path ->
               (match
                  observe_lane_store ~ownership_root:base_path ~path
                with
                | Error error -> quarantine keeper_name error
                | Ok Store_absent -> ()
                | Ok Store_present ->
                  (match
                     load_keeper_lane ~base_path ~path
                   with
                   | Error error -> quarantine keeper_name error
                   | Ok loaded ->
                     incr restored_keeper_count;
                     recovery_required_receipt_count :=
                       !recovery_required_receipt_count
                       + loaded.recovery_required_count;
                     List.iter
                       (fun error ->
                          reported_errors :=
                            (Some keeper_name, error) :: !reported_errors)
                       loaded.entry.load_errors;
                     with_registry_rw (fun () ->
                         Hashtbl.replace registry keeper_name loaded.entry);
                     Option.iter
                       (fun revision ->
                          recovered_mutations :=
                            (keeper_name, revision) :: !recovered_mutations)
                       loaded.recovery_revision)))
        keeper_names;
      Atomic.set persistence_configuration (Configured base_path);
      List.rev !recovered_mutations
      |> List.iter (fun (keeper_name, revision) ->
        notify_transition ~keeper_name ~revision);
      { restored_keeper_count = !restored_keeper_count
      ; recovery_required_receipt_count =
          !recovery_required_receipt_count
      ; load_errors = List.rev !reported_errors
      })

module For_testing = struct
  type nonrec transaction_stage = transaction_stage =
    | Transaction_begun
    | Mutation_applied
    | Before_commit
    | Commit_invoked
    | Commit_returned
    | Before_rollback
    | Before_close

  type nonrec commit_failure = commit_failure =
    | Commit_busy
    | Commit_io_error

  let reset () =
    Atomic.set transaction_failures_for_testing [];
    Atomic.set commit_failure_for_testing None;
    Atomic.set transaction_observer_for_testing None;
    Atomic.set before_entry_lock_observer_for_testing None;
    Atomic.set inventory_classified_observer_for_testing None;
    Atomic.set persistence_configuration Unconfigured;
    Atomic.set global_load_errors [];
    Atomic.set transition_observer None;
    with_registry_rw (fun () -> Hashtbl.clear registry)

  let fail_transaction_at_stages stages =
    Atomic.set transaction_failures_for_testing stages

  let fail_next_commit_with failure =
    Atomic.set commit_failure_for_testing (Some failure)

  let set_transaction_stage_observer observer =
    Atomic.set transaction_observer_for_testing observer

  let set_before_entry_lock_observer observer =
    Atomic.set before_entry_lock_observer_for_testing observer

  let set_inventory_classified_observer observer =
    Atomic.set inventory_classified_observer_for_testing observer

  let failure_kind_of_string = failure_kind_of_string
  let snapshot_path = snapshot_path

  let receipt_json ~base_path ~keeper_name ~receipt_id =
    let* path = snapshot_path ~base_path ~keeper_name in
    with_database ~ownership_root:base_path ~path ~create_if_missing:false
      (fun db ->
        let* _, _, _, row = read_meta_and_row db receipt_id in
        Ok (Option.map (fun row -> stored_receipt_wire row.receipt) row))
end
