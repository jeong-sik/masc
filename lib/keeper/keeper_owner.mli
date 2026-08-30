(** Single-fiber metadata owner for one Keeper.

    Producers communicate through a bounded mailbox.  [apply_meta],
    and [exact_projection] apply backpressure when the mailbox is full;
    commands are never dropped or coalesced. Once enqueued, a request settles
    before caller cancellation can release its surrounding authority scope.
    Routine reads use {!projection} and do not enter the mailbox. *)

val mailbox_capacity : int

val install_state_change_observer : (unit -> unit) -> unit
(** Install the process-wide non-yielding observer invoked after a
    health-visible operation, turn, or shutdown projection changes. Observer
    failures are logged and never change the accepted Owner result. *)

type store =
  { replace : Keeper_meta_contract.keeper_meta -> (unit, string) result
  ; remove : Keeper_meta_contract.keeper_meta -> (unit, string) result
  }

module Chat_operation = Keeper_chat_operation

type operation_projection =
  { queued_count : int
  ; running_operation_id : Chat_operation.Operation_id.t option
  ; terminal_count : int
  ; interrupted_count : int
  ; store_unavailable : bool
  }

type turn_lane =
  | Autonomous
  | Chat_operation
  | Maintenance

type turn_in_flight =
  { lane : turn_lane
  ; started_at : float
  }
(** At most one turn runs per Keeper, across all three lanes. The Owner holds
    that slot; {!Keeper_turn_dispatch_authority} states the same boundary from
    the other side ("Keeper Owner owns scheduling and single-running
    admission") and carries no per-Keeper mutex of its own.

    What the slot protects is a single-writer invariant. A turn drives the
    per-Keeper turn FSM through [Keeper_registry.set_turn_phase], which
    resolves every transition against the current phase and raises
    [Turn_phase_transition_violation] for a forbidden one. Two turns on one
    Keeper would each transition from whatever the other left behind, so
    concurrency here does not corrupt state quietly — it raises, and the
    violation counter [masc_fsm_guard_violation_total] records it. Measured
    over 2026-08-10..12 on the live fleet: 162,813 turn-phase transitions and
    0 violations.

    The exclusion is an invariant; the *order* in which contending lanes get
    the freed slot is not specified here and is not fair today — a queued chat
    operation is offered the slot synchronously when a turn ends, while the
    autonomous lane discovers it only on its next keepalive poll. RFC-0373
    measures the resulting starvation and is where an admission policy belongs.
    Any such policy must keep the invariant above, not merely the counter. *)

(** Wire spelling of a {!turn_lane} ("autonomous" / "chat_operation" /
    "maintenance"). Every projection that serializes a lane reads this one
    mapping; consumers must not re-spell the variants locally. *)
val turn_lane_to_string : turn_lane -> string

type autonomous_block =
  | Turn_busy of turn_in_flight option
  | Shutdown_requested of Keeper_shutdown_types.Operation_id.t

type shutdown_reservation =
  { operation_id : Keeper_shutdown_types.Operation_id.t
  ; in_flight : turn_in_flight option
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

type operation_acceptance =
  { operation : Chat_operation.t
  ; existing : bool
  ; queued_count : int
  }

type operation_error_kind =
  | Invalid_operation_input
  | Unknown_operation
  | Operation_not_queued
  | Operation_idempotency_conflict
  | Operation_store_unavailable

type error =
  | Reducer_rejected of Keeper_owner_reducer.error
  | Operation_rejected of Keeper_chat_operation_store.error
  | Store_unavailable of string
  | Owner_stopping
  | Owner_closed

type operation_execution =
  | Operation_succeeded of { outcome_ref : string }
  | Operation_failed of
      { kind : Chat_operation.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }

type operation_executor =
  sw:Eio.Switch.t ->
  keeper_name:string ->
  claim:(unit -> (Chat_operation.t option, error) result) ->
  operation_execution
(** One Owner-owned child execution. The executor must not cache an operation
    body before [claim]: [claim] is the mailbox-linearized Queued-to-Running
    boundary and returns the latest edited input. *)

type operation_runner =
  { ready : keeper_name:string -> bool
  ; execute : operation_executor
  ; on_execution_settled :
      keeper_name:string ->
      claimed_operation_id:Chat_operation.Operation_id.t option ->
      execution:operation_execution ->
      unit
  }
(** Typed admission for the durable operation drain. [ready] must be a
    non-yielding in-memory read. When it returns [false], the FIFO head remains
    Queued and no child is started. The producer that makes the dependency
    ready must call {!wake_operation_drain}; the Owner never polls.

    [on_execution_settled] runs on the Owner fiber after the child switch has
    fully unwound — every executor fiber has finished or been cancelled — and
    before the durable settle is applied. A cancelled child cannot publish its
    own terminal event, so this is the only point that both survives the
    cancellation and still knows the execution verdict. Implementations
    project the verdict to live consumers (wire-terminal synthesis); they must
    not mutate durable state. Exceptions are contained by the Owner. *)

type t

val start
  :  sw:Eio.Switch.t
  -> store:store
  -> operation_store_path:string
  -> now:(unit -> float)
  -> operation_runner:operation_runner option
  -> on_turn_slot_released:(unit -> unit) option
  -> keeper_name:string
  -> initial_meta:Keeper_meta_contract.keeper_meta option
  -> (t, error) result
(** [on_turn_slot_released] fires when a turn ends, the slot is still unclaimed
    after the queued chat operation (if any) has been offered it, and the
    autonomous lane has been refused the slot since the last notification. The
    signal therefore means "the lane that lost the slot can start now", not "a
    turn ended".

    All three conditions are load-bearing. Dropping the third one is what
    {!Keeper_registry.Turn_slot_released} did on 2026-08-12: a keeper woken by
    the release starts its next turn at once, so every turn end scheduled the
    next turn and the keepalive cadence stopped governing. Measured on the live
    fleet across the restart that carried it: turn starts went from 114.9/hour
    to 1523.5/hour, and the median interval between keepalive cycles fell from
    313s to 10s — the turn duration, not the configured cadence.

    It exists because the two lanes learn about a free slot by opposite means.
    A chat producer notifies the Owner through {!wake_operation_drain} — "the
    Owner never polls", as the {!operation_runner} contract says — while the
    autonomous lane has no such channel and rediscovers the slot only on its
    next keepalive cadence. RFC-0373 measured what that costs: over 2026-08-12
    all 50 autonomous deferrals named a chat holder, one held the slot 16.3
    minutes across 5 consecutive cycles, and the keeper carrying the most chat
    traffic lost 18.6% of its autonomous cycles.

    The callback runs on the Owner fiber. It must not block, and an exception
    it raises is contained rather than propagated — a lost wake degrades to the
    listener's own cadence. This does not change admission order: the chat lane
    still receives the freed slot first. *)

val projection : t -> Keeper_owner_reducer.projection
(** Lock-free immutable snapshot. *)

val operation_projection : t -> operation_projection
(** Lock-free immutable operation inventory. *)

val wake_operation_drain : t -> (unit, error) result
(** Reconsider existing Queued rows after the operation runner's dependency
    becomes ready. This command never changes sequence or state itself. *)

val turn_in_flight : t -> turn_in_flight option
(** Lock-free immutable projection of the single Owner-owned child turn. *)

val shutdown_operation_id : t -> Keeper_shutdown_types.Operation_id.t option
(** Lock-free immutable projection of the lifecycle shutdown reservation. *)

val autonomous_block_kind : autonomous_block -> string
val autonomous_block_to_string : autonomous_block -> string
val autonomous_block_to_yojson : autonomous_block -> Yojson.Safe.t

val run_autonomous_if_idle
  :  t
  -> (unit -> 'a)
  -> ([ `Ran of 'a | `Busy of autonomous_block ], error) result
(** Mailbox-linearized autonomous admission. The callback runs in the Owner's
    child switch, while the actor remains responsive. An already-started child
    returns [`Busy] without consuming turn input. A Queued chat whose runner is
    not ready does not block autonomous admission. Owner-directed cancellation
    returns [Error Owner_stopping]; its private child-stop signal never escapes
    this boundary. *)

val run_maintenance_if_idle
  :  t
  -> (unit -> 'a)
  -> ([ `Ran of 'a | `Busy of autonomous_block ], error) result
(** Mailbox-linearized exclusive maintenance attempt. *)

val begin_shutdown
  :  t
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> (begin_shutdown_result, error) result

val rollback_shutdown
  :  t
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> (rollback_shutdown_result, error) result

val restore_shutdown
  :  t
  -> operation_id:Keeper_shutdown_types.Operation_id.t
  -> (restore_shutdown_result, error) result

val transition_shutdown
  :  t
  -> from_operation_id:Keeper_shutdown_types.Operation_id.t
  -> to_operation_id:Keeper_shutdown_types.Operation_id.t option
  -> (transition_shutdown_result, error) result

val await_idle_after_shutdown : t -> (unit, error) result
(** Return after the Owner child that preceded the shutdown reservation has
    completed. The actor remains responsive while the caller waits. *)

val exact_projection
  :  t
  -> (Keeper_owner_reducer.projection, error) result
(** Mailbox-linearized projection for mutation and exact-operation paths. *)

val apply_meta
  :  t
  -> Keeper_owner_reducer.meta_command
  -> (Keeper_meta_contract.keeper_meta option, error) result

val exact_operation
  :  t
  -> Chat_operation.Operation_id.t
  -> (Chat_operation.t option, error) result

val submit_operation
  :  t
  -> operation_id:Chat_operation.Operation_id.t
  -> source:Yojson.Safe.t
  -> input:Yojson.Safe.t
  -> (operation_acceptance, error) result

val list_queued_operations
  :  t
  -> after_sequence:int64 option
  -> limit:int
  -> (Chat_operation.t list, error) result

val edit_queued_operation
  :  t
  -> operation_id:Chat_operation.Operation_id.t
  -> input:Yojson.Safe.t
  -> (Chat_operation.t, error) result

val move_queued_operation_to_end
  :  t
  -> Chat_operation.Operation_id.t
  -> (Chat_operation.t, error) result

val cancel_queued_operation
  :  t
  -> Chat_operation.Operation_id.t
  -> (Chat_operation.t, error) result

val claim_next_operation : t -> (Chat_operation.t option, error) result

val succeed_running_operation
  :  t
  -> operation_id:Chat_operation.Operation_id.t
  -> outcome_ref:string
  -> (Chat_operation.t, error) result

val begin_stopping : t -> (unit, error) result
(** Reject new mutation and submit commands, cancel an active child turn, and
    return only after its terminal operation transition has been attempted. *)
(** Reject future external commands. *)

val error_to_string : error -> string
val operation_error_kind : Keeper_chat_operation_store.error -> operation_error_kind

module For_testing : sig
  val mailbox_depth : t -> int
end
