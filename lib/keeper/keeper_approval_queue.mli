(** Durable, nonblocking HITL requests for Keeper external effects.

    The queue does not classify actions, suspend a Keeper fiber, or interpret a
    tool/product name. It records an exact request, accepts an explicit
    resolution, and wakes only the originating Keeper lane. *)

include module type of Keeper_approval_queue_rules_types

type storage_error =
  { path : string
  ; reason : string
  }

type summary_transition_rejection =
  | Summary_exact_attempt_bound of exact_attempt_binding

type summary_transition_error =
  | Summary_transition_storage_error of storage_error
  | Summary_transition_rejected of summary_transition_rejection

type exact_attempt_rejection =
  | Exact_attempt_not_found of string
  | Exact_attempt_key_mismatch of
      { approval_id : string
      ; input_hash : string
      ; sequence : int
      }
  | Exact_attempt_invalid_identity of string
  | Exact_attempt_summary_not_pending of string
  | Exact_attempt_unbound_state of string
  | Exact_attempt_identity_conflict of exact_attempt_binding
  | Exact_attempt_status_conflict of exact_attempt_binding
  | Exact_attempt_provenance_mismatch of
      { approval_id : string
      ; expected_call_id : string
      ; actual_model_run_id : string
      }
  | Exact_attempt_content_conflict of string

type exact_attempt_error =
  | Exact_attempt_storage_error of storage_error
  | Exact_attempt_rejected of exact_attempt_rejection

type exact_write_outcome =
  Keeper_event_queue_persistence.exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_attempt_transition =
  { changed : bool
  ; write_outcome : exact_write_outcome
  }
(** Exact writes share the Keeper runtime durability outcome SSOT.
    [Fsync_completed] is the only outcome that permits an OAS POST, slot
    failover, or automatic Gate finalization. [Visible_sync_unconfirmed _]
    means the rename is visible and the process projection has converged, but
    parent-directory fsync was not confirmed; callers must not cross those
    boundaries and may idempotently rewrite the same identity. A cancellation
    before rename is re-raised with memory unchanged. A cancellation observed
    after rename returns [Visible_sync_unconfirmed _] so visible file and memory
    remain convergent. *)

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
val summary_transition_error_to_string : summary_transition_error -> string
val exact_attempt_error_to_string : exact_attempt_error -> string
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

(** {1 Exact Always Allowed rules} *)

val list_rules :
  base_path:string -> unit -> (approval_rule list, rule_store_error) result

val list_rules_dashboard_json :
  base_path:string -> unit -> (Yojson.Safe.t, rule_store_error) result

(** Insert or fetch the rule for the exact
    [(keeper_name, tool_name, canonical complete input)] identity.
    [expires_at] is an optional absolute Unix expiry; the identity match
    ignores it, so an existing rule is returned unchanged. *)
val upsert_rule :
  base_path:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  ?created_by:string ->
  ?source_approval_id:string ->
  ?expires_at:float ->
  unit ->
  (approval_rule * bool, rule_store_error) result

val delete_rule :
  base_path:string -> id:string -> unit -> (approval_rule, rule_store_error) result

(** Find the exact remembered request and report whether it authorizes at
    [now] (defaults to the wall clock; inject for deterministic evaluation).
    An expired rule is reported as [Rule_match_expired], never applied, and
    never deleted. *)
val find_matching_rule :
  base_path:string ->
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  ?now:float ->
  unit ->
  (rule_lookup, rule_store_error) result

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
  ?rule_match:rule_match ->
  ?source_approval_id:string ->
  ?actor:string ->
  ?decision_source:decision_source ->
  ?decision:decision ->
  unit ->
  unit

val audit_rule_event :
  base_path:string -> event_type:string -> approval_rule -> unit

val generate_id : unit -> string
val recent_resolved_history_limit : int

val read_recent_audit :
  base_path:string -> ?keeper_name:string -> ?n:int -> unit -> Yojson.Safe.t list

val list_recent_resolved_json :
  base_path:string -> ?n:int -> unit -> Yojson.Safe.t list

module For_testing : sig
  type strict_snapshot_writer =
    string -> string -> (unit, Fs_compat.atomic_replace_failure) result

  val reset_audit_store : unit -> unit
  val reset_runtime_state : unit -> unit
  val with_pending_store_lock : (unit -> 'a) -> 'a
  val install_persistence_with_after_load_hook :
    base_path:string ->
    after_load:(unit -> unit) ->
    (install_report, install_error) result
  val pending_store_path : base_path:string -> string
  val always_allowed_store_path : base_path:string -> string

  val bind_summary_exact_attempt_with_writer :
    save_file_atomic_strict_staged:strict_snapshot_writer ->
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    (exact_attempt_transition, exact_attempt_error) result

  val release_summary_exact_attempt_before_dispatch_with_writer :
    save_file_atomic_strict_staged:strict_snapshot_writer ->
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    (exact_attempt_transition, exact_attempt_error) result

  val fail_summary_exact_attempt_before_dispatch_with_writer :
    save_file_atomic_strict_staged:strict_snapshot_writer ->
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    reason:string ->
    retryable:bool ->
    (exact_attempt_transition, exact_attempt_error) result

  val quarantine_summary_exact_attempt_with_writer :
    save_file_atomic_strict_staged:strict_snapshot_writer ->
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    cause:exact_attempt_quarantine_cause ->
    (exact_attempt_transition, exact_attempt_error) result

  val complete_summary_exact_attempt_with_writer :
    save_file_atomic_strict_staged:strict_snapshot_writer ->
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    summary:hitl_context_summary ->
    (exact_attempt_transition, exact_attempt_error) result
end

(** {1 Nonblocking submission and explicit resolution} *)

(** Durably enqueue an exact request without suspending the caller. Returns an
    existing id only when the same Keeper, operation identity, canonical input,
    turn/task/goal identity, and continuation channel are already pending. A
    deduplicated request does not consume a durable queue sequence. *)
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

val resolve_error_to_string : resolve_error -> string

(** Commit a resolution, optionally persist an exact Always Allowed rule for
    [Decision.Approve], then wake only the Keeper captured by the pending entry.
    [rule_expires_at] is an absolute Unix expiry applied to the remembered
    rule; it is ignored unless [remember_rule] is [true].

    [base_path] is the authenticated caller workspace. The pending or
    in-progress delivery entry must belong to it exactly before any resolution
    claim or journal mutation is attempted. *)
val resolve_with_policy :
  base_path:string ->
  id:string ->
  decision:decision ->
  ?source:decision_source ->
  ?remember_rule:bool ->
  ?rule_expires_at:float ->
  ?created_by:string ->
  unit ->
  (resolution_result, resolve_error) result

(** {1 Query} *)

val list_pending_json : unit -> Yojson.Safe.t
val list_pending_dashboard_json : unit -> Yojson.Safe.t
val list_pending_entries : unit -> pending_approval list
val get_pending_entry : id:string -> pending_approval option

val bind_summary_exact_attempt :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (exact_attempt_transition, exact_attempt_error) result

(** Bind one exact OAS attempt before provider dispatch. Only
    [Fsync_completed] permits the OAS POST. A visible unconfirmed bind retains
    the identity but forbids POST and failover. Repeating the active identity
    strictly rewrites it, allowing durability to be confirmed without changing
    identity. A released attempt may be replaced only by a new identity; every
    active, quarantined, or completed conflict fails closed. *)

val release_summary_exact_attempt_before_dispatch :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (exact_attempt_transition, exact_attempt_error) result

(** Mark the matching binding released only after OAS proves the attempt stayed
    before dispatch. Only [Fsync_completed] permits failover. A visible
    unconfirmed release retains the original identity, forbids a successor, and
    may be terminalized only with [Exact_terminal_persistence_failure],
    [Exact_cancellation], or [Exact_flow_execution_failed]. The same release is
    idempotently strict-rewritten. *)

val fail_summary_exact_attempt_before_dispatch :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  reason:string ->
  retryable:bool ->
  (exact_attempt_transition, exact_attempt_error) result

(** Atomically release the matching binding and record the final summary
    failure only after OAS proves the attempt stayed before dispatch.
    [retryable] is observation only; execution requires an explicit operator
    restart. Replaying the same identity and failure strictly rewrites it. *)

val quarantine_summary_exact_attempt :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  cause:exact_attempt_quarantine_cause ->
  (exact_attempt_transition, exact_attempt_error) result

(** Terminally quarantine a matching exact binding with one closed typed cause.
    A dispatch-uncertain binding accepts any public exact cause. A released
    binding accepts only [Exact_terminal_persistence_failure],
    [Exact_cancellation], or [Exact_flow_execution_failed]. The same identity
    and cause is idempotently strict-rewritten. It can never return to the
    summary mutation path. Restart-only states are not values of
    [exact_attempt_quarantine_cause] and cannot enter this surface. *)

val complete_summary_exact_attempt :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  summary:hitl_context_summary ->
  (exact_attempt_transition, exact_attempt_error) result

(** Commit validated MASC summary content and the exact binding's completed
    status in one snapshot transaction. Only [Fsync_completed] permits
    automatic Gate finalization. Identical completion is idempotently
    strict-rewritten; different content for the same attempt is a conflict. *)

val mark_summary_pending : id:string -> (bool, summary_transition_error) result
(** Atomically transition [Summary_not_requested] to [Summary_pending]. Returns
      [false] for a missing entry or any already-started/terminal summary state,
      so a Gate can prevent duplicate judge workers. A bound or quarantined
      exact attempt is rejected explicitly. *)

val attach_summary :
  id:string -> hitl_context_summary -> (bool, summary_transition_error) result

val mark_summary_failed :
  id:string ->
  reason:string ->
  retryable:bool ->
  (bool, summary_transition_error) result

(** Durably transition any [Summary_failed] state back to the in-flight marker.
    Only explicit operator action calls this CAS, so the diagnostic [retryable]
    classification never controls work. A restart-classified
    [Exact_released_recovery_required] with [Summary_pending] is also reset to
    [Exact_unbound] without changing its pending summary marker. A live
    [Exact_released_before_dispatch] with [Summary_pending] is never accepted.
    There is no timer or retry count. *)
val restart_failed_summary : id:string -> (bool, summary_transition_error) result

(** Explicit operator recovery: transition every failed summary for this
    workspace in one durable transaction. Non-exact failures return to
    [Summary_not_requested]. Released exact failures return to [Summary_pending]
    with [Exact_unbound]. Restart-classified released pending work also returns
    to [Exact_unbound] while remaining [Summary_pending], so only this operator
    action permits a new exact attempt. Returns the reopened approval ids. *)
val restart_failed_summaries :
  base_path:string -> (string list, summary_transition_error) result

val pending_count_for_keeper : keeper_name:string -> int
