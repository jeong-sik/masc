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

val task_cache_signal_of_args :
  Yojson.Safe.t -> (task_cache_signal option, string) result
(** Read [task_cache_subject_agent] and [task_cache_task_id] out of a tool
    call. Both blank or absent is [Ok None]; one without the other is an
    [Error] carrying the message the caller reports, so every tool surface
    rejects a half-given signal in the same words. *)

(** State of this immediate fanout invocation. [Fanout_not_started] reports an
    early return before projection; [Fanout_finished] reports that the delivery
    invocation ended, not that every Keeper accepted or read the message.
    [Fanout_durable_admitted] is set by a host only after it commits both the
    authoritative row and the durable recipient obligations. *)
type fanout_state =
  | Fanout_not_started
  | Fanout_active
  | Fanout_finished
  | Fanout_durable_admitted

type broadcast_delivery =
  { request_id : string
  ; seq : int
  ; rendered : string
  ; from_agent : string
  ; content : string
  ; mention : string option
  ; msg_type : string
  ; mention_delivery : mention_delivery
  ; fanout_state : fanout_state
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

val find_broadcast : request_id:string -> Workspace_utils_backend_setup.config ->
  from_agent:string -> content:string -> (broadcast_delivery option, broadcast_error) result
(** Read the exact authoritative committed row without publishing. Missing is
    [Ok None]; unavailable, corrupt and contradictory rows remain errors. *)

val validate_deferred_fleet_content : string -> (unit,broadcast_error) result
(** Check before durable admission. The Lane caller supplies a host-authored
    stored-artifact marker; selected report text is kept inside its artifact. *)
type fleet_delivery_mode = Immediate_fleet | Deferred_fleet
val broadcast_once :
  ?fleet_delivery:fleet_delivery_mode -> request_id:string ->
  Workspace_utils_backend_setup.config -> from_agent:string -> content:string ->
  (broadcast_delivery, broadcast_error) result
(** Reconcile an exact producer-owned request after an unanswered call. A
    committed authoritative message returns its receipt without another message
    write. In [Immediate_fleet], an idle retry replays the idempotent fleet
    projection to recover interrupted recipients; an active fanout returns its
    receipt immediately with [Fanout_active]. Clients retain the retry identity
    until [Fanout_finished]. [Deferred_fleet] retries only return the receipt;
    the root-owned recipient journal performs recovery. A retry before primary
    commit waits for row readiness, not fleet delivery; failed or cancelled
    attempts wake it to reread. Reusing
    an identity with different content or sender is rejected. This path always
    declares [Fleet_conversation]; callers cannot replay a different audience.
    [Deferred_fleet] is only for a host with durable recipient obligations:
    it commits without synchronous projection and refuses mention-bearing text. *)

module For_testing : sig
  val replace_on_exact_request_wait : (string -> unit) -> (string -> unit)
  (** Observe a retry about to wait for an active request's row readiness.
      Test isolation only; no lock is held while the observer runs. *)
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
