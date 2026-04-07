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
