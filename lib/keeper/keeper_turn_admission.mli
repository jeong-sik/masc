(** Temporary per-Keeper turn/shutdown fence. Keeper Owner is the sole live
    scheduling authority; this module retains the non-waiting execution fence
    until shutdown and durable-intake ownership are split out. *)

type lane =
  | Autonomous (** heartbeat-scheduled cycle; skips when the slot is busy *)
  | Chat (** diagnostic projection of an Owner-run chat operation *)

type slot_transition =
  | Turn_released
  | Shutdown_rolled_back

type slot_transition_observer =
  base_path:string ->
  keeper_name:string ->
  transition:slot_transition ->
  unit

val set_slot_transition_observer : slot_transition_observer option -> unit
(** Install the single non-blocking observer for transitions that can make a
    Keeper lane dispatchable again. It runs after the turn mutex/state mutex is
    released. Observer failures are logged and cannot alter admission state. *)

type in_flight_info =
  { lane : lane
  ; started_at : float (** Unix epoch seconds when the turn was admitted *)
  }

type autonomous_block =
  | Turn_busy of in_flight_info option
  | Shutdown_requested of Keeper_shutdown_types.Operation_id.t

val autonomous_block_kind : autonomous_block -> string
val autonomous_block_to_string : autonomous_block -> string
val autonomous_block_to_yojson : autonomous_block -> Yojson.Safe.t
(** Canonical typed projections for admission diagnostics. Consumers must not
    recover block detail by parsing prose. *)

type shutdown_reservation =
  { operation_id : Keeper_shutdown_types.Operation_id.t
  ; in_flight : in_flight_info option
  }

type begin_shutdown_result =
  | Shutdown_reserved of shutdown_reservation
  | Shutdown_already_reserved of shutdown_reservation

type rollback_shutdown_result =
  | Shutdown_rolled_back
  | Shutdown_not_reserved
  | Shutdown_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type restore_shutdown_result =
  | Shutdown_restored
  | Shutdown_already_restored
  | Shutdown_restore_conflict of Keeper_shutdown_types.Operation_id.t

type transition_shutdown_result =
  | Shutdown_transition_applied
  | Shutdown_transition_already_applied
  | Shutdown_transition_reserved_by_other of Keeper_shutdown_types.Operation_id.t

type 'a registration_commit_result =
  | Registration_committed of 'a
  | Registration_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type 'a durable_intake_result =
  | Intake_committed of 'a
  | Intake_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type 'a transfer_intake_result =
  | Transfer_intake_committed of 'a
  | Transfer_intake_source_shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Transfer_intake_target_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

type intake_token
(** Opaque authority for one currently admitted durable intake. The token is
    valid only inside the callback passed to [run_durable_intake_if_open]. *)

type slot_snapshot =
  { snapshot_keeper_name : string
  ; snapshot_slot_created : bool
  ; snapshot_in_flight : in_flight_info option
  ; snapshot_shutdown_operation_id : Keeper_shutdown_types.Operation_id.t option
  }

type fleet_snapshot =
  { fleet_keeper_count : int
  ; fleet_in_flight_keeper_count : int
  ; fleet_shutdown_keeper_count : int
  ; fleet_slots : slot_snapshot list
  }

type token
(** Opaque authority for one currently admitted Keeper turn. The token is
    invalidated before the underlying slot is released and cannot be
    constructed outside this module. *)

val lane_to_string : lane -> string

val run_if_free_with_token
  :  base_path:string
  -> keeper_name:string
  -> (token -> 'a)
  -> [ `Ran of 'a | `Busy of autonomous_block ]
(** [run_if_free], additionally exposing the authority token owned by the
    admitted closure. Intake side effects and provider dispatch must stay
    inside this closure. *)

val install_before_dispatch_authority
  : token -> (unit -> (unit, string) result) -> (unit, string) result
(** Install the immutable selected-source/lifecycle validator for this turn.
    Installation is single-assignment and fails after token release. *)

val validate_before_dispatch : token -> (unit, string) result
(** Revalidate that the admission is still active and invoke its installed
    authority immediately before a provider dispatch. *)

val run_if_free
  :  base_path:string
  -> keeper_name:string
  -> (unit -> 'a)
  -> [ `Ran of 'a | `Busy of autonomous_block ]
(** Run [f] holding the keeper's turn slot, or return [`Busy] without
    blocking when another turn is in flight. The autonomous lane uses this:
    a busy slot skips the cycle and the next heartbeat retries naturally.
    [`Busy (Turn_busy None)] means the slot is held but the holder has not yet
    published its info (admission in progress on another fiber).
    [`Busy (Shutdown_requested id)] means a durable shutdown reservation owns
    admission; no slot is acquired and no turn body runs.
    Exceptions from [f] (including [Eio.Cancel.Cancelled]) release the slot and
    re-raise. This module never parks or queues callers. *)

val in_flight
  :  base_path:string
  -> keeper_name:string
  -> in_flight_info option
(** Read-only snapshot of the turn currently holding the keeper's slot,
    or [None] when the slot is free or the keeper is unknown. *)

(** Atomically close admission for [keeper_name] and snapshot the turn that
    already owns the slot. New autonomous/chat turns receive the typed
    [`Shutdown_requested] result after this succeeds. *)
val begin_shutdown :
  base_path:string ->
  keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  begin_shutdown_result

(** Re-open admission only when [operation_id] still owns the reservation.
    Used when durable prepare fails before cancellation begins. An owner with
    no existing admission slot returns [Shutdown_not_reserved] without
    allocating a slot. *)
val rollback_shutdown :
  base_path:string ->
  keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  rollback_shutdown_result

(** Restore the admission owner from a durable non-terminal shutdown record
    before boot recovery or same-name registration starts. The operation id is
    compared as a typed identity; a different in-memory owner is never
    overwritten. *)
val restore_shutdown :
  base_path:string ->
  keeper_name:string ->
  operation_id:Keeper_shutdown_types.Operation_id.t ->
  restore_shutdown_result

(** Atomically release [from_operation_id], or transfer its reservation to
    [to_operation_id]. A missing slot is an already-applied release; when a
    durable successor is supplied, a missing reservation is restored to that
    successor. A different live owner is never overwritten. *)
val transition_shutdown :
  base_path:string ->
  keeper_name:string ->
  from_operation_id:Keeper_shutdown_types.Operation_id.t ->
  to_operation_id:Keeper_shutdown_types.Operation_id.t option ->
  transition_shutdown_result

(** Run the registry [commit] only while no shutdown operation owns the Keeper
    admission fence. Shutdown reservation and same-name lane installation are
    therefore totally ordered.

    PRECONDITION — [commit] must not suspend the calling fiber. It runs inside
    a [Stdlib.Mutex] critical section, and [Stdlib.Mutex.lock] blocks the OS
    thread that runs the Eio scheduler: a fiber that suspends here can never be
    resumed, so any other fiber on the domain that touches this slot wedges the
    entire domain with no timeout and no diagnostic. Concretely, [commit] must
    not acquire the per-keeper lifecycle key lock
    ([Keeper_lifecycle_reservation.with_key_lock] suspends via
    [Cross_context_mutex]); acquire that lock around this call instead, as
    [Keeper_registry_setup] does. The type cannot express this — OCaml has no
    effect annotation for "does not suspend" — so the obligation is on the
    caller and is covered by
    [test/test_keeper_registry_admission_no_suspend.ml]. *)
val commit_registration_if_open :
  base_path:string ->
  keeper_name:string ->
  (unit -> 'a) ->
  'a registration_commit_result

(** Serialize one suspending durable intake effect with shutdown join. The
    shutdown fence is checked after the intake mutex is acquired: intake that
    wins commits before [await_idle_after_shutdown] returns, while a shutdown
    that wins prevents the effect from starting. *)
val run_durable_intake_if_open :
  base_path:string ->
  keeper_name:string ->
  (intake_token -> 'a) ->
  'a durable_intake_result

(** Hold both source and target durable-intake fences in canonical Keeper-name
    order for one transfer effect. Opposing A-to-B and B-to-A operations
    therefore cannot form an ABBA wait cycle. The callback receives live
    owner-specific tokens and must complete every source and target durable
    mutation before returning. *)
val run_transfer_intake_if_open :
  base_path:string ->
  from_keeper:string ->
  to_keeper:string ->
  (source_intake_token:intake_token ->
   target_intake_token:intake_token ->
   'a) ->
  'a transfer_intake_result

val intake_token_matches :
  intake_token ->
  base_path:string ->
  keeper_name:string ->
  bool
(** [true] only for a live token belonging to the requested Keeper. *)

(** Join the current turn holder and any durable external intake after
    admission has been closed. This waits without an invented timeout, then
    immediately releases both slots. Never call from the same admitted turn
    or intake. *)
val await_idle_after_shutdown : base_path:string -> keeper_name:string -> unit

val snapshot_for : base_path:string -> keeper_name:string -> slot_snapshot
(** Raw, read-only admission state for one keeper. Unknown keepers return a
    zero-valued snapshot with [snapshot_slot_created = false]; no slot is
    allocated by observation. *)

val fleet_snapshot : base_path:string -> keeper_names:string list -> fleet_snapshot
(** Fleet-level admission state for configured [keeper_names] plus any live
    slot already observed under [base_path]. This keeps dashboard/health
    observability from hiding an active slot simply because the meta/config
    scan missed it. *)

val slot_snapshot_to_yojson : slot_snapshot -> Yojson.Safe.t

val fleet_health_json :
  base_path:string -> keeper_names:string list -> Yojson.Safe.t
(** Health component for [/health] and dashboard runtime resolution. Durable
    queued work is reported by the Keeper Owner operation projection. *)

module For_testing : sig
  val reset : unit -> unit

  (** Hold the raw turn mutex without publishing [in_flight_info]. Constructs
      the documented lock-to-observability window for deterministic admission
      regression tests. *)

  val peek
    :  base_path:string
    -> keeper_name:string
    -> in_flight_info option option
  (** [Some info] for an occupied slot, [Some None] for a created idle slot,
      or [None] if never created. *)
end
