(** Keeper Transition Audit — Structured audit trail (RFC-0002).

    Records every decision point for observability and replay.

    All type definitions ([transition_record], [completed_turn_outcome], [completed_turn_record],
    [turn_fsm_transition_record]) and their pure converters live in
    {!Keeper_transition_audit_types}.  Re-exported here so callers can
    continue using [Keeper_transition_audit.transition_record] etc.
    without reaching into the types submodule. *)

(** {1 SSOT Types} *)
include module type of struct
  include Keeper_transition_audit_types
end

(** {1 In-memory Ring Buffer} *)

(** Record a transition in the per-keeper ring buffer (last 50). *)
val record_transition :
  keeper_name:string -> transition_record -> unit

(** Retrieve recent transitions for a keeper, newest first. *)
val recent_transitions :
  keeper_name:string -> limit:int -> transition_record list

(** JSON array of recent transitions. *)
val recent_transitions_json :
  keeper_name:string -> limit:int -> Yojson.Safe.t

(** Record a completed keeper turn in the per-keeper ring buffer (last 50). *)
val record_completed_turn :
  keeper_name:string -> completed_turn_record -> unit

(** Append a turn FSM transition to the same durable audit sink used by
    lifecycle transitions and completed turns. *)
val record_turn_fsm_transition :
  keeper_name:string -> turn_fsm_transition_record -> unit

(** Retrieve recent completed keeper turns for a keeper, newest first. *)
val recent_completed_turns :
  keeper_name:string -> limit:int -> completed_turn_record list

(** {1 Async Forensics Append}

    The in-memory rings above are the authoritative live trail; the
    dated-JSONL default store is restart forensics. Recorders therefore
    never write the store inline on the keeper fiber once
    [start_flush_fiber] has run — they enqueue, and the flush fiber
    drains every 0.5 s. Before [start_flush_fiber] (tests, non-server
    embedders) recording appends synchronously, preserving the previous
    behavior. *)

(** Start the background drain fiber on [sw] and switch recorders to
    enqueue mode. Registers a shutdown hook that flushes the remaining
    queue. Call once from server bootstrap. *)
val start_flush_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit

(** Drain all queued forensics records to the default store now.
    Returns the number of records written. Store-backed readers call
    this before reading; safe from any fiber. *)
val flush_pending : unit -> int

(** Forensics records queued for the async drain fiber. A rising depth
    means the drain fiber is starved or the store append is parked
    (#20677 failure mode). *)
val queue_depth : unit -> int

module For_testing : sig
  val reset_state : unit -> unit
  val clear_completed_turn_ring : keeper_name:string -> unit
  val observe_append_failure : site:string -> exn -> unit
  val queued_count : unit -> int
  val dropped_count : unit -> int

  (** Toggle enqueue mode without spawning the drain fiber, so tests can
      exercise the queue deterministically. [reset_state] sets it back to
      false (synchronous appends). *)
  val set_async_append_active : bool -> unit
end
