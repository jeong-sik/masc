(** Sole-writer SQLite storage for Keeper chat operations. *)

module Operation = Keeper_chat_operation
module Semantic = Keeper_semantic_execution

type t

type error =
  | Invalid_input of string
  | Unknown_operation of Operation.Operation_id.t
  | Not_queued of Operation.Operation_id.t
  | Not_running of Operation.Operation_id.t
  | Idempotency_conflict of Operation.Operation_id.t
  | Store_unavailable of string
  | Integrity_error of string
  | Native_call_unsettled
      (** The operation's native call blocks this change: it is still active
          without a terminal disposition, or it holds an unknown-effect receipt
          that cannot complete or resume. The store is intact. An active call
          is settled by recording its disposition; an unknown-effect receipt
          allows only a failed or cancelled settlement. *)

type admission =
  | Accepted of Operation.t
  | Existing of Operation.t

type inventory =
  { queued_count : int
  ; running_operation_id : Operation.Operation_id.t option
  ; terminal_count : int
  ; interrupted_count : int
  }

val database_file : string
val path_for_keeper : keepers_runtime_dir:string -> keeper_name:string -> string

type input_history = Fresh_input_history | Prior_input_history_unavailable
(** A prior journal cannot prove that a missing trace row never had input.
    This durable global floor also covers omitted historical traces. *)
type input_checkpoint_observation =
  | Input_unobserved
  | Input_observed of Keeper_checkpoint_ref.t
  | Prior_input_unavailable

type outstanding_snapshot =
  | Missing_store
  | Stored_operations of { chat_operations : Operation.t list; semantic_executions : Semantic.t list; input_checkpoints : Keeper_checkpoint_ref.t list; input_history : input_history }

type durable_snapshot =
  | Missing_durable_store
  | Stored_durable_records of
      { chat_operations : Operation.t list
      ; batch_member_inputs : Yojson.Safe.t list
      ; semantic_executions : Semantic.t list
      ; input_checkpoints : Keeper_checkpoint_ref.t list
      ; input_history : input_history
      }

val inspect_outstanding : path:string -> (outstanding_snapshot, error) result
(** Read-only current-schema/integrity checked snapshot of queued/running
    operations, semantic executions owning retained checkpoints, and every
    trace's current input checkpoint. A checkpoint whose pending_input is None
    is still ownership evidence. Never creates, upgrades or recovers a store.
    Missing files remain distinct from a validated empty queue. Mutation callers
    must exclude the sole writer and creation for the whole enclosing commit. *)

val inspect_durable_records : path:string -> (durable_snapshot, error) result
(** Read-only schema/integrity checked snapshot of every durable record in the
    operation store, including terminal operations, frozen batch-member
    original inputs, and settled semantic executions. Used by whole-workspace
    blob reference scanning so no reference retained in an authoritative SQLite
    column can be collected. *)

val inspect_pending_inputs : path:string -> (Operation.t list option, error) result
(** Read-only, schema-checked transaction over queued/running inputs only.
    Does not scan terminal history or run a whole-database integrity audit.
    [None] means no database, distinct from an empty validated snapshot. *)

type input_checkpoint_update =
  | Input_checkpoint_updated
  | Input_checkpoint_source_changed of input_checkpoint_observation

val input_checkpoint : t -> trace_id:Keeper_id.Trace_id.t ->
  (input_checkpoint_observation, error) result
(** Input_unobserved is only available in a fresh journal. A missing trace in
    a journal with unresolved prior input history is Prior_input_unavailable,
    never Unobserved. Input_observed points to exact retained bytes, including
    consumed pending_input=None. None of these grants dispatch authority. *)

val update_input_checkpoint : t -> now:float -> observed:Keeper_checkpoint_ref.t option ->
  checkpoint:Keeper_checkpoint_ref.t -> (input_checkpoint_update, error) result
(** Owner-serialized predecessor CAS for the trace in checkpoint. The caller
    retains and validates the exact payload first. A stale predecessor returns
    the actual reference without writing. Uncertain commit remains an error;
    reread the actual relation to reconcile it, never blindly retry.
    This relation survives immutable operation/semantic terminal settlement.
    Before an independent update, the same transaction detaches canonical
    response lineages to their retained original execution branches. *)

val register_created_input_checkpoint : t -> checkpoint:Keeper_checkpoint_ref.t ->
  (input_checkpoint_update, error) result
(** Explicit new-trace registration, called only after the Owner validates the
    producer-owned creation seed for an empty actor. Registers this one exact
    retained reference even when prior history is unavailable; never changes
    the global floor. A different existing reference is refused. An exact
    existing reference is an idempotent observation, not permission to replay
    metadata or dispatch. This low-level storage function cannot validate the
    creation capability or filesystem evidence; the Owner must do so first. *)

val history_clear_input_checkpoint : t -> trace_id:Keeper_id.Trace_id.t ->
  (Keeper_checkpoint_ref.t option, error) result
(** Maintenance admission in a journal transaction. Refuse unavailable prior
    input, running operations, nonterminal semantic executions and any active or
    unacknowledged native call, including calls attached to terminal executions.
    None is a genuinely unobserved input, never a forgotten consumed request. *)

val commit_history_clear_input_checkpoint : t -> trace_id:Keeper_id.Trace_id.t ->
  observed:Keeper_checkpoint_ref.t option -> checkpoint:Keeper_checkpoint_ref.t option ->
  (input_checkpoint_update, error) result
(** Recheck the same unsettled-state guard and exact input predecessor in one
    transaction before publishing a confirmed operator clear. None revalidates
    genuinely fresh no-payload clears only; it cannot remove an observed input.
    The Owner must validate its original maintenance capability and the actual
    retained/canonical installation receipt. Filesystem and journal commits are
    separate. An uncertain commit remains Error and does not authorize replay. *)

module Offline : sig
  type prepared_copy =
    { operation_count : int; semantic_count : int; batch_member_count : int
    ; next_sequence : int64 }
  val prepare_v2_copy : source:Sqlite3.db -> destination:Sqlite3.db ->
    (prepared_copy, error) result
  (** Copy an exactly validated v2 source into a caller-reserved empty SQLite
      destination using SQLite Backup. Source is read only by this function;
      no startup settlement or ordinary open migration occurs. Transform only
      the private destination and preserve every original operation/semantic/
      batch cell and next_sequence. Prior input is marked globally unavailable,
      including omitted traces, and no checkpoint is imported as authority.

      Success verifies a transaction in the private destination, not publication,
      installation, source freshness after return, or a file/parent fsync receipt.
      A failed or uncertain result may leave a partial destination: retain it
      only as failed evidence, never install or blindly retry it. Caller owns
      both handles and must hold
      the original BasePath lease before promoting any offline artifact; this
      copy primitive neither acquires authority nor replaces a live journal. *)

  val verify_v2_copy : source:Sqlite3.db -> destination:Sqlite3.db ->
    (prepared_copy, error) result
  (** Read-only transactions over an exact v2 source and prepared v3 copy.
      Revalidate all original cells and the sequence, mandatory unavailable
      prior history, and the absence of imported input rows. This verifies
      the relationship, not file durability, live-source freshness or input
      authority. Both handles must have no active caller transaction. *)

  type prior_input_adoption = Operator_adopts_checkpoint of Keeper_checkpoint_ref.t
  (** An explicit operator decision, not evidence inferred from a canonical
      file, a maximum turn count or two absent pending requests. The caller
      must validate and retain the exact payload and record the adjudication
      with its source/bundle identity before exposing any installation.
      Constructing this variant is not proof of human authorization. *)
  type input_adoption_copy =
    { original_records : prepared_copy
    ; adopted_checkpoints : Keeper_checkpoint_ref.t list
    }

  val prepare_input_adoption_copy :
    source:Sqlite3.db -> destination:Sqlite3.db ->
    adoptions:prior_input_adoption list -> (input_adoption_copy, error) result
  (** Derive a separate private copy from a validated current-schema journal
      whose prior input is unavailable and whose input rows are still empty.
      Requires a nonempty explicit selection with one checkpoint per trace.
      Preserve every original operation/semantic/batch cell and sequence;
      install exactly the selected input references and keep the global
      unavailable-history floor. Omitted traces remain unavailable.

      Never mutates or reuses the published source bundle, clears uncertainty,
      chooses a checkpoint, reconstructs missing answers, settles executions,
      or grants native continuation authority. The operator adapter must
      preserve the original bundle and bind the derivative and retained
      payloads in a separate manifest. No CLI adoption/installation is provided
      by this database primitive. An uncertain commit is Error; preserve the
      derivative as evidence and read its actual relationship before deciding
      any next action. Handles are caller-owned with no active transactions. *)

  val verify_input_adoption_copy :
    source:Sqlite3.db -> destination:Sqlite3.db ->
    adoptions:prior_input_adoption list -> (input_adoption_copy, error) result
  (** Read-only verification of the original cells, unavailable global floor
      and exact selected input references in a derivative. A row with consumed
      pending_input=None is still selected ownership. This verifies identities
      only: it cannot certify retained payloads, the operator decision, file
      durability, live-source freshness or installation permission. *)
end

val open_or_create : path:string -> (t, error) result
val open_existing : path:string -> (t, error) result
(** Open and validate the current authoritative schema without creating or
    migrating a database. Used only by the serialized Owner recovery path. *)
type released_checkpoint
(** A retained checkpoint a committed transaction of this store released.
    Only {!take_released_checkpoints} makes one, so holding one is the proof
    that its file is no longer named. *)

val take_released_checkpoints : t -> released_checkpoint list
(** Hand over, once, the retained checkpoints that committed transactions on
    this handle released, oldest commit first. A transaction releases a
    reference one of its semantic writes stopped naming when, after all its
    writes, no execution or input owner {!inspect_outstanding} would select still names that
    sha256; it computes this before its COMMIT and publishes it only when the
    COMMIT returns success. A failed or uncertain commit releases nothing.
    Unavailable prior history discards release candidates without deleting
    files; after reconciliation, startup sweeping must rediscover orphans.
    The caller removes the files; nothing here touches the filesystem. *)

val released_reference : released_checkpoint -> Keeper_checkpoint_ref.t
val released_session_dir : session_root:string -> released_checkpoint -> string
(** The session directory holding the released file, under [session_root]. *)

val is_open : t -> bool
(** Whether this handle still names a live database. Every command is guarded,
    so this is not a precondition callers must check; it lets a caller that
    already knows why the handle was closed report that cause rather than the
    closure. *)

val close : t -> (unit, error) result
val path : t -> string

type batch_plan = { members : Operation.Operation_id.t list; input : Yojson.Safe.t }
type batch_selector = Operation.t -> Operation.t list -> (batch_plan option, string) result

val submit
  :  ?priority:batch_selector
  -> t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> source:Yojson.Safe.t
  -> input:Yojson.Safe.t
  -> (admission, error) result

val get : t -> Operation.Operation_id.t -> (Operation.t option, error) result
val list_restart_interrupted : t -> (Operation.t list, error) result
(** Every durable [Failed Interrupted_by_restart] record, including settled
    batch members. Re-reading after startup permits interrupted projection
    writes to retry; it is independent of newly running operations. *)
val inventory : t -> (inventory, error) result
(** Pure selector receives the contiguous fresh, unbound queued operations
    starting at the claimable head and ending before the next continuation.
    Members must be a contiguous prefix beginning with the head. The store freezes membership
    and combined input atomically with claim; resumed executions never acquire
    new members. *)
val claim_next : ?batch:batch_selector -> t -> now:float -> (Operation.t option, error) result
val batch_operations : t -> operation_id:Operation.Operation_id.t -> (Operation.t list, error) result
(** Ordered original member inputs and digests, including the execution owner.
    The claimed owner carries the aggregate input; this read preserves each
    original user message for transcript delivery. Terminal bodies are released.
    A singleton returns itself. *)

val list_queued
  :  t
  -> after_sequence:int64 option
  -> limit:int
  -> (Operation.t list, error) result

val edit_queued
  :  t
  -> operation_id:Operation.Operation_id.t
  -> input:Yojson.Safe.t
  -> (Operation.t, error) result

val move_queued_to_end
  :  t
  -> operation_id:Operation.Operation_id.t
  -> (Operation.t, error) result

(** Put one queued operation first, preserving the relative order and
    identity/input of every other operation in one transaction. *)
val move_queued_to_front : t -> now:float -> operation_id:Operation.Operation_id.t ->
  (Operation.t, error) result

(** Move a sender's still-queued priority cohort to the front in the supplied
    accepted order. A predecessor already running or terminal is skipped. A
    queued predecessor with a different source is rejected. All positions
    change in one transaction, so a running Keeper cannot claim an
    intermediate reversed order. *)
val move_queued_priority_cohort_to_front :
  t -> now:float -> operation_id:Operation.Operation_id.t ->
  predecessors:Operation.Operation_id.t list -> (Operation.t, error) result

val cancel_queued
  :  t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> (Operation.t, error) result

val succeed_running
  :  t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> outcome_ref:string
  -> (Operation.t, error) result

val fail_running
  :  t
  -> now:float
  -> operation_id:Operation.Operation_id.t
  -> kind:Operation.failure_kind
  -> detail:string
  -> outcome_ref:string option
  -> (Operation.t, error) result

(** Durable cooperative checkpoint continuation, independent of provider retry. *)
val direct_checkpoint : t -> operation_id:Operation.Operation_id.t -> (Keeper_semantic_execution.gate_checkpoint option, error) result
val direct_native_call : t -> operation_id:Operation.Operation_id.t ->
  (Keeper_native_call.state, error) result
val update_direct_native_call : t -> now:float -> operation_id:Operation.Operation_id.t ->
  execution_digest:string -> Keeper_native_call.change -> (unit, error) result
(** Owner-serialized native-call identity and checkpoint CAS. Every change
    verifies the current direct-operation execution digest. An operation input
    branch advances to each admitted Active native checkpoint in the same
    SQLite transaction and semantic CAS, including initial Bind. Its origin
    remains pinned, global input is untouched, and uncertain branch commits
    remain Error without readback-to-success. The Owner must validate the
    original executing child and retained candidate before publication. *)
val update_direct_branch_checkpoint : t -> now:float ->
  operation_id:Operation.Operation_id.t -> execution_digest:string ->
  call_id:string -> observed:Keeper_checkpoint_ref.t ->
  observed_branch:Keeper_checkpoint_ref.t -> checkpoint:Keeper_checkpoint_ref.t ->
  (unit, error) result
(** Compare the original operation's branch and native predecessors and advance
    both together. No global input read or write participates. A stale branch,
    native call or digest leaves both unchanged. Commit uncertainty stays Error.
    This is a storage primitive; it supplies no child or physical authority. *)
val update_direct_input_checkpoint : t -> now:float ->
  operation_id:Operation.Operation_id.t -> execution_digest:string ->
  call_id:string -> observed:Keeper_checkpoint_ref.t ->
  observed_input:Keeper_checkpoint_ref.t option -> checkpoint:Keeper_checkpoint_ref.t ->
  (input_checkpoint_update, error) result
(** Atomically advance the active direct native call and the trace's input
    owner. A stale input predecessor leaves both unchanged. The native-call
    identity, operation digest and phase retain their existing validation.
    An uncertain commit remains Error even if it installed both references.
    Reread native and input ownership together before reconciling; semantic
    readback alone is not confirmation and blind retry is not permitted. *)

val bind_direct_input_checkpoint : t -> now:float ->
  operation_id:Operation.Operation_id.t -> execution_digest:string ->
  observed:Keeper_native_call.state -> call:Keeper_native_call.t ->
  observed_input:Keeper_checkpoint_ref.t option -> checkpoint:Keeper_checkpoint_ref.t ->
  (input_checkpoint_update, error) result
(** Atomically bind the next native call and publish a verified input history
    cut. Owner validates the transformation before using this storage primitive.
    Both predecessor comparisons are transactional; uncertain commits stay Error.
    This and [update_direct_input_checkpoint] refuse operation input branches;
    a branch must use its own native/branch publication instead of global input. *)

val bind_direct_branch_checkpoint : t -> now:float ->
  operation_id:Operation.Operation_id.t -> execution_digest:string ->
  observed:Keeper_native_call.state -> call:Keeper_native_call.t ->
  observed_branch:Keeper_checkpoint_ref.t -> (unit, error) result
(** Compare the exact branch predecessor and native state, then bind the next
    native seed and advance the branch in one transaction. The retired native
    reference may differ from the host branch source: Owner must validate that
    physical relationship and its typed cut first. Global input is untouched;
    uncertain commits remain Error without readback-to-success. *)

val direct_input_wait : t -> operation_id:Operation.Operation_id.t ->
  (Keeper_semantic_execution.input_wait option, error) result
val defer_direct_input_wait : t -> now:float -> operation_id:Operation.Operation_id.t ->
  execution_digest:string -> waiting:Keeper_semantic_execution.input_wait -> (Operation.t, error) result
(** Atomic original direct-operation input wait. The Owner must first validate
    its original child, trace and exact retained request. The transaction checks
    current global or operation branch input ownership, the execution digest
    and matching native Retire;
    it acknowledges that receipt, records the wait and requeues the same input.
    Active/unknown effects, stale references and conflicting waits are refused.
    Waiting is blocked from claiming and priority indefinitely; no time-based
    expiry or generic resume. An uncertain commit stays Error; read actual
    state before reconciliation. This grants no response admission. *)

(** For an operation branch, a same-turn retained host checkpoint may follow
    the actual Retire receipt. Owner must prove the exact physical N -> H
    relation, pending ownership and history/repetition preservation first. The
    transaction rechecks branch H and Retire N and acknowledges only N; the
    global path still requires the exact native/input reference. *)

val direct_input_response_intent : t -> operation_id:Operation.Operation_id.t ->
  (Keeper_semantic_execution.input_response_intent option, error) result
(** The actual persisted intent, or None when no intent is recorded. Files or
    matching checkpoint hashes never supply a missing intent. *)
val direct_input_branch : t -> operation_id:Operation.Operation_id.t ->
  (Keeper_semantic_execution.input_branch option, error) result
(** Read this exact operation's stored branch, never the trace's global head. *)
val checkpoint_direct_input_branch : t -> now:float ->
  operation_id:Operation.Operation_id.t -> execution_digest:string ->
  observed:Keeper_checkpoint_ref.t -> checkpoint:Keeper_checkpoint_ref.t ->
  (unit, error) result
(** CAS of a retained host checkpoint, with exact running operation/digest and
    native settlement checks. This never reads or writes global input. Physical
    retention, pending and original child/scope validation belong to the caller.
    Commit uncertainty remains Error and grants no deletion/retry authority. *)
val prepare_direct_input_response : t -> now:float -> operation_id:Operation.Operation_id.t ->
  execution_digest:string -> intent:Keeper_semantic_execution.input_response_intent ->
  (unit, error) result
(** Record one response intent under the original queued operation/digest/wait,
    acknowledged native state and current input predecessor in one transaction.
    The Owner must first validate its original child, canonical source and frozen
    candidate and confirm candidate retention. This primitive does no checkpoint filesystem I/O
    and grants no response acceptance or resume. Source/candidate join semantic
    retention; duplicates preserve the fact, conflicting intents refuse. A
    same-payload canonical intent can advance only to Operation_input. That
    destination preserves the global input and the exact current branch wait;
    Canonical_input still requires the original global predecessor. Commit
    uncertainty stays Error without readback-to-success or cleanup authority. *)

val resolve_direct_input_wait : t -> now:float -> operation_id:Operation.Operation_id.t ->
  execution_digest:string -> observed:Keeper_semantic_execution.input_wait ->
  checkpoint:Keeper_checkpoint_ref.t -> (unit, error) result
(** The Owner first validates its exclusive response child and sealed physical
    installation receipt. One transaction consumes the exact queued wait and
    current input predecessor, publishes its consumed checkpoint and enables the
    same operation's checkpoint continuation. This is never a new prompt.
    A prepared intent, when present, pins the exact consumed candidate.
    Operation_input instead consumes its exact prepared candidate into the
    operation's branch without updating the trace's global input. Duplicate/stale
    responses refuse; uncertain commit acknowledgement stays
    Error and grants no retry or retained-file deletion authority. *)

val defer_direct_checkpoint : t -> now:float -> operation_id:Operation.Operation_id.t -> execution_digest:string ->
  checkpoint:Keeper_semantic_execution.gate_checkpoint -> (Operation.t, error) result
val resume_direct_checkpoint : t -> now:float -> operation_id:Operation.Operation_id.t ->
  observed:Keeper_semantic_execution.gate_checkpoint -> (unit, error) result

val direct_runtime_retry :
  t -> operation_id:Operation.Operation_id.t ->
  (Semantic.runtime_retry option, error) result
(** A pending continuation is bound to the same operation's current canonical
    input digest. Terminal, edited or mismatched input cannot authorize replay. *)
val defer_direct_runtime_retry :
  t -> now:float -> operation_id:Operation.Operation_id.t -> execution_digest:string ->
  continuation:Semantic.runtime_retry -> (Operation.t, error) result
(** Atomically preserve the original operation input and frozen checkpoint/runtime
    authority in the existing semantic journal, and return the same operation to
    Queued. The caller must already have persisted the canonical checkpoint. *)
val update_direct_runtime_retry_wait :
  t -> now:float -> operation_id:Operation.Operation_id.t ->
  observed:Semantic.runtime_retry -> replacement:Semantic.runtime_retry -> (bool, error) result
(** Update only the exactly observed queued retry after a dependency change. The retained checkpoint,
    operation input and effect scope stay owned by the same execution. Returns
    [false] when another transition has replaced or consumed the witness. *)
val resume_direct_runtime_retry :
  t -> now:float -> operation_id:Operation.Operation_id.t ->
  observed:Semantic.runtime_retry -> (unit, error) result
(** The caller independently re-reads and validates the canonical checkpoint.
    After Owner claim, compare that observed checkpoint/runtime identity before
    consuming continuation into Running. An interrupted resumed execution needs
    reconciliation; it is never blindly replayed from a stale checkpoint. *)

(** Settle every [Running] operation as [Failed Interrupted_by_restart] and
    return those operations as they were read, so the caller can leave an
    operator-visible failure row for each: without one, a request the
    restart cut off vanished from the transcript with no answer
    (msx-retro-mania, three requests on 2026-09-14). *)
val settle_running_after_restart : t -> now:float -> (Operation.t list, error) result
val error_to_string : error -> string

module For_testing : sig
  type commit_fault =
    | Fail_before_commit
    | Fail_after_commit

  val fail_next_commit : commit_fault -> unit
  val clear_commit_fault : unit -> unit
  val fail_next_runtime_retry_read : unit -> unit
  val clear_runtime_retry_read_fault : unit -> unit
  val database_file : string
  val database_application_id : int64
  val table_column_counts : (string * int) list
  val owning_semantic_executions : t -> (Semantic.t list, error) result
  (** The executions a commit's release reads as live, selected partly in SQL. *)
end

(** Semantic execution records share the Owner's SQLite journal. Suspended or
    recovering records reserve only their own sources, never the running slot. *)
type semantic_error =
  | Semantic_store_error of error
  | Admission_conflict of Keeper_execution_scope_id.t
  | Sources_owned of Keeper_execution_scope_id.t list
  | Invalid_execution of Semantic.error

type semantic_admission = Semantic_created of Semantic.t | Semantic_existing of Semantic.t
val semantic_error_to_string : semantic_error -> string
val semantic_get : t -> Keeper_execution_scope_id.t -> (Semantic.t option, semantic_error) result
val semantic_outstanding : t -> (Semantic.t list, semantic_error) result
val semantic_prepare :
  t -> id:Keeper_execution_scope_id.t -> input:Yojson.Safe.t -> sources:Semantic.source_member list -> now:float ->
  (semantic_admission, semantic_error) result
(** The identity is Direct_operation or Autonomous_admission without aliases.
    The canonical typed JSON key includes both origin and scalar. Commits the
    identity, initialized empty repetition frame, source membership and
    Preparing phase together. Reusing identity never clears recorded evidence.
    An uncertain commit is an error; reload by that identity before deciding a
    retry. Different outstanding operations may coexist with disjoint sources. *)

val start_autonomous_execution :
  t -> id:Keeper_execution_scope_id.t -> input:Yojson.Safe.t ->
  sources:Semantic.source_member list -> now:float ->
  (semantic_admission, semantic_error) result
(** Commit one producer-supplied Autonomous_admission, original input, exact
    source ownership and Running phase together. Direct identities are refused.
    [Semantic_existing] only observes the unchanged original record, including
    a parked wait; it never grants another provider dispatch. A failed or
    uncertain commit must be reconciled by the same identity, not a fresh UUID.
    The caller must be the admitted Owner child with freshly validated intake. *)

type autonomous_input_wait_update =
  | Autonomous_input_wait_installed of Semantic.t
  | Autonomous_input_wait_existing of Semantic.t
  | Autonomous_input_wait_source_changed of input_checkpoint_observation

val defer_autonomous_input_wait :
  t -> now:float -> id:Keeper_execution_scope_id.t -> input_sha256:string ->
  observed:Keeper_checkpoint_ref.t option -> waiting:Semantic.input_wait ->
  (autonomous_input_wait_update, semantic_error) result
(** Atomically compare the captured global input predecessor, publish the
    retained checkpoint and park only its original autonomous execution.
    Original input/source membership remain owned, without a chat row, running
    chat slot or invented native Retire receipt. An exact existing wait is a
    read observation and never overwrites a newer independent global input.
    Conflicting requests, changed admission digests, native effects and stale
    predecessors leave both relations unchanged. Retention and complete pending
    payload/scope/trace/child validation remain the Owner caller's obligations;
    opaque references alone are not physical or response authority. This API
    does not implement autonomous response, resume, heartbeat intake or seeding. *)

(** Gate waiting remains the original queued operation, but cannot be claimed
    until a bound durable resolution is supplied. A deferred runtime retry
    whose provider-throttle [not_before] lies after [now] is likewise not
    claimable; the scheduled wake re-offers it once the backoff passes. *)
val has_claimable_queued : t -> now:float -> (bool, error) result

(** True only if a still-queued original chat was inserted after the named
    running operation. Queued direct continuations are excluded even when a
    cooperative checkpoint moved them behind later operations. *)
val has_newer_original_queued : t -> operation_id:Operation.Operation_id.t -> (bool, error) result

val next_runtime_retry_wake : t -> now:float -> (float option, error) result
(** Earliest future [not_before] among cooling deferred runtime retries, so the
    owner can re-arm the drain wake after a restart (the defer-time sleeper
    dies with the process). [None] when nothing is cooling past [now]. *)
val direct_gate_state : t -> operation_id:Operation.Operation_id.t -> (Semantic.gate_wait_state option, error) result
val direct_gate_obligations : t -> operation_id:Operation.Operation_id.t -> (Semantic.gate_obligation list, error) result
val defer_direct_gate : t -> now:float -> operation_id:Operation.Operation_id.t -> execution_digest:string ->
  waiting:Semantic.gate_wait -> (Operation.t, error) result
val resolve_direct_gate : t -> now:float -> operation_id:Operation.Operation_id.t ->
  resolution:Semantic.gate_resolution -> (Operation.t, error) result
val resume_direct_gate : t -> now:float -> operation_id:Operation.Operation_id.t ->
  waiting:Semantic.gate_wait -> resolution:Semantic.gate_resolution -> (unit, error) result

val discharge_direct_gate : t -> now:float -> operation_id:Operation.Operation_id.t ->
  obligation:Semantic.gate_obligation -> (unit, error) result

val direct_gate_waits : t -> ((Operation.Operation_id.t * Semantic.gate_wait_state) list, error) result

val defer_direct_gate_reconciliation : t -> now:float -> operation_id:Operation.Operation_id.t -> execution_digest:string ->
  binding:Semantic.gate_binding -> diagnostic:string -> (Operation.t, error) result

val direct_gate_binding : t -> operation_id:Operation.Operation_id.t -> (Semantic.gate_binding option, error) result

val direct_gate_bindings : t -> ((Operation.Operation_id.t * Semantic.gate_binding) list, error) result
val reconcile_direct_gate_binding : t -> now:float -> operation_id:Operation.Operation_id.t ->
  binding:Semantic.gate_binding -> waiting:Semantic.gate_wait -> (unit, error) result
