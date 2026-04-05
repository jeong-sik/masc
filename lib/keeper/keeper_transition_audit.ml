(** Keeper Transition Audit — Structured audit trail (RFC-0002). *)

type transition_record = {
  snapshot : Keeper_measurement.measurement_snapshot;
  events_fired : Keeper_state_machine.event list;
  selected_event : Keeper_state_machine.event;
  prev_phase : Keeper_state_machine.phase;
  new_phase : Keeper_state_machine.phase;
  transition_outcome : string;
  wall_clock_at_decision : float;
}

let to_json (r : transition_record) : Yojson.Safe.t =
  `Assoc [
    "snapshot", Keeper_measurement.measurement_snapshot_to_json r.snapshot;
    "events_fired",
      `List (List.map Keeper_state_machine.event_to_json r.events_fired);
    "selected_event", Keeper_state_machine.event_to_json r.selected_event;
    "prev_phase", Keeper_state_machine.phase_to_json r.prev_phase;
    "new_phase", Keeper_state_machine.phase_to_json r.new_phase;
    "transition_outcome", `String r.transition_outcome;
    "wall_clock_at_decision", `Float r.wall_clock_at_decision;
  ]

(* Phase 1 stub: Keeper_guard not yet wired as consumer.
   Phase 4 will implement actual replay by calling Keeper_guard.evaluate. *)
let replay_check _snapshot _expected_events = true
