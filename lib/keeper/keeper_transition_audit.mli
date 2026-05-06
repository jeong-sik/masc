(** Keeper Transition Audit — Structured audit trail (RFC-0002).

    Records every decision point for observability and replay. *)

(** A single transition decision record. *)
type transition_record = {
  snapshot : Keeper_measurement.measurement_snapshot option;
  events_fired : Keeper_state_machine.event list;
  selected_event : Keeper_state_machine.event;
  prev_phase : Keeper_state_machine.phase;
  new_phase : Keeper_state_machine.phase;
  transition_outcome : string;
  wall_clock_at_decision : float;
}

(** Serialize a transition record for JSONL storage. *)
val to_json : transition_record -> Yojson.Safe.t

(** Historical keeper-turn outcome buckets for dashboard outcomes rollups.
    This stays separate from [transition_record] because a keeper turn can be
    [Turn_succeeded] at the state-machine layer while still ending in a
    [gate_rejected] decision_stage at the turn observer layer. *)
type completed_turn_outcome =
  | Turn_substantive
  | Turn_failed
  | Turn_gate_rejected

type completed_turn_record = {
  turn_id : int;
  started_at : float;
  ended_at : float;
  outcome : completed_turn_outcome;
}

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

(** Retrieve recent completed keeper turns for a keeper, newest first. *)
val recent_completed_turns :
  keeper_name:string -> limit:int -> completed_turn_record list

module For_testing : sig
  val reset_state : unit -> unit
  val clear_completed_turn_ring : keeper_name:string -> unit
  val observe_append_failure : site:string -> exn -> unit
end
