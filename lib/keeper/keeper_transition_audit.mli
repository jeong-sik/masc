(** Keeper Transition Audit — Structured audit trail (RFC-0002).

    Records every decision point for observability and replay. *)

(** A single transition decision record. *)
type transition_record = {
  snapshot : Keeper_measurement.measurement_snapshot;
  events_fired : Keeper_state_machine.event list;
  selected_event : Keeper_state_machine.event;
  prev_phase : Keeper_state_machine.phase;
  new_phase : Keeper_state_machine.phase;
  transition_outcome : string;
  wall_clock_at_decision : float;
}

(** Serialize a transition record for JSONL storage. *)
val to_json : transition_record -> Yojson.Safe.t

(** Given a historical snapshot, re-run [Keeper_guard.evaluate] (when available)
    and verify the result matches the recorded events.
    Phase 1: always returns [true] (stub). *)
val replay_check :
  Keeper_measurement.measurement_snapshot ->
  Keeper_state_machine.event list ->
  bool
