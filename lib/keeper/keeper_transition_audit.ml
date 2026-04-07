(** Keeper Transition Audit — Structured audit trail (RFC-0002). *)

type transition_record = {
  snapshot : Keeper_measurement.measurement_snapshot option;
  events_fired : Keeper_state_machine.event list;
  selected_event : Keeper_state_machine.event;
  prev_phase : Keeper_state_machine.phase;
  new_phase : Keeper_state_machine.phase;
  transition_outcome : string;
  wall_clock_at_decision : float;
}

let to_json (r : transition_record) : Yojson.Safe.t =
  `Assoc [
    "snapshot", (match r.snapshot with
      | Some s -> Keeper_measurement.measurement_snapshot_to_json s
      | None -> `Null);
    "events_fired",
      `List (List.map Keeper_state_machine.event_to_json r.events_fired);
    "selected_event", Keeper_state_machine.event_to_json r.selected_event;
    "prev_phase", Keeper_state_machine.phase_to_json r.prev_phase;
    "new_phase", Keeper_state_machine.phase_to_json r.new_phase;
    "transition_outcome", `String r.transition_outcome;
    "wall_clock_at_decision", `Float r.wall_clock_at_decision;
  ]



(* ================================================================ *)
(* In-memory ring buffer for recent transitions                     *)
(* ================================================================ *)

(** Per-keeper ring buffer: stores the last N transition records.
    Thread-safe via non-yielding StringMap + Array mutation in single-domain Eio. *)

type ring = {
  buf : transition_record option array;
  mutable pos : int;
  mutable count : int;
}

let ring_capacity = 50

let rings : (string, ring) Hashtbl.t = Hashtbl.create 16

let get_or_create_ring name =
  match Hashtbl.find_opt rings name with
  | Some r -> r
  | None ->
    let r = { buf = Array.make ring_capacity None; pos = 0; count = 0 } in
    Hashtbl.replace rings name r;
    r

let record_transition ~keeper_name (rec_ : transition_record) =
  let ring = get_or_create_ring keeper_name in
  ring.buf.(ring.pos) <- Some rec_;
  ring.pos <- (ring.pos + 1) mod ring_capacity;
  ring.count <- ring.count + 1

let recent_transitions ~keeper_name ~limit : transition_record list =
  match Hashtbl.find_opt rings keeper_name with
  | None -> []
  | Some ring ->
    let n = min limit (min ring.count ring_capacity) in
    let result = ref [] in
    for i = 0 to n - 1 do
      let idx = (ring.pos - 1 - i + ring_capacity) mod ring_capacity in
      match ring.buf.(idx) with
      | Some r -> result := r :: !result
      | None -> ()
    done;
    !result

let recent_transitions_json ~keeper_name ~limit : Yojson.Safe.t =
  `List (List.map to_json (recent_transitions ~keeper_name ~limit))
