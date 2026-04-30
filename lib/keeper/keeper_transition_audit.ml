(** Keeper Transition Audit — Structured audit trail (RFC-0002). *)

(* tla-lint: file-scope: structured audit trail for FSM transitions.
   The ring buffer (pos/count) and result accumulators here record
   what the FSM did; they do not influence what it does next.
   Mutations are bookkeeping for the JSONL flush layer. *)

type transition_record = {
  snapshot : Keeper_measurement.measurement_snapshot option;
  events_fired : Keeper_state_machine.event list;
  selected_event : Keeper_state_machine.event;
  prev_phase : Keeper_state_machine.phase;
  new_phase : Keeper_state_machine.phase;
  transition_outcome : string;
  wall_clock_at_decision : float;
}

type operator_signal = {
  signal_class : string;
  severity : string;
  requires_operator_decision : bool;
  next_human_action : string option;
  summary : string;
}

let event_type_of_event event =
  match Keeper_state_machine.event_to_json event with
  | `Assoc fields -> (
      match List.assoc_opt "type" fields with
      | Some (`String value) -> value
      | _ -> Keeper_state_machine.event_to_string event)
  | _ -> Keeper_state_machine.event_to_string event

let operator_signal ?next_human_action ~signal_class ~severity
    ~requires_operator_decision summary =
  {
    signal_class;
    severity;
    requires_operator_decision;
    next_human_action;
    summary;
  }

let operator_signal_to_json signal =
  `Assoc
    [
      ("class", `String signal.signal_class);
      ("severity", `String signal.severity);
      ("requires_operator_decision", `Bool signal.requires_operator_decision);
      ("next_human_action", Json_util.string_opt_to_json signal.next_human_action);
      ("summary", `String signal.summary);
    ]

let operator_signal_of_transition (r : transition_record) =
  let open Keeper_state_machine in
  let phase_name = Keeper_state_machine.phase_to_string in
  match r.selected_event with
  | Operator_pause ->
      operator_signal ~signal_class:"operator_gate" ~severity:"warn"
        ~requires_operator_decision:true
        ~next_human_action:"resume_or_update_policy"
        "keeper paused; operator decision is required"
  | Operator_resume ->
      operator_signal ~signal_class:"operator_gate" ~severity:"ok"
        ~requires_operator_decision:false "keeper resumed by operator"
  | Operator_stop _ | Stop_requested ->
      operator_signal ~signal_class:"operator_stop" ~severity:"warn"
        ~requires_operator_decision:false "keeper stop requested"
  | Restart_budget_exhausted ->
      operator_signal ~signal_class:"runtime_alert" ~severity:"bad"
        ~requires_operator_decision:true
        ~next_human_action:"inspect_or_restart_keeper"
        "restart budget exhausted; operator must choose recovery"
  | Guardrail_stop { reason } ->
      operator_signal ~signal_class:"runtime_alert" ~severity:"bad"
        ~requires_operator_decision:true
        ~next_human_action:"inspect_guardrail_and_resume"
        (Printf.sprintf "guardrail stopped keeper: %s" reason)
  | Compact_retry_exhausted ->
      operator_signal ~signal_class:"context_management" ~severity:"bad"
        ~requires_operator_decision:true
        ~next_human_action:"approve_handoff_or_reduce_context"
        "auto-compact retry budget exhausted"
  | Compaction_failed { reason } ->
      operator_signal ~signal_class:"context_management" ~severity:"bad"
        ~requires_operator_decision:true
        ~next_human_action:"retry_compaction_or_handoff"
        (Printf.sprintf "compaction failed: %s" reason)
  | Handoff_failed { reason } ->
      operator_signal ~signal_class:"handoff" ~severity:"bad"
        ~requires_operator_decision:true
        ~next_human_action:"retry_handoff_or_resume"
        (Printf.sprintf "handoff failed: %s" reason)
  | Context_overflow_detected _ ->
      operator_signal ~signal_class:"context_management" ~severity:"warn"
        ~requires_operator_decision:false
        "context overflow detected; recovery path should continue"
  | _ -> (
      match r.new_phase with
      | Paused ->
          operator_signal ~signal_class:"operator_gate" ~severity:"warn"
            ~requires_operator_decision:true
            ~next_human_action:"resume_or_update_policy"
            (Printf.sprintf "%s -> paused; operator decision is required"
               (phase_name r.prev_phase))
      | Crashed ->
          operator_signal ~signal_class:"runtime_alert" ~severity:"bad"
            ~requires_operator_decision:true
            ~next_human_action:"inspect_or_restart_keeper"
            "keeper crashed; operator must inspect recovery"
      | Dead ->
          operator_signal ~signal_class:"runtime_alert" ~severity:"bad"
            ~requires_operator_decision:true
            ~next_human_action:"inspect_or_recreate_keeper"
            "keeper reached dead phase"
      | Zombie ->
          operator_signal ~signal_class:"runtime_alert" ~severity:"bad"
            ~requires_operator_decision:true
            ~next_human_action:"inspect_or_recreate_keeper"
            "keeper reached zombie phase (terminal structural failure)"
      | Failing ->
          operator_signal ~signal_class:"runtime_recovery" ~severity:"warn"
            ~requires_operator_decision:false
            "keeper entered failing recovery lane"
      | Overflowed ->
          operator_signal ~signal_class:"context_management" ~severity:"warn"
            ~requires_operator_decision:false
            "keeper overflowed context and should compact or hand off"
      | Compacting ->
          operator_signal ~signal_class:"context_management" ~severity:"warn"
            ~requires_operator_decision:false "keeper is compacting context"
      | HandingOff ->
          operator_signal ~signal_class:"handoff" ~severity:"warn"
            ~requires_operator_decision:false "keeper handoff is in progress"
      | Draining ->
          operator_signal ~signal_class:"operator_stop" ~severity:"warn"
            ~requires_operator_decision:false "keeper is draining toward stop"
      | Restarting ->
          operator_signal ~signal_class:"runtime_recovery" ~severity:"warn"
            ~requires_operator_decision:false "keeper restart is scheduled"
      | Running when r.prev_phase <> Running ->
          operator_signal ~signal_class:"healthy" ~severity:"ok"
            ~requires_operator_decision:false "keeper recovered to running"
      | Offline | Running | Stopped ->
          operator_signal ~signal_class:"healthy" ~severity:"ok"
            ~requires_operator_decision:false "phase transition observed")

let to_json (r : transition_record) : Yojson.Safe.t =
  let event_type = event_type_of_event r.selected_event in
  let operator_signal = operator_signal_of_transition r in
  `Assoc [
    "snapshot", (match r.snapshot with
      | Some s -> Keeper_measurement.measurement_snapshot_to_json s
      | None -> `Null);
    "events_fired",
      `List (List.map Keeper_state_machine.event_to_json r.events_fired);
    "selected_event", Keeper_state_machine.event_to_json r.selected_event;
    "event_type", `String event_type;
    "prev_phase", Keeper_state_machine.phase_to_json r.prev_phase;
    "new_phase", Keeper_state_machine.phase_to_json r.new_phase;
    "transition_outcome", `String r.transition_outcome;
    "operator_signal", operator_signal_to_json operator_signal;
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

let completed_turn_outcome_of_json = function
  | `String "substantive" -> Some Turn_substantive
  | `String "failed" -> Some Turn_failed
  | `String "gate_rejected" -> Some Turn_gate_rejected
  | _ -> None

let completed_turn_to_json (r : completed_turn_record) : Yojson.Safe.t =
  `Assoc
    [
      "turn_id", `Int r.turn_id;
      "started_at", `Float r.started_at;
      "ended_at", `Float r.ended_at;
      "outcome", completed_turn_outcome_to_json r.outcome;
    ]

let completed_turn_of_json = function
  | `Assoc fields -> (
      match
        List.assoc_opt "turn_id" fields,
        List.assoc_opt "started_at" fields,
        List.assoc_opt "ended_at" fields,
        List.assoc_opt "outcome" fields
      with
      | Some (`Int turn_id), Some (`Float started_at), Some (`Float ended_at),
        Some outcome_json -> (
          match completed_turn_outcome_of_json outcome_json with
          | Some outcome -> Some { turn_id; started_at; ended_at; outcome }
          | None -> None)
      | Some (`Int turn_id), Some (`Int started_at), Some (`Int ended_at),
        Some outcome_json -> (
          match completed_turn_outcome_of_json outcome_json with
          | Some outcome ->
              Some
                {
                  turn_id;
                  started_at = float_of_int started_at;
                  ended_at = float_of_int ended_at;
                  outcome;
                }
          | None -> None)
      | _ -> None)
  | _ -> None

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
      (try
         let dir =
           Filename.concat
             (Common.masc_dir_from_base_path
                ~base_path:(Env_config_core.base_path ()))
             "transition-audit"
         in
         let store = Dated_jsonl.create ~base_dir:dir () in
         default_store_ref := Some store;
         Some store
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
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

let append_completed_turn_to_default_store ~keeper_name
    (rec_ : completed_turn_record) =
  match get_default_store () with
  | None -> ()
  | Some store ->
      let json =
        `Assoc
          [
            "keeper", `String keeper_name;
            "completed_turn", completed_turn_to_json rec_;
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
  | None -> append_completed_turn_to_default_store ~keeper_name rec_
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

let recent_completed_turns_from_store ~keeper_name ~limit =
  match sink_path (), get_default_store () with
  | Some _, _ | _, None -> []
  | None, Some store ->
      Dated_jsonl.read_recent store (max limit 1 * 8)
      |> List.filter_map (function
           | `Assoc fields -> (
               match
                 List.assoc_opt "keeper" fields,
                 List.assoc_opt "completed_turn" fields
               with
               | Some (`String name), Some record
                 when String.equal name keeper_name ->
                   completed_turn_of_json record
               | _ -> None)
           | _ -> None)
      |> List.rev
      |> List.filteri (fun idx _ -> idx < limit)

let recent_completed_turns ~keeper_name ~limit : completed_turn_record list =
  match Hashtbl.find_opt completed_turn_rings keeper_name with
  | None -> recent_completed_turns_from_store ~keeper_name ~limit
  | Some ring ->
      let n = min limit (min ring.count ring_capacity) in
      let result = ref [] in
      for i = 0 to n - 1 do
        let idx = (ring.pos - 1 - i + ring_capacity) mod ring_capacity in
        match ring.buf.(idx) with
        | Some r -> result := !result @ [ r ]
        | None -> ()
      done;
      match !result with
      | [] -> recent_completed_turns_from_store ~keeper_name ~limit
      | turns -> turns

module For_testing = struct
  let reset_state () =
    Hashtbl.clear rings;
    Hashtbl.clear completed_turn_rings;
    default_store_ref := None

  let clear_completed_turn_ring ~keeper_name =
    Hashtbl.remove completed_turn_rings keeper_name
end
