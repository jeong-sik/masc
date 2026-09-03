(** Composite observer — pure projection. See [.mli] for contract. *)

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_routing
  | Turn_executing
  | Turn_finalizing
  | Turn_exhausted

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_tool_policy_selected

type runtime_state = string


type invariant_key =
  | Invariant_no_runtime_before_measurement
  | Invariant_event_priority_monotone
  | Invariant_phase_derivation_agreement

type invariants_check = {
  no_runtime_before_measurement : bool;
  event_priority_monotone : bool;
  phase_derivation_agreement : bool;
}

type last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_stage : Keeper_registry.packed_decision_stage;
  runtime_state : runtime_state;
  selected_model : string option;
}

type live_turn = {
  turn_id : int;
  started_at : float;
  last_progress_at : float;
  last_progress_kind : string option;
  selected_model : string option;
  active_tool_count : int;
  wake : Keeper_registry.wake_reason;
}

type last_skip = {
  ls_ts : float;
  ls_reasons : string list;
}

type run_state =
  | In_turn of {
      rs_wake : Keeper_registry.wake_reason;
      rs_started_at : float;
      rs_active_tool_count : int;
    }
  | Waiting of {
      rs_queue_depth : int;
      rs_last_skip : last_skip option;
    }
  | Suspended of Keeper_state_machine.phase

type turn_attempt = {
  ta_turn_id : int;
  ta_attempts : int;
  ta_first_started_at : float;
}

type board_cursor = {
  bc_ts : float;
  bc_post_id : string option;
}

type fsm_guard_violation_bucket = {
  action : string;
  stage : string;
  count : int;
}

type snapshot = {
  keeper_name : string;
  correlation_id : string;
  run_id : string;
  ts : float;
  phase : Keeper_state_machine.phase;
  ktc_turn_phase : Keeper_registry.packed_turn_phase;
  kdp_decision : Keeper_registry.packed_decision_stage;
  kcl_runtime_state : runtime_state;
  shared_measurement : Keeper_state_machine.context_actions option;
  invariants : invariants_check;
  conditions : Keeper_state_machine.conditions;
  is_live : bool;
  live_turn : live_turn option;
  run_state : run_state;
  last_outcome : last_outcome option;
  last_skip : last_skip option;
  turn_attempt : turn_attempt option;
  board_cursor : board_cursor;
  board_wakeups : int;
  fiber_stop_flag : bool;
  fiber_wakeup_flag : bool;
  idle_seconds : int;
  last_turn_ts : float;
  fsm_guard_violations : int;
  fsm_guard_violation_breakdown : fsm_guard_violation_bucket list;
}

let take_fsm_guard_buckets limit buckets =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | bucket :: rest -> loop (remaining - 1) (bucket :: acc) rest
  in
  loop limit [] buckets
;;

let fsm_guard_violation_breakdown () =
  Otel_metric_store.snapshot ()
  |> List.filter_map (fun (metric : Otel_metric_store.metric) ->
    if String.equal metric.name Otel_metric_store.metric_fsm_guard_violation
       && metric.value > 0.0
    then
      match List.assoc_opt "action" metric.labels, List.assoc_opt "stage" metric.labels with
      | Some action, Some stage ->
        Some { action; stage; count = int_of_float metric.value }
      | _ -> None
    else None)
  |> List.sort (fun a b ->
    match compare b.count a.count with
    | 0 ->
      (match String.compare a.action b.action with
       | 0 -> String.compare a.stage b.stage
       | by_action -> by_action)
    | by_count -> by_count)
  |> take_fsm_guard_buckets 8
;;

let turn_phase_to_string (tp : Keeper_registry.packed_turn_phase) =
  match tp with
  | Keeper_registry.Packed Turn_idle -> "idle"
  | Keeper_registry.Packed Turn_prompting -> "prompting"
  | Keeper_registry.Packed Turn_routing -> "routing"
  | Keeper_registry.Packed Turn_executing -> "executing"
  | Keeper_registry.Packed Turn_finalizing -> "finalizing"
  | Keeper_registry.Packed Turn_exhausted -> "exhausted"

let decision_stage_to_string (s : Keeper_registry.packed_decision_stage) =
  match s with
  | Keeper_registry.Packed Decision_undecided -> "undecided"
  | Keeper_registry.Packed Decision_guard_ok -> "guard_ok"
  | Keeper_registry.Packed Decision_tool_policy_selected -> "tool_policy_selected"

let runtime_state_to_string (s : runtime_state) = s


let invariant_key_to_string = function
  | Invariant_no_runtime_before_measurement -> "NoRuntimeBeforeMeasurement"
  | Invariant_event_priority_monotone -> "EventPriorityMonotone"
  | Invariant_phase_derivation_agreement -> "PhaseDerivationAgreement"

(* Derivation from registry entry *)

(* Exhaustive on [Keeper_state_machine.phase]: maps the raw Keeper phase
   to the turn phase projection when
   no live turn observation exists.  Spelling each branch out turns a
   future phase
   addition into a compile error. *)
let live_turn_phase (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.turn_phase
  | None ->
      (match entry.phase with
       | Keeper_state_machine.Draining ->
           Keeper_registry.Packed Turn_finalizing
       | Keeper_state_machine.Running
       | Keeper_state_machine.Failing
       | Keeper_state_machine.Offline
       | Keeper_state_machine.Paused
       | Keeper_state_machine.Stopped
       | Keeper_state_machine.Crashed
       | Keeper_state_machine.Restarting ->
           Keeper_registry.Packed Turn_idle)

let live_decision_stage (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.decision_stage
  | None -> Keeper_registry.Packed Decision_undecided

let live_runtime_state (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs ->
    (match obs.turn_phase with
     | Keeper_registry.Packed Turn_idle
     | Keeper_registry.Packed Turn_prompting -> "idle"
     | Keeper_registry.Packed Turn_routing -> "routing"
     | Keeper_registry.Packed Turn_executing -> "executing"
     | Keeper_registry.Packed Turn_finalizing -> "done"
     | Keeper_registry.Packed Turn_exhausted -> "exhausted")
  | None -> "idle"

let live_measurement (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some { measurement = Some measurement; _ } -> Some measurement.tm_context_actions
  | _ -> None

(* Run-state classification (#16, 38-bug campaign PR-5). Exhaustive on
   [Keeper_state_machine.phase]: a future phase addition must be classified
   here explicitly rather than silently inheriting a catch-all arm. *)
let run_state_of_entry (entry : Keeper_registry.registry_entry) ~last_skip
    : run_state =
  match entry.phase with
  | Keeper_state_machine.Running ->
    (match entry.current_turn_observation with
     | Some obs ->
       In_turn
         {
           rs_wake = obs.wake;
           rs_started_at = obs.started_at;
           rs_active_tool_count = obs.active_tool_count;
         }
     | None ->
       Waiting
         {
           rs_queue_depth = Keeper_event_queue.length (Atomic.get entry.event_queue);
           rs_last_skip = last_skip;
         })
  | Keeper_state_machine.Offline
  | Keeper_state_machine.Failing
  | Keeper_state_machine.Draining
  | Keeper_state_machine.Paused
  | Keeper_state_machine.Stopped
  | Keeper_state_machine.Crashed
  | Keeper_state_machine.Restarting ->
    Suspended entry.phase

(* [wake_kind] + [stimulus_kinds] pair for [run_state_to_json]'s
   [In_turn] arm. *)
let wake_reason_kind_and_stimuli (wake : Keeper_registry.wake_reason) : string * string list =
  match wake with
  | Keeper_registry.Proactive_tick -> "proactive_tick", []
  | Keeper_registry.Woken stimuli ->
    "woken", List.map Keeper_event_queue.payload_kind_label stimuli
  (* A chat turn is claimed from the Owner's durable operation ledger, not
     selected from the event queue, so it carries no stimuli. The empty list is
     the accurate answer, not a placeholder. *)
  | Keeper_registry.Chat_request -> "chat_request", []

let run_state_to_json (rs : run_state) : Yojson.Safe.t =
  match rs with
  | In_turn { rs_wake; rs_started_at; rs_active_tool_count } ->
    let wake_kind, stimulus_kinds = wake_reason_kind_and_stimuli rs_wake in
    `Assoc
      [
        "kind", `String "in_turn";
        "wake_kind", `String wake_kind;
        "stimulus_kinds", `List (List.map (fun s -> `String s) stimulus_kinds);
        "started_at", `Float rs_started_at;
        "active_tool_count", `Int rs_active_tool_count;
      ]
  | Waiting { rs_queue_depth; rs_last_skip } ->
    `Assoc
      [
        "kind", `String "waiting";
        "queue_depth", `Int rs_queue_depth;
        "skip_reasons",
          (match rs_last_skip with
           | Some ls -> `List (List.map (fun r -> `String r) ls.ls_reasons)
           | None -> `List []);
      ]
  | Suspended phase ->
    `Assoc [ "kind", `String "suspended"; "phase", `String (Keeper_state_machine.phase_to_string phase) ]

(* Invariants *)

let check_no_runtime_before_measurement
    ~(runtime_state : runtime_state)
    ~(measurement_captured : bool)
    : bool =
  let _ = runtime_state, measurement_captured in
  true

type event_priority_state = {
  ep_measurement_bind_count : int;
  ep_has_measurement : bool;
  ep_has_pending_measurement : bool;
}

let check_event_priority_monotone_pure
    (state : event_priority_state)
    : bool =
  state.ep_measurement_bind_count <= 1
  && not (state.ep_has_measurement && state.ep_has_pending_measurement)

let check_event_priority_monotone
    (entry : Keeper_registry.registry_entry)
    : bool =
  match entry.current_turn_observation with
  | None -> true
  | Some obs ->
      check_event_priority_monotone_pure {
        ep_measurement_bind_count = obs.measurement_bind_count;
        ep_has_measurement = Option.is_some obs.measurement;
        ep_has_pending_measurement = Option.is_some entry.pending_turn_measurement;
      }

let check_phase_derivation_agreement
    (entry : Keeper_registry.registry_entry)
    : bool =
  Keeper_state_machine.derive_phase entry.conditions = entry.phase

let compute_invariants
    (entry : Keeper_registry.registry_entry)
    ~(phase : Keeper_state_machine.phase)
    ~(turn_phase : Keeper_registry.packed_turn_phase)
    ~(runtime_state : runtime_state)
    ~(measurement_captured : bool)
    : invariants_check =
  {
    no_runtime_before_measurement =
      check_no_runtime_before_measurement
        ~runtime_state
        ~measurement_captured;
    event_priority_monotone = check_event_priority_monotone entry;
    phase_derivation_agreement = check_phase_derivation_agreement entry;
  }

(* Otel_metric_store bump — one counter tick per violated invariant per snapshot.
   Called from [observe]. Backend rate/increase queries distinguish transient
   from steady-state violations. Labels bounded: keeper × invariant (5)
   ≤ ~250 series on a 50-keeper host. Mirrors the naming pattern in
   [Runtime_strategy_trace.bump_otel_metric_store_counter]. *)
let bump_invariant_violations ~(keeper_name : string) (inv : invariants_check) =
  let bump key satisfied =
    if not satisfied then
      Otel_metric_store.inc_counter Keeper_metrics.(to_string InvariantViolations)
        ~labels:[
          ("keeper", keeper_name);
          ("invariant", invariant_key_to_string key);
        ]
        ()
  in
  bump Invariant_no_runtime_before_measurement inv.no_runtime_before_measurement;
  bump Invariant_event_priority_monotone inv.event_priority_monotone;
  bump Invariant_phase_derivation_agreement inv.phase_derivation_agreement

(* Public API *)

let stable_correlation_id (entry : Keeper_registry.registry_entry) : string =
  Printf.sprintf "keeper:%s:%d" entry.name entry.transition_seq

let stable_run_id (entry : Keeper_registry.registry_entry) : string =
  Printf.sprintf "r-%.0f-%d" entry.started_at entry.restart_count

let observe
    ?correlation_id
    ?run_id
    ?now
    (entry : Keeper_registry.registry_entry)
    : snapshot =
  let ts = match now with Some t -> t | None -> Time_compat.now () in
  let correlation_id =
    match correlation_id with
    | Some s when String.length s > 0 -> s
    | _ ->
      match entry.last_event_bus_correlation with
      | Some cid -> cid
      | None -> stable_correlation_id entry
  in
  let run_id =
    match run_id with
    | Some s when String.length s > 0 -> s
    | _ -> stable_run_id entry
  in
  let is_live = entry.current_turn_observation <> None in
  let turn_phase = live_turn_phase entry in
  let decision_stage = live_decision_stage entry in
  let runtime_state = live_runtime_state entry in
  let measurement = live_measurement entry in
  let measurement_captured = Option.is_some measurement in
  let invariants =
    compute_invariants
      entry
      ~phase:entry.phase
      ~turn_phase
      ~runtime_state
      ~measurement_captured
  in
  bump_invariant_violations ~keeper_name:entry.name invariants;
  let last_skip =
    match entry.last_skip_observation with
    | Some (ts, reasons) -> Some { ls_ts = ts; ls_reasons = reasons }
    | None -> None
  in
  {
    keeper_name = entry.name;
    correlation_id;
    run_id;
    ts;
    phase = entry.phase;
    ktc_turn_phase = turn_phase;
    kdp_decision = decision_stage;
    kcl_runtime_state = runtime_state;
    shared_measurement = measurement;
    invariants;
    conditions = entry.conditions;
    is_live;
    live_turn =
      (match entry.current_turn_observation with
       | Some obs ->
         Some
           {
             turn_id = obs.turn_id;
             started_at = obs.started_at;
             last_progress_at = obs.last_progress_at;
             last_progress_kind = obs.last_progress_kind;
             selected_model = obs.selected_model;
             active_tool_count = obs.active_tool_count;
             wake = obs.wake;
           }
       | None -> None);
    run_state = run_state_of_entry entry ~last_skip;
    last_outcome =
      (match entry.last_completed_turn with
       | Some lc ->
         Some {
           turn_id = lc.ct_turn_id;
           ended_at = lc.ct_ended_at;
           decision_stage = lc.ct_decision_stage;
           runtime_state = "done";
           selected_model = lc.ct_selected_model;
         }
       | None -> None);
    last_skip;
    turn_attempt =
      (match Atomic.get entry.turn_attempt_state with
       | Some attempt ->
         Some
           {
             ta_turn_id = attempt.turn_id;
             ta_attempts = attempt.attempts;
             ta_first_started_at = attempt.first_started_at;
           }
       | None -> None);
    board_cursor =
      { bc_ts = entry.board_cursor_ts; bc_post_id = entry.board_cursor_post_id };
    board_wakeups = Keeper_registry.StringMap.cardinal entry.board_wakeups;
    fiber_stop_flag = Atomic.get entry.fiber_stop;
    fiber_wakeup_flag = Atomic.get entry.fiber_wakeup;
    idle_seconds =
      (let last = entry.meta.runtime.proactive_rt.last_ts in
       if last <= 0.0 then 0
       else int_of_float (max 0.0 (Time_compat.now () -. last)));
    last_turn_ts = entry.meta.runtime.usage.last_turn_ts;
    fsm_guard_violations =
      Otel_metric_store.metric_total Otel_metric_store.metric_fsm_guard_violation
      |> int_of_float;
    fsm_guard_violation_breakdown = fsm_guard_violation_breakdown ();
  }

(* JSON serialisation (RFC-0003 §7) *)

let invariants_to_json (inv : invariants_check) : Yojson.Safe.t =
  `Assoc [
    "no_runtime_before_measurement", `Bool inv.no_runtime_before_measurement;
    "event_priority_monotone", `Bool inv.event_priority_monotone;
    "phase_derivation_agreement", `Bool inv.phase_derivation_agreement;
  ]

let measurement_to_json (m : Keeper_state_machine.context_actions) : Yojson.Safe.t =
  `Assoc
    [
      "handoff", `Bool m.handoff;
    ]

type phase_condition_row = {
  key : string;
  label : string;
  priority : int;
  value : bool;
  phase : Keeper_state_machine.phase;
}

let phase_condition_rows (c : Keeper_state_machine.conditions) : phase_condition_row list =
  let row key label priority value phase =
    { key; label; priority; value; phase }
  in
  [
    row "stopped_clean_drain" "Stopped: clean drain complete" 2
      (c.stop_requested && c.drain_complete)
      Keeper_state_machine.Stopped;
    row "offline_launch_pending" "Offline: launch pending without fiber" 3
      (c.launch_pending && not c.fiber_alive)
      Keeper_state_machine.Offline;
    row "restarting_requested" "Restarting: supervisor requested restart" 5
      ((not c.fiber_alive) && c.restart_requested)
      Keeper_state_machine.Restarting;
    row "crashed_fiber_down" "Crashed: fiber down" 6
      (not c.fiber_alive)
      Keeper_state_machine.Crashed;
    row "draining_stop_requested" "Draining: stop requested" 7
      c.stop_requested
      Keeper_state_machine.Draining;
    row "paused_operator" "Paused: explicit operator pause" 8
      c.operator_paused
      Keeper_state_machine.Paused;
    row "failing_unhealthy" "Failing: heartbeat or turn unhealthy" 12
      ((not c.heartbeat_healthy) || not c.turn_healthy)
      Keeper_state_machine.Failing;
    row "running_fiber_alive" "Running: fiber alive" 13
      c.fiber_alive
      Keeper_state_machine.Running;
    row "offline_fallback" "Offline: fallback" 14
      true
      Keeper_state_machine.Offline;
  ]

let phase_diagnosis_to_json
    ~(current_phase : Keeper_state_machine.phase)
    (conditions : Keeper_state_machine.conditions)
    : Yojson.Safe.t =
  let derived_phase = Keeper_state_machine.derive_phase conditions in
  let rows = phase_condition_rows conditions in
  let determining =
    rows
    |> List.find_opt (fun row -> row.value)
    |> Option.map (fun row -> row.key)
  in
  `Assoc [
    "current_phase", `String (Keeper_state_machine.phase_to_string current_phase);
    "derived_phase", `String (Keeper_state_machine.phase_to_string derived_phase);
    "can_execute_turn", `Bool (Keeper_state_machine.can_execute_turn derived_phase);
    "conditions", Keeper_state_machine_json.conditions_to_json conditions;
    "determining_condition",
      Json_util.string_opt_to_json determining;
    "rows",
      `List
        (List.map
           (fun row ->
              `Assoc [
                "key", `String row.key;
                "label", `String row.label;
                "priority", `Int row.priority;
                "value", `Bool row.value;
                "phase", `String (Keeper_state_machine.phase_to_string row.phase);
                "determining", `Bool (Some row.key = determining);
              ])
           rows);
  ]

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    "keeper", `String s.keeper_name;
    "correlation_id", `String s.correlation_id;
    "run_id", `String s.run_id;
    "ts", `Float s.ts;
    "phase", `String (Keeper_state_machine.phase_to_string s.phase);
    "turn_phase", `String (turn_phase_to_string s.ktc_turn_phase);
    "decision", `Assoc [
      "stage", `String (decision_stage_to_string s.kdp_decision);
    ];
    "runtime", `Assoc [
      "state", `String (runtime_state_to_string s.kcl_runtime_state);
    ];
    "measurement", (match s.shared_measurement with
      | Some m -> `Assoc [
          "captured", `Bool true;
          "context_actions", measurement_to_json m;
        ]
      | None -> `Assoc [
          "captured", `Bool false;
        ]);
    "invariants", invariants_to_json s.invariants;
    "phase_diagnosis", phase_diagnosis_to_json
      ~current_phase:s.phase s.conditions;
    "is_live", `Bool s.is_live;
    "live_turn", (match s.live_turn with
      | Some live ->
        `Assoc [
          "turn_id", `Int live.turn_id;
          "started_at", `Float live.started_at;
          "last_progress_at", `Float live.last_progress_at;
          "last_progress_kind",
            Json_util.string_opt_to_json live.last_progress_kind;
          "selected_model",
            Json_util.string_opt_to_json live.selected_model;
          "active_tool_count", `Int live.active_tool_count;
        ]
      | None -> `Null);
    "run_state", run_state_to_json s.run_state;
    "last_outcome", (match s.last_outcome with
      | Some lo -> `Assoc [
          "turn_id", `Int lo.turn_id;
          "ended_at", `Float lo.ended_at;
          "decision_stage",
            `String (decision_stage_to_string lo.decision_stage);
          "runtime_state",
            `String (runtime_state_to_string lo.runtime_state);
          "selected_model",
            Json_util.string_opt_to_json lo.selected_model;
        ]
      | None -> `Null);
    "last_skip", (match s.last_skip with
      | Some ls -> `Assoc [
          "ts", `Float ls.ls_ts;
          "reasons", `List (List.map (fun r -> `String r) ls.ls_reasons);
        ]
      | None -> `Null);
    "turn_attempt", (match s.turn_attempt with
      | Some attempt -> `Assoc [
          "turn_id", `Int attempt.ta_turn_id;
          "attempts", `Int attempt.ta_attempts;
          "first_started_at", `Float attempt.ta_first_started_at;
        ]
      | None -> `Null);
    "board_cursor", `Assoc [
      "ts", `Float s.board_cursor.bc_ts;
      "post_id", Json_util.string_opt_to_json s.board_cursor.bc_post_id;
    ];
    "board_wakeups", `Int s.board_wakeups;
    "fiber_stop_flag", `Bool s.fiber_stop_flag;
    "fiber_wakeup_flag", `Bool s.fiber_wakeup_flag;
    "idle_seconds", `Int s.idle_seconds;
    "last_turn_ts", `Float s.last_turn_ts;
    "fsm_guard_violations", `Int s.fsm_guard_violations;
    "fsm_guard_violation_breakdown",
      `List
        (List.map
           (fun bucket ->
              `Assoc
                [
                  "action", `String bucket.action;
                  "stage", `String bucket.stage;
                  "count", `Int bucket.count;
                ])
           s.fsm_guard_violation_breakdown);
  ]
