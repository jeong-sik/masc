(** Durable, nonblocking HITL requests for Keeper external effects.

    The queue does not classify actions, suspend a Keeper fiber, or interpret a
    tool/product name. It records an exact request, accepts an explicit
    resolution, and wakes only the originating Keeper lane. *)

open Keeper_approval_queue_rules_types

type storage_error =
  { path : string
  ; reason : string
  }

type summary_transition_rejection =
  | Summary_exact_attempt_bound of exact_attempt_binding

type summary_transition_error =
  | Summary_transition_storage_error of storage_error
  | Summary_transition_rejected of summary_transition_rejection

type summary_owner_retirement_error =
  | Summary_owner_retirement_storage_error of storage_error
  | Summary_owner_retirement_exact_attempt_unsettled of exact_attempt_binding

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
  | Exact_attempt_disposition_conflict of
      { approval_id : string
      ; disposition : summary_attempt_disposition
      }
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
    [Fsync_completed] is the only outcome that permits an AGENT_CORE POST, slot
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
  | Grant_replay_projection_unavailable of storage_error
  | Grant_workspace_mismatch of
      { approval_id : string
      ; requested_base_path : string
      ; stored_base_path : string
      }
  | Grant_still_pending of string
  | Grant_resolution_not_approved of string
  | Grant_resolution_missing of string
  | Grant_replay_not_consumed of string
  | Grant_replay_outcome_conflict of string

(** What the durable Gate store says when a queued approved resolution has
    nothing behind it. Each constructor is a fact about the store, not a read
    failure: reading again on the next turn returns the same answer, so the
    queued resolution has nothing to replay and is retired. Read failures
    stay in [grant_error] and remain actionable. *)
type resolution_absence =
  | Resolution_missing
      (** neither a delivery row nor a pending row carries the id; the store
          was reset or the row was removed after the resolution was queued *)
  | Resolution_still_pending
      (** the store holds the id unresolved while the queue already carries
          its resolution *)
  | Resolution_not_approved
      (** the store recorded a rejection for an id the queue carries as
          approved *)
  | Resolution_workspace_mismatch of { stored_base_path : string }

type approved_resolution_state =
  | Resolution_unconsumed
  | Resolution_consumed

type resolution_replay_outcome =
  | Replay_applied of Tool_output.artifact_ref
  | Replay_applied_with_warning of Tool_output.artifact_ref
  | Replay_failed of Tool_output.artifact_ref
  | Replay_indeterminate of Tool_output.artifact_ref
(** Derived replay evidence points to exact bytes in {!Tool_blob_store}. The
    Gate sidecar owns only this typed content address. The current provider
    input rehydrates the full payload at the caller-owned projection boundary;
    the assigned Runtime measures and admits that exact projected request.
    Canonical history and checkpoints retain the reference, not a duplicate
    payload or a size-dependent preview.
    [Replay_indeterminate] is terminal and fail-closed: the effect may already
    have happened, so it must never be replayed. *)

type approved_resolution_delivery =
  { request : approved_resolution_request
  ; state : approved_resolution_state
  ; replay_outcome : resolution_replay_outcome option
  }

type grant_consumption =
  | Consumption_committed of Keeper_approval.Audit.receipt
  | Consumption_already_committed
  | Consumption_not_matching

type pending_submission_disposition =
  | Pending_created of Keeper_approval.Audit.receipt
  | Pending_deduplicated
  | Folded_onto_unconsumed_grant
      (** The same effect request is already approved and its one-shot grant
          has not been consumed: the host owes the Keeper a replay of exactly
          this call, so no second approval is opened. Rejected and
          grant-consumed deliveries never fold — those retries are a new
          approval cycle and a new effect respectively. *)

type pending_submission =
  { approval_id : string
  ; disposition : pending_submission_disposition
  }

type replay_recording =
  | Replay_recorded
  | Replay_already_recorded

type delivery_replay_failure =
  { approval_id : string
  ; reason : string
  }

type install_report =
  { loaded_pending : int
  ; replayed_deliveries : int
  ; delivery_replay_failures : delivery_replay_failure list
  ; replay_projection_error : storage_error option
  }

type install_error = Install_storage_failed of storage_error

val storage_error_to_string : storage_error -> string
val approval_queue_unavailable_title : string
val approval_queue_unavailable_severity : string
val approval_queue_ready_state_json : Yojson.Safe.t
val approval_queue_unavailable_state_json : storage_error -> Yojson.Safe.t
val summary_transition_error_to_string : summary_transition_error -> string
val summary_owner_retirement_error_to_string :
  summary_owner_retirement_error -> string
val exact_attempt_error_to_string : exact_attempt_error -> string
val grant_error_to_string : grant_error -> string

val resolution_absence_of_grant_error : grant_error -> resolution_absence option
(** [Some] for the store answers that say there is no resolution behind an
    approval id; [None] for read failures and for producer-side replay
    conflicts, which are not statements about the resolution's existence. *)

val resolution_absence_to_string : resolution_absence -> string
val install_error_to_string : install_error -> string

(** Install one workspace's persisted Gate queue. The file is parsed as one
    closed snapshot: a malformed entry fails the install and is observed via
    the persistence read-drop metric; no valid-looking subset is installed.
    Snapshot read and in-memory installation are one serialized transition, so
    a concurrent mutation for the same workspace cannot be overwritten by the
    loaded snapshot.
    A malformed or unreadable derived replay projection is reported in
    [replay_projection_error] without making the authorization store
    unavailable. The projection stays untouched and replay-result writes remain
    scoped unavailable until operator repair.
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

(** Read the approved request together with its consumption state and any
    durable host replay result. Unlike [approved_resolution_request], this
    remains available after one-shot consumption so a retried or restarted
    Keeper turn cannot forget an already-applied external effect. *)
val approved_resolution_delivery :
  base_path:string ->
  id:string ->
  (approved_resolution_delivery, grant_error) result

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

(** Durably attach a typed content address for exact host replay evidence to a
    consumed approval. The derived replay projection is separate from
    authorization state, so a write failure affects this approval's replay
    delivery only. Identical writes are idempotent; conflicting or
    not-fully-synced writes fail visibly. *)
val record_consumed_resolution_replay :
  base_path:string ->
  id:string ->
  outcome:resolution_replay_outcome ->
  (replay_recording, grant_error) result

(** Idempotently project durable approval truth into the originating Keeper's
    visible chat. These receipts never authorize or replay an effect; they are
    the presentation acknowledgement required before the wake event may be
    drained.

    Each row's [call_summary] is copied from the approval's request row
    ({!Keeper_chat_store.approval_request_call_summary}): the producer stated
    that line once, on the Gate request ({!Keeper_gate.request}), and this
    queue never derives one from the stored input. *)
val ensure_resolution_chat_projection :
  base_path:string ->
  keeper_name:string ->
  approval_id:string ->
  tool_name:string option ->
  decision:decision ->
  (unit, string) result

val ensure_replay_chat_projection :
  base_path:string ->
  keeper_name:string ->
  approval_id:string ->
  tool_name:string option ->
  outcome:resolution_replay_outcome ->
  (unit, string) result

val continuation_chat_projection_present :
  base_path:string ->
  keeper_name:string ->
  approval_id:string ->
  bool

type continuation_projection_result =
  | Continuation_projection_recorded
  | Continuation_projection_not_ready

(** Record the post-resolution continuation receipt only when the turn can
    truthfully settle it: rejections need no replay; approvals require a
    consumed grant with a durable replay outcome. *)
val ensure_settled_continuation_chat_projection :
  base_path:string ->
  keeper_name:string ->
  resolution:Keeper_event_queue.hitl_resolution ->
  (continuation_projection_result, string) result

val generate_id : unit -> string

module For_testing : sig
  type strict_snapshot_writer =
    string -> string -> (unit, Fs_compat.atomic_replace_failure) result

  val reset_runtime_state : unit -> unit
  val with_pending_store_lock : (unit -> 'a) -> 'a
  val get_pending_entry_unchecked : id:string -> pending_approval option
  val install_persistence_with_after_load_hook :
    base_path:string ->
    after_load:(unit -> unit) ->
    (install_report, install_error) result
  val pending_store_path : base_path:string -> string
  val pending_log_path : base_path:string -> string
  val replay_results_store_path : base_path:string -> string

  val durable_snapshot_json : base_path:string -> (Yojson.Safe.t, string) result
  (** What a restart would load: the snapshot plus the log rows after it,
      in the snapshot's JSON shape. Reads only. *)
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
    existing id when the same Keeper, operation identity, canonical input,
    task/goal identity, and continuation channel are already pending, or are
    already approved with their one-shot grant unconsumed
    ({!Folded_onto_unconsumed_grant}). The turn that asked is recorded on the
    entry but is not part of the request's identity: a next-turn retry of the
    same call folds onto the approval already in flight instead of opening a
    second one (#28866). A deduplicated or folded request does not consume a
    durable queue sequence or emit a new pending audit event.

    [call_summary] is the producer's one-line statement of the call
    ({!Keeper_gate.request.call_summary}); it is written on the request's chat
    row and takes no part in the request's identity. *)
val submit_pending :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  call_summary:string option ->
  base_path:string ->
  ?turn_id:int ->
  ?request_context:Yojson.Safe.t ->
  ?task_id:string ->
  ?goal_id:string ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  unit ->
  (pending_submission, storage_error) result

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

type resolution_result =
  { remembered_rule : approval_rule option
  ; audit_receipts : Keeper_approval.Audit.receipt list
  }

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

val list_pending_dashboard_json_for_workspace :
  base_path:string -> (Yojson.Safe.t list, storage_error) result
val list_pending_entries_for_workspace :
  base_path:string -> (pending_approval list, storage_error) result

type pending_entries_snapshot =
  { revision : int
  ; entries : pending_approval list
  ; read_errors : storage_error list
  }

val pending_entries_snapshot_for_workspace :
  base_path:string -> (pending_entries_snapshot, storage_error) result
(** Read the revision, readable pending rows, and per-entry errors under the
    same queue lock. Consumers that publish current-state authority must use
    this snapshot rather than joining {!store_revision_for_workspace} to a
    second list read. *)

val list_pending_entries_with_read_errors_for_workspace :
  base_path:string ->
  (pending_approval list * storage_error list, storage_error) result
(** Returns one lock-consistent projection of the readable entries and any
    per-entry read errors. A non-empty error list means mutations remain
    blocked even though the readable entries are safe to display. *)

val retire_summary_owner :
  base_path:string ->
  keeper_name:string ->
  reason:string ->
  (string list, summary_owner_retirement_error) result
(** Fail closed only while an exact summary attempt remains unsettled.
    Otherwise terminalize unbound pending summaries in one durable snapshot and
    leave already terminal summaries unchanged. *)

val store_revision_for_workspace : base_path:string -> int
(** Monotonic process-local revision of the workspace queue authority.

    Every published durable snapshot advances it, as does each transition into
    or out of unavailable. A projection cached under this number therefore
    cannot outlive the write that changed what the queue publishes: an
    enqueued ask, a resolution, and a completed delivery each move it. *)
(** Read one workspace's pending rows without collapsing an unavailable,
    malformed, or reset-required durable store into an empty projection. *)
val get_pending_entry_for_workspace :
  base_path:string
  -> id:string
  -> (pending_approval option, storage_error) result

val bind_summary_exact_attempt :
  id:string ->
  input_hash:string ->
  sequence:int ->
  slot_id:string ->
  call_id:string ->
  plan_fingerprint:string ->
  request_body_sha256:string ->
  (exact_attempt_transition, exact_attempt_error) result

(** Bind one exact AGENT_CORE attempt before provider dispatch. Only
    [Fsync_completed] permits the AGENT_CORE POST. A visible unconfirmed bind retains
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

(** Mark the matching binding released only after AGENT_CORE proves the attempt stayed
    before dispatch. Only [Fsync_completed] permits failover. A visible
    unconfirmed release retains the original identity, forbids a successor, and
    may be terminalized only with [Exact_terminal_persistence_failure],
    [Exact_cancellation], or [Exact_flow_execution_failed]. The same release is
    idempotently strict-rewritten. *)

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
    and cause is idempotently strict-rewritten. The same strict snapshot
    atomically records a non-retryable [Summary_failed] with a stable MASC-owned
    cause. It can never return to the summary mutation path. Restart-only states
    are not values of
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

val mark_summary_attempt_identity_unbound :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  (bool, exact_attempt_error) result
(** Durably block an unbound pending summary with the stable
    [Summary_attempt_identity_unbound] fact. The row identity is an exact CAS;
    no caller supplies diagnostic text. A current start reservation can settle
    here when its worker terminates before binding an exact attempt. *)

val mark_summary_attempt_persistence_uncertain :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  (bool, exact_attempt_error) result
(** Durably record terminalization durability uncertainty without changing the
    summary or exact binding. The stored operator detail is fixed by the queue
    serializer and cannot contain runtime/provider exception text. *)

val mark_summary_attempt_pre_worker_unavailable :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  reason_code:summary_attempt_pre_worker_unavailable_code ->
  operator_detail:string ->
  (bool, exact_attempt_error) result
(** Durably block an unbound current-schema row before provider dispatch. The
    closed reason code and exact non-blank operator detail are persisted in the
    same snapshot and are retryable only through
    [reserve_summary_attempt_retry]. *)

val release_orphaned_start_reservation :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  (bool, exact_attempt_error) result
(** Boot-recovery reclaim of a start reservation orphaned by a hard process
    restart. The graceful settle to [Summary_attempt_identity_unbound] runs only
    in memory, so a process death in the reserve->bind window strands the
    durable [Summary_pre_worker_start_reserved] row with no restart handler.
    This reverses that reservation: an unbound start reservation returns to
    [Summary_attempt_ready] so boot recovery re-activates a worker. Distinct
    from [reserve_summary_attempt_retry], the operator path that never reclaims
    a start reservation. Safe only for a reservation whose in-memory admission
    is gone; the boot-recovery caller guards against reclaiming a live
    reservation via the process-local admission set. Returns [false] for any row
    that is not an unbound start reservation, leaving it untouched. *)

val summary_attempt_start_reserved_operator_detail : string

val reserve_summary_attempt_retry :
  base_path:string ->
  id:string ->
  input_hash:string ->
  sequence:int ->
  expected_exact_attempt:exact_attempt_state ->
  expected_disposition:summary_attempt_disposition ->
  requested_by:string ->
  (bool, exact_attempt_error) result
(** Explicit operator CAS from a blocked row directly to the typed durable
    start reservation. No intermediate ready row is persisted. The
    caller-observed row identity, exact attempt, and disposition must still
    match atomically. A restart-classified released binding returns to unbound
    in the same write. An existing start reservation is not retryable.
    Terminal exact quarantine is never retried. *)

val pending_count_for_keeper_in_workspace :
  base_path:string -> keeper_name:string -> (int, storage_error) result
(** Count one keeper's pending approvals within the durable workspace store.
    Store read failures remain explicit instead of collapsing to zero. *)
