(** Workspace broadcast — emit workspace-wide messages and the
    accompanying message-activity event. *)


type broadcast_error =
  | Broadcast_not_persisted of string
  | Broadcast_policy_rejected of string
  | Broadcast_dependency_unavailable of string

val broadcast_error_to_string : broadcast_error -> string

type mention_delivery_deferred =
  | Handler_unavailable
  | Target_state_unavailable
  | Intake_store_unavailable
  | Workspace_status_unavailable
  | Handler_failed
  | Predecessor_pending
  | Recovery_unavailable

type mention_delivery_rejected =
  | Target_not_configured
  | Invalid_target
  | Invalid_request

type mention_delivery =
  | Passive
  | Pending
  | Accepted
  | Already_accepted
  | Deferred of mention_delivery_deferred
  | Rejected of mention_delivery_rejected

(** Whether a committed message is conversation the fleet should see in its
    Keeper windows, or a record of something the system did. Declared by the
    producer; never derived from the message text. A call site that declares
    nothing is a [System_record], so a new producer cannot silently fan a
    machine announcement out to every Keeper's transcript. *)
type audience =
  | Fleet_conversation
  | System_record

type task_cache_signal =
  { subject_agent : string
  ; task_id : string
  }

type broadcast_delivery =
  { request_id : string
  ; seq : int
  ; rendered : string
  ; from_agent : string
  ; content : string
  ; mention : string option
  ; msg_type : string
  ; mention_delivery : mention_delivery
  ; audience : audience
  }

type mention_outbox_quarantine_reason =
  | Malformed_filename
  | Malformed_json
  | Invalid_current_schema
  | Request_identity_mismatch

type mention_outbox_quarantine_receipt =
  { source_name : string
  ; quarantine_name : string
  ; reason : mention_outbox_quarantine_reason
  ; detail : string
  ; raw_sha256 : string
  }

type message_schema_rejection_kind =
  | Message_row_unreadable
  | Message_row_malformed_json
  | Message_row_incompatible

type message_schema_rejection =
  { source_name : string
  ; kind : message_schema_rejection_kind
  ; detail : string
  }

exception Current_message_schema_rejected of message_schema_rejection list

type reconciliation_report =
  { outbox_rows : int
  ; pending_rows : int
  ; accepted : int
  ; already_accepted : int
  ; deferred : int
  ; rejected : int
  ; corrupt_rows : int
  ; quarantine_receipts : mention_outbox_quarantine_receipt list
  ; blocked_targets : string list
  ; global_barrier : bool
  }

val mention_outbox_quarantine_reason_to_string :
  mention_outbox_quarantine_reason -> string

val message_schema_rejection_to_string : message_schema_rejection -> string

(** Reject any retained workspace message row that predates the current
    request-id + mention-delivery schema. Startup calls this synchronously
    before installing Keeper delivery, so the documented pre-deploy purge is
    an enforced boundary rather than an operator promise. *)
val validate_current_message_schema :
  Workspace_utils_backend_setup.config -> (unit, message_schema_rejection list) result

val emit_message_activity : Workspace_utils_backend_setup.config ->
           from_agent:string ->
           content:string ->
           mention:string option ->
           ?session_id:string ->
           ?operation_id:string ->
           ?worker_run_id:string ->
           ?evidence_refs:string list -> unit -> unit
val broadcast_channel : Workspace_utils_backend_setup.config -> string

(** Atomically replace the process-wide committed-broadcast notification
    handler. The handler runs only after the authoritative workspace message
    write commits. *)
val set_on_broadcast_mention :
  (broadcast_delivery -> mention_delivery) -> unit

(** Reconcile the explicit-mention pending outbox in source sequence order.
    The authoritative backend owns enumeration, so Memory commits remain
    visible even when their optional filesystem mirror failed. *)
val reconcile_pending_mentions :
  Workspace_utils_backend_setup.config ->
  (reconciliation_report, string) result

val mention_delivery_to_yojson : mention_delivery -> Yojson.Safe.t
val mention_delivery_kind : mention_delivery -> string
val mention_delivery_reason : mention_delivery -> string option
val broadcast_delivery_to_yojson : broadcast_delivery -> Yojson.Safe.t

val broadcast : ?trace_context:string ->
           ?msg_type:string ->
           ?task_cache_signal:task_cache_signal ->
           audience:audience ->
           Workspace_utils_backend_setup.config ->
           from_agent:string -> content:string ->
           (broadcast_delivery, broadcast_error) result

module For_testing : sig
  (** Replace the handler and return the prior one. Test isolation only. *)
  val replace_on_broadcast_mention :
    (broadcast_delivery -> mention_delivery) ->
    broadcast_delivery -> mention_delivery

  (** Replace the authoritative workspace-row write boundary and return the
      prior function. Test isolation only. *)
  val replace_write_json_commit :
    (Workspace_utils_backend_setup.config ->
     string ->
     Yojson.Safe.t ->
     (Workspace_utils.write_json_commit, string) result) ->
    (Workspace_utils_backend_setup.config ->
     string ->
     Yojson.Safe.t ->
     (Workspace_utils.write_json_commit, string) result)
end
