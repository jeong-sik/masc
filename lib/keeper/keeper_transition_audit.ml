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

let completed_turn_outcome_to_json = function
  | Turn_substantive -> `String "substantive"
  | Turn_failed -> `String "failed"
  | Turn_gate_rejected -> `String "gate_rejected"

let completed_turn_to_json (r : completed_turn_record) : Yojson.Safe.t =
  `Assoc
    [
      "turn_id", `Int r.turn_id;
      "started_at", `Float r.started_at;
      "ended_at", `Float r.ended_at;
      "outcome", completed_turn_outcome_to_json r.outcome;
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

type completed_turn_ring = {
  buf : completed_turn_record option array;
  mutable pos : int;
  mutable count : int;
}

let completed_turn_rings : (string, completed_turn_ring) Hashtbl.t =
  Hashtbl.create 16

let get_or_create_ring name =
  match Hashtbl.find_opt rings name with
  | Some r -> r
  | None ->
    let r : ring =
      { buf = Array.make ring_capacity None; pos = 0; count = 0 }
    in
    Hashtbl.replace rings name r;
    r

let get_or_create_completed_turn_ring name =
  match Hashtbl.find_opt completed_turn_rings name with
  | Some r -> r
  | None ->
    let r : completed_turn_ring =
      { buf = Array.make ring_capacity None; pos = 0; count = 0 }
    in
    Hashtbl.replace completed_turn_rings name r;
    r

(* ================================================================ *)
(* Optional file sink — best-effort jsonl append                    *)
(* ================================================================ *)

(** Path of the persistent transition log, configured via the
    [MASC_KEEPER_TRANSITION_LOG] env var. When unset the sink is disabled
    and only the in-memory ring is updated. Reading the env on each call
    keeps the surface tiny — one keeper transition per second is the
    upper bound, so the cost is negligible. *)
let sink_path () = Sys.getenv_opt "MASC_KEEPER_TRANSITION_LOG"

let default_store_ref : Dated_jsonl.t option ref = ref None

let get_default_store () =
  match !default_store_ref with
  | Some store -> Some store
  | None ->
      let dir =
        Filename.concat (Env_config_core.base_path ()) ".masc/transition-audit"
      in
      (match Dated_jsonl.create ~base_dir:dir () with
       | store ->
           default_store_ref := Some store;
           Some store
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception exn ->
           Log.Keeper.warn "transition_audit default store failed: %s"
             (Printexc.to_string exn);
           None)

(** Append a single jsonl line for the given transition. Wraps the record
    json with the keeper name so a single sink file can mux multiple
    keepers. Any IO error is swallowed: the in-memory ring is the
    authoritative trail for live dashboards, the sink is for restart
    forensics only. *)
let append_to_sink ~keeper_name (rec_ : transition_record) =
  match sink_path () with
  | None -> ()
  | Some path ->
    Safe_ops.protect ~default:() (fun () ->
       let line =
         Yojson.Safe.to_string
           (`Assoc [
              "keeper", `String keeper_name;
              "record", to_json rec_;
            ])
       in
       let oc =
         open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path
       in
       Fun.protect
         ~finally:(fun () ->
           close_out_noerr oc)
         (fun () -> output_string oc (line ^ "\n")))

let append_to_default_store ~keeper_name (rec_ : transition_record) =
  match get_default_store () with
  | None -> ()
  | Some store ->
      let json =
        `Assoc
          [
            "keeper", `String keeper_name;
            "record", to_json rec_;
          ]
      in
      Safe_ops.protect ~default:() (fun () ->
          Dated_jsonl.append store json)

let record_transition ~keeper_name (rec_ : transition_record) =
  let ring = get_or_create_ring keeper_name in
  ring.buf.(ring.pos) <- Some rec_;
  ring.pos <- (ring.pos + 1) mod ring_capacity;
  ring.count <- ring.count + 1;
  (match sink_path () with
   | Some _ -> append_to_sink ~keeper_name rec_
   | None -> append_to_default_store ~keeper_name rec_)

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
  let recent = recent_transitions ~keeper_name ~limit in
  if recent <> [] then
    `List (List.map to_json recent)
  else
    match sink_path (), get_default_store () with
    | Some _, _ | _, None -> `List []
    | None, Some store ->
        let items =
          Dated_jsonl.read_recent store (max limit 1 * 8)
          |> List.filter_map (function
               | `Assoc fields -> (
                   match List.assoc_opt "keeper" fields, List.assoc_opt "record" fields with
                   | Some (`String name), Some record
                     when String.equal name keeper_name -> Some record
                   | _ -> None)
               | _ -> None)
          |> List.filteri (fun idx _ -> idx < limit)
        in
        `List items

let record_completed_turn ~keeper_name (rec_ : completed_turn_record) =
  let ring = get_or_create_completed_turn_ring keeper_name in
  ring.buf.(ring.pos) <- Some rec_;
  ring.pos <- (ring.pos + 1) mod ring_capacity;
  ring.count <- ring.count + 1;
  match sink_path () with
  | None -> ()
  | Some path ->
      Safe_ops.protect ~default:() (fun () ->
          let line =
            Yojson.Safe.to_string
              (`Assoc
                [
                  "keeper", `String keeper_name;
                  "completed_turn", completed_turn_to_json rec_;
                ])
          in
          let oc =
            open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path
          in
          Fun.protect
            ~finally:(fun () ->
              close_out_noerr oc)
            (fun () -> output_string oc (line ^ "\n")))

let recent_completed_turns ~keeper_name ~limit : completed_turn_record list =
  match Hashtbl.find_opt completed_turn_rings keeper_name with
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
