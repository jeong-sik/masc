(** Durable, nonblocking HITL requests for Keeper external effects.

    The queue does not classify actions, suspend a Keeper fiber, or interpret a
    tool/product name. It records an exact request, accepts an explicit
    resolution, and wakes only the originating Keeper lane. *)

include module type of Keeper_approval_queue_types

type storage_error =
  { path : string
  ; reason : string
  }

type approved_resolution_request =
  { keeper_name : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type grant_error =
  | Grant_store_unavailable of storage_error
  | Grant_workspace_mismatch of
      { approval_id : string
      ; requested_base_path : string
      ; stored_base_path : string
      }
  | Grant_still_pending of string
  | Grant_resolution_not_approved of string
  | Grant_resolution_missing of string

type approved_resolution_state =
  | Resolution_unconsumed
  | Resolution_consumed

type grant_consumption =
  | Consumption_committed
  | Consumption_already_committed
  | Consumption_not_matching

type delivery_replay_failure =
  { approval_id : string
  ; reason : string
  }

type install_report =
  { loaded_pending : int
  ; replayed_deliveries : int
  ; delivery_replay_failures : delivery_replay_failure list
  }

type install_error = Install_storage_failed of storage_error

val storage_error_to_string : storage_error -> string
val grant_error_to_string : grant_error -> string
val install_error_to_string : install_error -> string

(** Install one workspace's persisted Gate queue. The file is parsed as one
    closed snapshot: a malformed entry fails the install and is observed via
    the persistence read-drop metric; no valid-looking subset is installed.
    Snapshot read and in-memory installation are one serialized transition, so
    a concurrent mutation for the same workspace cannot be overwritten by the
    loaded snapshot.
    In-flight summaries retain their durable state. Independent delivery replay
    failures are returned in [delivery_replay_failures] and never prevent later
    journals or Gate recovery from being attempted. *)
val install_persistence :
  base_path:string -> (install_report, install_error) result

(** Read the exact approved request from the durable resolution journal. [None]
    means that its one-shot authorization has already been consumed. *)
val approved_resolution_request :
  base_path:string ->
  id:string ->
  (approved_resolution_request option, grant_error) result

(** Observe whether an approved resolution remains durably unconsumed. *)
val approved_resolution_state :
  base_path:string -> id:string -> (approved_resolution_state, grant_error) result

(** Atomically consume an approved resolution only when the Keeper, opaque
    operation identity, and canonical complete input match its durable request.
    Turn, Task, Goal, and channel fields remain provenance and never become
    authorization constraints. *)
val consume_approved_resolution :
  base_path:string ->
  id:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  (grant_consumption, grant_error) result

(** {1 Audit log} *)

val audit_approval_event :
  base_path:string ->
  event_type:string ->
  id:string ->
  keeper_name:string ->
  tool_name:string ->
  ?turn_id:int ->
  ?task_id:string ->
  ?goal_id:string ->
  ?goal_ids:string list ->
  ?source_approval_id:string ->
  ?actor:string ->
  ?decision_source:decision_source ->
  ?decision:decision ->
  unit ->
  unit

val approval_audit_pending_event : string
val approval_audit_resolved_event : string
val generate_id : unit -> string
val recent_resolved_history_limit : int

val read_recent_audit :
  base_path:string -> ?keeper_name:string -> ?n:int -> unit -> Yojson.Safe.t list

val list_recent_resolved_json :
  base_path:string -> ?n:int -> unit -> Yojson.Safe.t list

module For_testing : sig
  val reset_audit_store : unit -> unit
  val reset_runtime_state : unit -> unit
  val with_pending_store_lock : (unit -> 'a) -> 'a
  val install_persistence_with_after_load_hook :
    base_path:string ->
    after_load:(unit -> unit) ->
    (install_report, install_error) result
  val pending_store_path : base_path:string -> string
end

(** {1 Nonblocking submission and explicit resolution} *)

(** Durably enqueue an exact request without suspending the caller. Returns an
    existing id only when the same Keeper, operation identity, canonical input,
    turn/task/goal identity, and continuation channel are already pending. *)
val submit_pending :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  base_path:string ->
  ?turn_id:int ->
  ?request_context:Yojson.Safe.t ->
  ?task_id:string ->
  ?goal_id:string ->
  ?goal_ids:string list ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  unit ->
  (string, storage_error) result

type resolve_error =
  | Not_found of string
  | Already_resolved of string
  | Delivery_failed of
      { approval_id : string
      ; reason : string
      }
  | Persistence_failed of
      { approval_id : string
      ; storage_error : storage_error
      }

type auto_judge_delivery_requeue_error =
  | Requeue_delivery_not_found of string
  | Requeue_delivery_not_auto_judge of string
  | Requeue_delivery_summary_not_decisive of string
  | Requeue_delivery_pending_conflict of string
  | Requeue_delivery_persistence_failed of storage_error

val resolve_error_to_string : resolve_error -> string
val auto_judge_delivery_requeue_error_to_string :
  auto_judge_delivery_requeue_error -> string

(** After origin-lane delivery fails, atomically return an Auto Judge decision
    to the durable pending queue with its decisive summary intact. Human and
    explicit Always Allowed resolutions remain delivery journals and are never
    silently rewritten into model-owned work. *)
val requeue_failed_auto_judge_delivery :
  id:string -> (unit, auto_judge_delivery_requeue_error) result

(** Commit a request-local resolution, then wake only the Keeper captured by
    the pending entry. A resolution never creates a standing authorization. *)
val resolve_with_policy :
  id:string ->
  decision:decision ->
  ?source:decision_source ->
  unit ->
  (unit, resolve_error) result

val resolve :
  id:string ->
  decision:decision ->
  (unit, resolve_error) result

(** {1 Query} *)

val list_pending_json : unit -> Yojson.Safe.t
val list_pending_dashboard_json : unit -> Yojson.Safe.t
val list_pending_entries : unit -> pending_approval list
val get_pending_json : id:string -> Yojson.Safe.t option
val get_pending_entry : id:string -> pending_approval option

val mark_summary_pending : id:string -> (bool, storage_error) result
(** Atomically transition [Summary_not_requested] to [Summary_pending]. Returns
    [false] for a missing entry or any already-started/terminal summary state,
    so a Gate can prevent duplicate judge workers. *)

val attach_summary :
  id:string -> hitl_context_summary -> (bool, storage_error) result

val mark_summary_failed :
  id:string -> reason:string -> retryable:bool -> (bool, storage_error) result

(** Durably transition only [Summary_failed { retryable = true }] back to the
    in-flight marker. This exact CAS has no timer or retry-count policy. *)
val restart_retryable_summary : id:string -> (bool, storage_error) result

val pending_count : unit -> int
val pending_count_for_keeper : keeper_name:string -> int
val has_pending_for_keeper : keeper_name:string -> bool
