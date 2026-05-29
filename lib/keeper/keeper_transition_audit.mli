(** Keeper Transition Audit — Structured audit trail (RFC-0002).

    Records every decision point for observability and replay.

    All type definitions ([transition_record], [operator_signal],
    [completed_turn_outcome], [completed_turn_record],
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

module For_testing : sig
  val reset_state : unit -> unit
  val clear_completed_turn_ring : keeper_name:string -> unit
  val observe_append_failure : site:string -> exn -> unit
end
