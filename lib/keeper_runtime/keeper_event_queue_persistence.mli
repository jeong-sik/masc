(** Durable per-Keeper Event Layer state.

    Current writes go to [event-queue-v18.json] with the exact
    [keeper.event_queue.state.v17] compact-witness schema. The envelope holds
    revision, pending stimuli, the latest
    projected transition, an operation-indexed ledger of older projected
    dispositions, at most one unprojected transition, and durable
    accepted-transfer target projections. Only this schema and the
    [event-queue-transitions-v7.jsonl] WAL are queue authority. Every WAL row
    carries the complete pre-transition state needed for snapshot-independent
    recovery. The WAL accepts at most one row and is retired after projection,
    so its retained size is bounded by one complete state. Serializing that
    state on each transition is the intentional cost of recovery that does not
    infer missing sibling work from a delta. *)

(** The durable filenames this binary reads and writes. Callers outside
    OCaml — the deployment preflight script builds fixtures at these exact
    names — read them from here instead of repeating the version. *)
val snapshot_filename : string

val transition_wal_filename : string

val install_state_change_observer : (unit -> unit) -> unit
(** Install the process-wide non-yielding observer invoked after each durable
    event-queue snapshot or transition-WAL commit. Observer failures are logged
    and never change the already committed queue result. *)

type owner_identity
type owner_identity_error

val resolve_owner_identity :
  base_path:string ->
  keeper_name:string ->
  (owner_identity, owner_identity_error) result
(** Resolve the canonical process-local owner identity shared by every durable
    event-queue operation. The representation and owner-lock implementation
    remain private to [masc.keeper_runtime]. *)

val owner_identity_error_to_string : owner_identity_error -> string
val owner_identity_equal : owner_identity -> owner_identity -> bool
val owner_identity_hash : owner_identity -> int
val owner_identity_base_path : owner_identity -> string
val owner_identity_keeper_name : owner_identity -> string

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string
(** [Fsync_completed] means the payload and parent-directory [Unix.fsync]
    calls both returned successfully. It is the process-restart dispatch
    fence, not a hardware/power-loss persistence or Darwin [F_FULLFSYNC]
    guarantee. [Visible_sync_unconfirmed _] means rename is visible but the
    parent sync did not complete. *)

type accepted_cancellation = Keeper_event_queue_state.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_state.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  }

type source_terminal_receipt = Keeper_event_queue_state.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_completed
  | Turn_attempt_terminal of { detail : string }

type accepted_source_terminal = Keeper_event_queue_state.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition = Keeper_event_queue_state.transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

type transition_receipt = Keeper_event_queue_state.transition_receipt
type outbox_entry = Keeper_event_queue_state.outbox_entry

type transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt
  | Transition_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

val load_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t, string) result
(** Strict pending projection after durable transition-WAL replay. Durable read
    failures remain explicit. *)

val load_pending_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t, string) result
(** Strict pending projection. Durable read failures remain explicit. *)

val peek_when_result :
  base_path:string ->
  keeper_name:string ->
  now:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  (Keeper_event_queue.stimulus option, string) result

val select_when_result :
  base_path:string ->
  keeper_name:string ->
  now:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  (Keeper_event_queue_state.pending_selection option, string) result

val pending_selections_result :
  base_path:string ->
  keeper_name:string ->
  (Keeper_event_queue_state.pending_selection list, string) result
(** Read every pending entry with its exact immutable selection authority, in
    queue order. This is the durable admission snapshot used when one Keeper
    turn admits every ready source; it performs no mutation. *)

val validate_pending_selection_result :
  base_path:string ->
  keeper_name:string ->
  selection:Keeper_event_queue_state.pending_selection ->
  (unit, string) result

val ack_pending_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  selection:Keeper_event_queue_state.pending_selection ->
  unit ->
  (unit, string) result

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Incoherent_read

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

type 'pending with_read_errors =
  { pending : 'pending
  ; read_errors : snapshot_read_error list
  }
(** A pending projection paired with the typed read errors that emptied it.
    [read_errors = []] means [pending] is the durable truth; a non-empty list
    means the durable state could not be read and [pending] is empty. *)

type snapshot_with_errors = Keeper_event_queue.t with_read_errors

type selections_with_errors =
  Keeper_event_queue_state.pending_selection list with_read_errors
(** The same read with each pending entry's exact source authority
    ([source_snapshot_ref] input plus [admitted_revision]), so an operator
    surface can address one entry without a second read. *)

type durable_state_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

val snapshot_read_error_kind_to_string : snapshot_read_error_kind -> string
val discover_keeper_names_with_durable_state :
  base_path:string -> durable_state_discovery
val load_snapshot_with_errors :
  base_path:string -> keeper_name:string -> snapshot_with_errors

val load_selections_with_errors :
  base_path:string -> keeper_name:string -> selections_with_errors
(** {!load_snapshot_with_errors} projected through
    {!Keeper_event_queue_state.pending_selections}: the same durable read and
    the same typed read errors, keeping each entry's [admitted_revision]. *)

val observe_snapshot_with_errors :
  base_path:string -> keeper_name:string -> snapshot_with_errors
(** Read-only operator projection of the pending queue. Unlike
    {!load_snapshot_with_errors}, this observer never acquires the canonical
    queue-owner transaction lock and never checkpoints or compacts the
    transition WAL. It accepts only two identical full-state observations, so
    a concurrent snapshot/WAL generation change is an explicit read error
    rather than a healthy empty projection. *)

module For_testing : sig
  val observe_snapshot_with_errors_with_interleave :
    between_samples:(unit -> unit) ->
    base_path:string ->
    keeper_name:string ->
    snapshot_with_errors

  val snapshot_cache_reads : unit -> int
  val snapshot_cache_hits : unit -> int

  val reset_snapshot_cache_for_testing : unit -> unit
  (** The decoded snapshot is reused while the file it came from has not
      moved. A test asserts on these because the state being right does not
      say whether it was parsed again: an unchanged file must be a hit, and a
      rewritten one must not. *)
end

val load_state_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue_state.t, string) result
(** Strict state read used by tests and operator projection. A malformed
    current envelope or unknown schema is an [Error], never an empty
    queue. Committed current-schema WAL rows are replayed idempotently. A row
    already represented by the durable projected witness is compacted; an
    unprojected source-bearing row remains authoritative until the reaction
    projector records and retires it. *)

val validate_state_read_only_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue_state.t, string) result
(** Decode a current snapshot when present and replay its v6 WAL without
    checkpointing or WAL compaction. A missing snapshot starts from the WAL
    row's exact complete pre-transition state, matching {!load_state_result}. *)

val validate_existing_state_read_only_result :
  base_path:string -> keeper_name:string -> (Keeper_event_queue_state.t, string) result
(** Decode existing durable state and replay its v6 WAL without checkpointing
    or WAL compaction. A WAL-only owner is replayed from the row's exact
    complete pre-transition state;
    absence of both artifacts is an explicit error, matching
    {!load_state_result}. *)

val cancel_pending_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  applied_at:float ->
  cancellation:accepted_cancellation ->
  unit ->
  (transition_result, string) result
(** Append and fsync the canonical source-bearing cancellation transition before
    checkpointing removal of the exact pending source. WAL replay can complete
    the transition from the pre-removal state after a crash. *)

val transfer_pending_accepted_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  applied_at:float ->
  transfer:accepted_transfer ->
  unit ->
  (transition_result, string) result
(** Append and fsync the canonical source-bearing transfer transition before
    checkpointing removal of the exact pending source. *)

val ack_pending_source_terminal_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  acked_at:float ->
  source_terminal:accepted_source_terminal ->
  unit ->
  (transition_result, string) result
(** Append and fsync the canonical source-bearing ACK transition before
    checkpointing removal of the exact pending source. *)

val terminalize_pending_turn_attempt_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  applied_at:float ->
  selection:Keeper_event_queue_state.pending_selection ->
  detail:string ->
  unit ->
  (transition_result, string) result
(** Atomically construct and commit a source-bearing terminal receipt for one
    failed admitted turn. The selection carries the exact source incarnation;
    no caller-provided prose or counter controls admission. *)

val terminalize_pending_turn_completed_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  applied_at:float ->
  selection:Keeper_event_queue_state.pending_selection ->
  unit ->
  (transition_result, string) result
(** Atomically construct and commit a source-bearing completion receipt for one
    successful admitted turn. *)

val project_transition_outbox_result :
  append_before_retire:(outbox_entry -> (unit, string) result) ->
  base_path:string ->
  keeper_name:string ->
  (unit, string) result
(** Read the single pending transition under the canonical lane identity,
    invoke the supplied ledger append, and retire only after that append
    succeeds. Raw outbox entries and the retirement primitive are not exported
    independently. *)

val persist :
  base_path:string -> keeper_name:string -> Keeper_event_queue.t -> unit

val update :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t -> Keeper_event_queue.t) -> unit

val update_result :
  ?after_commit:(unit -> unit) ->
  base_path:string ->
  keeper_name:string ->
  (Keeper_event_queue.t -> Keeper_event_queue.t) ->
  (unit, string) result

val update_checked_result :
  ?after_commit:(unit -> unit) ->
  base_path:string ->
  keeper_name:string ->
  (Keeper_event_queue.t -> (Keeper_event_queue.t, string) result) ->
  (unit, string) result

val reprioritize_pending_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  selection:Keeper_event_queue_state.pending_selection ->
  urgency:Keeper_event_queue.urgency ->
  unit ->
  (int64, string) result
(** Source-incarnation-fenced priority change. Unrelated queue mutations do
    not invalidate the selected source. *)

val defer_pending_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  selection:Keeper_event_queue_state.pending_selection ->
  unit ->
  (int64, string) result
(** Durably rotate one exact transiently blocked source to the tail of its
    current urgency lane. *)

type enqueue_stimulus_result =
  | Enqueued
  | Already_present

val enqueue_stimulus_if_absent_result :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus ->
  (enqueue_stimulus_result, string) result
(** Atomically enqueue only when the same typed stimulus is absent from the
    full durable state: pending and transition outbox. *)

type 'authorization_error guarded_transfer_projection_result =
  | Transfer_projection_result of transfer_projection_result
  | First_projection_rejected of 'authorization_error

val project_accepted_transfer_guarded_result :
  authorize_first_projection:(unit -> (unit, 'authorization_error) result) ->
  after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  transfer:accepted_transfer ->
  ('authorization_error guarded_transfer_projection_result, string) result
(** Atomically distinguish an exact durable replay from a first target effect.
    [authorize_first_projection] runs under the target queue lock only when the
    exact accepted transfer is not already durable. A replay therefore
    converges after target identity rotation, while a first projection cannot
    create state for an absent or replaced Keeper. *)

val persist_snapshot :
  base_path:string -> keeper_name:string -> (unit -> Keeper_event_queue.t) -> unit

val ack_consumed :
  base_path:string ->
  keeper_name:string ->
  Keeper_event_queue.stimulus list ->
  (unit, string) result

val drop_by_post_id :
  ?after_commit:(Keeper_event_queue.t -> unit) ->
  base_path:string ->
  keeper_name:string ->
  post_id:string ->
  unit ->
  (Keeper_event_queue.stimulus list, string) result

type owner_lifecycle =
  | Runnable
  | Recoverable
  | Retained_disabled
  | Paused_dead
  | Shutdown_fenced
  | Lifecycle_unknown of string

(** Fleet projection split by the caller's canonical durable owner-lifecycle
    read. [Runnable] requires a live owner fiber; [Recoverable] is permitted
    owner truth with durable demand but no live fiber. Disabled, paused/dead,
    and shutdown-fenced owners remain distinct closed variants. Queue
    persistence deliberately does not infer owner truth from event contents or
    elapsed time. *)
val fleet_summary_json :
  now:float ->
  base_path:string ->
  owner_lifecycle:(keeper_name:string -> owner_lifecycle) ->
  Yojson.Safe.t
