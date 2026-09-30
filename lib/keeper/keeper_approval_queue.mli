(** Durable, nonblocking HITL requests for Keeper external effects.

    The queue does not classify actions, suspend a Keeper fiber, or interpret a
    tool/product name. It records an exact request, accepts an explicit
    resolution, and wakes only the originating Keeper lane. *)

open Keeper_approval_queue_rules_types
open Keeper_approval_queue_result

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
    journals or Gate recovery from being attempted.
    A spent delivery is removed from the store; the count is
    [retired_deliveries]. A delivery is spent when its wake was delivered and
    is no longer in its Keeper's event queue, no unsettled execution of that
    Keeper names the approval, and an approval's grant is consumed; or when its
    Keeper's meta file is gone: deleting a Keeper drops its approvals and
    rejections, used or not, at the next install, so a Keeper created again
    under the same name starts without them. A delivery whose Keeper meta,
    queue, or operation store cannot be read, whose Keeper meta does not decode
    as the current schema, or whose Keeper has meta but no queue, is kept. The removal is skipped while the store or the replay projection is
    unavailable, and a failed write is reported in
    [delivery_retirement_error] and retried at the next install. *)
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

val continuation_settled_chat_projection_present :
  base_path:string ->
  keeper_name:string ->
  approval_id:string ->
  bool
(** Whether the approval's continuation slot holds a settlement of either
    phase ([Approval_continuation_recorded] or
    [Approval_continuation_failed]). The intake reads this before a queued
    resolution is delivered again. *)

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

(** Record instruction delivery after an official client transmitted the admitted
    resolution and a later turn settled in the same captured session. This is
    not an effect receipt and does not consume an available one-shot grant. *)
val record_native_continuation_delivery :
  base_path:string -> keeper_name:string ->
  resolution:Keeper_event_queue.hitl_resolution ->
  (continuation_projection_result, string) result

(** Record the continuation as failed when the turn that received the
    replay failed after the provider answered ([route] satisfies
    {!Keeper_runtime_failure_route.response_observed}). The same readiness
    rule applies, so a grant the turn never spent is not settled by its
    failure. The row shares the continuation slot with the recorded
    receipt: one settlement per approval, and the intake retires the queued
    wake on either (#32956). *)
val ensure_failed_continuation_chat_projection :
  base_path:string ->
  keeper_name:string ->
  resolution:Keeper_event_queue.hitl_resolution ->
  route:Keeper_runtime_failure_route.route ->
  (continuation_projection_result, string) result

val generate_id : unit -> string

module For_testing : sig
  type strict_snapshot_writer =
    string -> string -> (unit, Fs_compat.atomic_replace_failure) result

  val with_unavailable_workspace : base_path:string -> (unit -> 'a) -> 'a
  (** Expose the production unavailable-store observation without removing its durable requests. *)
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
    row and takes no part in the request's identity.

    [observation] is what the executor's box refused when the Gate ran the
    request boxed before deferring it (RFC-0422): stored on the row, shown
    to the judge, no part of the identity either. *)
val submit_pending :
  keeper_name:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  call_summary:string option ->
  base_path:string ->
  ?turn_id:int ->
  ?request_context:Yojson.Safe.t ->
  ?observation:Keeper_approval_queue_rules_types.observed_refusal ->
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

(** Commit a resolution, optionally persist an exact Always Allowed rule for
    [Decision.Approve], then wake only the Keeper captured by the pending entry.
    [rule_expires_at] is an absolute Unix expiry applied to the remembered
    rule; it is ignored unless [remember_rule] is [true].

    [base_path] is the authenticated caller workspace. The pending or
    in-progress delivery entry must belong to it exactly before any resolution
    claim or journal mutation is attempted.

    A delivery that {!install_persistence} retired as spent is gone from the
    queue, so deciding it again returns [Not_found] and writes nothing; the
    decision stays on the audit ledger. While the delivery is still held, the
    same request again completes without a new ledger row and a different one
    is [Already_resolved]. *)
val resolve_with_policy :
  base_path:string ->
  id:string ->
  decision:decision ->
  source:decision_source ->
  ?remember_rule:bool ->
  ?rule_expires_at:float ->
  ?created_by:string ->
  unit ->
  (resolution_result, resolve_error) result
(** [source] is required: who decided is audit identity, and a default would
    mint [Human_operator] for callers that never named one. *)

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

(** Durable observation for an operation waiting on this exact Gate request.
    [None] is absent authority, never an implicit approval or denial. *)
type waiting_observation = private
  { waiting_request : pending_approval; waiting_decision : decision option }
val observe_waiting_request : base_path:string -> id:string ->
  (waiting_observation option, storage_error) result
