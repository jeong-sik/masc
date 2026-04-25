(** Composite observer — pure projection. See [.mli] for contract. *)

type ksm_phase =
  | Ksm_running
  | Ksm_failing
  | Ksm_overflowed
  | Ksm_compacting
  | Ksm_handing_off
  | Ksm_draining
  | Ksm_stable

let all_ksm_phases =
  [ Ksm_running; Ksm_failing; Ksm_overflowed; Ksm_compacting; Ksm_handing_off; Ksm_draining; Ksm_stable ]

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing

let all_turn_phases =
  [ Turn_idle; Turn_prompting; Turn_executing; Turn_compacting; Turn_finalizing ]

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

let all_decision_stages =
  [ Decision_undecided; Decision_guard_ok; Decision_gate_rejected; Decision_tool_policy_selected ]

type cascade_state = Keeper_registry.cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

let all_cascade_states =
  [ Cascade_idle; Cascade_selecting; Cascade_trying; Cascade_done; Cascade_exhausted ]

type compaction_stage = Keeper_registry.compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

let all_compaction_stages =
  [ Compaction_accumulating; Compaction_compacting; Compaction_done ]

type tla_action =
  | Action_start_turn
  | Action_measurement_broadcast
  | Action_decide_guard
  | Action_select_tool_policy
  | Action_start_cascade_selection
  | Action_select_cascade
  | Action_gate_rejected
  | Action_cascade_done
  | Action_cascade_exhausted
  | Action_finish_turn
  | Action_start_compaction
  | Action_finish_compaction
  | Action_enter_failing
  | Action_clear_failing
  | Action_enter_overflowed
  | Action_overflowed_auto_compact

let all_tla_actions =
  [
    Action_start_turn; Action_measurement_broadcast; Action_decide_guard; Action_select_tool_policy;
    Action_start_cascade_selection; Action_select_cascade; Action_gate_rejected; Action_cascade_done;
    Action_cascade_exhausted; Action_finish_turn; Action_start_compaction; Action_finish_compaction;
    Action_enter_failing; Action_clear_failing; Action_enter_overflowed; Action_overflowed_auto_compact;
  ]

type invariant_key =
  | Invariant_phase_turn_alignment
  | Invariant_no_cascade_before_measurement
  | Invariant_compaction_atomicity
  | Invariant_event_priority_monotone

let all_invariant_keys =
  [
    Invariant_phase_turn_alignment; Invariant_no_cascade_before_measurement;
    Invariant_compaction_atomicity; Invariant_event_priority_monotone;
  ]

type invariants_check = {
  phase_turn_alignment : bool;
  no_cascade_before_measurement : bool;
  compaction_atomicity : bool;
  event_priority_monotone : bool;
}

type last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_stage : decision_stage;
  cascade_state : cascade_state;
  selected_model : string option;
}

type snapshot = {
  correlation_id : string;
  run_id : string;
  ts : float;
  ksm_phase : ksm_phase;
  collapsed_from : Keeper_state_machine.phase option;
  ktc_turn_phase : turn_phase;
  kdp_decision : decision_stage;
  kcl_cascade_state : cascade_state;
  kmc_compaction : compaction_stage;
  kcb_state : Keeper_failure_circuit_breaker.display_state;
  shared_measurement : Keeper_state_machine.auto_rule_summary option;
  invariants : invariants_check;
  is_live : bool;
  last_outcome : last_outcome option;
  fiber_stop_flag : bool;
  fiber_wakeup_flag : bool;
  consecutive_noop_count : int;
  idle_seconds : int;
}

let ksm_phase_to_string = function
  | Ksm_running -> "Running"
  | Ksm_failing -> "Failing"
  | Ksm_overflowed -> "Overflowed"
  | Ksm_compacting -> "Compacting"
  | Ksm_handing_off -> "HandingOff"
  | Ksm_draining -> "Draining"
  | Ksm_stable -> "Stable"

let ksm_phase_of_string = function
  | "Running" -> Some Ksm_running
  | "Failing" -> Some Ksm_failing
  | "Overflowed" -> Some Ksm_overflowed
  | "Compacting" -> Some Ksm_compacting
  | "HandingOff" -> Some Ksm_handing_off
  | "Draining" -> Some Ksm_draining
  | "Stable" -> Some Ksm_stable
  | _ -> None

let turn_phase_to_string = function
  | Turn_idle -> "idle"
  | Turn_prompting -> "prompting"
  | Turn_executing -> "executing"
  | Turn_compacting -> "compacting"
  | Turn_finalizing -> "finalizing"

let turn_phase_of_string = function
  | "idle" -> Some Turn_idle
  | "prompting" -> Some Turn_prompting
  | "executing" -> Some Turn_executing
  | "compacting" -> Some Turn_compacting
  | "finalizing" -> Some Turn_finalizing
  | _ -> None

let decision_stage_to_string = function
  | Decision_undecided -> "undecided"
  | Decision_guard_ok -> "guard_ok"
  | Decision_gate_rejected -> "gate_rejected"
  | Decision_tool_policy_selected -> "tool_policy_selected"

let decision_stage_of_string = function
  | "undecided" -> Some Decision_undecided
  | "guard_ok" -> Some Decision_guard_ok
  | "gate_rejected" -> Some Decision_gate_rejected
  | "tool_policy_selected" -> Some Decision_tool_policy_selected
  | _ -> None

let cascade_state_to_string = function
  | Cascade_idle -> "idle"
  | Cascade_selecting -> "selecting"
  | Cascade_trying -> "trying"
  | Cascade_done -> "done"
  | Cascade_exhausted -> "exhausted"

let cascade_state_of_string = function
  | "idle" -> Some Cascade_idle
  | "selecting" -> Some Cascade_selecting
  | "trying" -> Some Cascade_trying
  | "done" -> Some Cascade_done
  | "exhausted" -> Some Cascade_exhausted
  | _ -> None

let compaction_stage_to_string = function
  | Compaction_accumulating -> "accumulating"
  | Compaction_compacting -> "compacting"
  | Compaction_done -> "done"

let compaction_stage_of_string = function
  | "accumulating" -> Some Compaction_accumulating
  | "compacting" -> Some Compaction_compacting
  | "done" -> Some Compaction_done
  | _ -> None

let tla_action_to_string = function
  | Action_start_turn -> "StartTurn"
  | Action_measurement_broadcast -> "MeasurementBroadcast"
  | Action_decide_guard -> "DecideGuard"
  | Action_select_tool_policy -> "SelectToolPolicy"
  | Action_start_cascade_selection -> "StartCascadeSelection"
  | Action_select_cascade -> "SelectCascade"
  | Action_gate_rejected -> "GateRejected"
  | Action_cascade_done -> "CascadeDone"
  | Action_cascade_exhausted -> "CascadeExhausted"
  | Action_finish_turn -> "FinishTurn"
  | Action_start_compaction -> "StartCompaction"
  | Action_finish_compaction -> "FinishCompaction"
  | Action_enter_failing -> "EnterFailing"
  | Action_clear_failing -> "ClearFailing"
  | Action_enter_overflowed -> "EnterOverflowed"
  | Action_overflowed_auto_compact -> "OverflowedAutoCompact"

let tla_action_of_string = function
  | "StartTurn" -> Some Action_start_turn
  | "MeasurementBroadcast" -> Some Action_measurement_broadcast
  | "DecideGuard" -> Some Action_decide_guard
  | "SelectToolPolicy" -> Some Action_select_tool_policy
  | "StartCascadeSelection" -> Some Action_start_cascade_selection
  | "SelectCascade" -> Some Action_select_cascade
  | "GateRejected" -> Some Action_gate_rejected
  | "CascadeDone" -> Some Action_cascade_done
  | "CascadeExhausted" -> Some Action_cascade_exhausted
  | "FinishTurn" -> Some Action_finish_turn
  | "StartCompaction" -> Some Action_start_compaction
  | "FinishCompaction" -> Some Action_finish_compaction
  | "EnterFailing" -> Some Action_enter_failing
  | "ClearFailing" -> Some Action_clear_failing
  | "EnterOverflowed" -> Some Action_enter_overflowed
  | "OverflowedAutoCompact" -> Some Action_overflowed_auto_compact
  | _ -> None

let invariant_key_to_string = function
  | Invariant_phase_turn_alignment -> "PhaseTurnAlignment"
  | Invariant_no_cascade_before_measurement -> "NoCascadeBeforeMeasurement"
  | Invariant_compaction_atomicity -> "CompactionAtomicity"
  | Invariant_event_priority_monotone -> "EventPriorityMonotone"

let invariant_key_of_string = function
  | "PhaseTurnAlignment" -> Some Invariant_phase_turn_alignment
  | "NoCascadeBeforeMeasurement" -> Some Invariant_no_cascade_before_measurement
  | "CompactionAtomicity" -> Some Invariant_compaction_atomicity
  | "EventPriorityMonotone" -> Some Invariant_event_priority_monotone
  | _ -> None

(* Derivation from registry entry *)

let derive_ksm_phase (phase : Keeper_state_machine.phase) : ksm_phase =
  match phase with
  | Keeper_state_machine.Running -> Ksm_running
  | Keeper_state_machine.Failing -> Ksm_failing
  | Keeper_state_machine.Overflowed -> Ksm_overflowed
  | Keeper_state_machine.Compacting -> Ksm_compacting
  | Keeper_state_machine.HandingOff -> Ksm_handing_off
  | Keeper_state_machine.Draining -> Ksm_draining
  | Keeper_state_machine.Offline
  | Keeper_state_machine.Paused
  | Keeper_state_machine.Stopped
  | Keeper_state_machine.Crashed
  | Keeper_state_machine.Restarting
  | Keeper_state_machine.Dead -> Ksm_stable

let collapsed_from_phase
    (phase : Keeper_state_machine.phase)
    (derived : ksm_phase)
    : Keeper_state_machine.phase option =
  match derived with
  | Ksm_stable -> Some phase
  | Ksm_running
  | Ksm_failing
  | Ksm_overflowed
  | Ksm_compacting
  | Ksm_handing_off
  | Ksm_draining -> None

(* Exhaustive on [ksm_phase]: the prior wildcard hid the design
   decision for new ksm_phase variants and made the dashboard report
   Turn_idle for keepers in Ksm_failing / Ksm_overflowed when there is
   no live observation. Spelling each branch out turns a future
   ksm_phase addition into a compile error and makes the chosen
   mapping auditable. (#8605 family -- exhaustive-match template) *)
let live_turn_phase (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.turn_phase
  | None ->
      (match derive_ksm_phase entry.phase with
       | Ksm_compacting -> Turn_compacting
       | Ksm_handing_off
       | Ksm_draining -> Turn_finalizing
       | Ksm_running
       | Ksm_failing
       | Ksm_overflowed
       | Ksm_stable -> Turn_idle)

let live_decision_stage (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.decision_stage
  | None -> Decision_undecided

let live_cascade_state (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.cascade_state
  | None -> Cascade_idle

let live_measurement (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some { measurement = Some measurement; _ } -> Some measurement.tm_auto_rules
  | _ -> None

(* Invariants *)

let check_phase_turn_alignment
    (phase : ksm_phase)
    (turn_phase : turn_phase)
    : bool =
  match phase, turn_phase with
  | Ksm_compacting, Turn_compacting -> true
  | Ksm_compacting, _ -> false
  | _, Turn_compacting -> false
  | _ -> true

let check_compaction_atomicity
    (phase : ksm_phase)
    (compaction_stage : compaction_stage)
    : bool =
  (compaction_stage = Compaction_compacting) = (phase = Ksm_compacting)

let check_no_cascade_before_measurement
    ~(cascade_state : cascade_state)
    ~(measurement_captured : bool)
    : bool =
  match cascade_state with
  | Cascade_idle -> true
  | Cascade_selecting | Cascade_trying | Cascade_done | Cascade_exhausted ->
      measurement_captured

let check_event_priority_monotone
    (entry : Keeper_registry.registry_entry)
    : bool =
  match entry.current_turn_observation with
  | None -> true
  | Some obs ->
      obs.measurement_bind_count <= 1
      && not (Option.is_some obs.measurement && Option.is_some entry.pending_turn_measurement)

let compute_invariants
    (entry : Keeper_registry.registry_entry)
    ~(phase : ksm_phase)
    ~(turn_phase : turn_phase)
    ~(cascade_state : cascade_state)
    ~(compaction_stage : compaction_stage)
    ~(measurement_captured : bool)
    : invariants_check =
  {
    phase_turn_alignment = check_phase_turn_alignment phase turn_phase;
    no_cascade_before_measurement =
      check_no_cascade_before_measurement
        ~cascade_state
        ~measurement_captured;
    compaction_atomicity = check_compaction_atomicity phase compaction_stage;
    event_priority_monotone = check_event_priority_monotone entry;
  }

(* Prometheus bump — one counter tick per violated invariant per snapshot.
   Called from [observe]. PromQL rate/increase distinguishes transient
   from steady-state violations. Labels bounded: keeper × invariant (4)
   ≤ ~200 series on a 50-keeper host. Mirrors the naming pattern in
   [Cascade_strategy_trace.bump_prometheus_counter]. *)
let bump_invariant_violations ~(keeper_name : string) (inv : invariants_check) =
  let bump key satisfied =
    if not satisfied then
      Prometheus.inc_counter Prometheus.metric_keeper_invariant_violations
        ~labels:[
          ("keeper", keeper_name);
          ("invariant", invariant_key_to_string key);
        ]
        ()
  in
  bump Invariant_phase_turn_alignment inv.phase_turn_alignment;
  bump Invariant_no_cascade_before_measurement inv.no_cascade_before_measurement;
  bump Invariant_compaction_atomicity inv.compaction_atomicity;
  bump Invariant_event_priority_monotone inv.event_priority_monotone

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
  let ksm_phase = derive_ksm_phase entry.phase in
  let collapsed_from = collapsed_from_phase entry.phase ksm_phase in
  let turn_phase = live_turn_phase entry in
  let compaction_stage = entry.compaction_stage in
  let decision_stage = live_decision_stage entry in
  let cascade_state = live_cascade_state entry in
  let measurement = live_measurement entry in
  let measurement_captured = Option.is_some measurement in
  let invariants =
    compute_invariants
      entry
      ~phase:ksm_phase
      ~turn_phase
      ~cascade_state
      ~compaction_stage
      ~measurement_captured
  in
  bump_invariant_violations ~keeper_name:entry.name invariants;
  let kcb_state =
    Keeper_failure_circuit_breaker.display_state_of
      ~keeper_name:entry.name
  in
  {
    correlation_id;
    run_id;
    ts;
    ksm_phase;
    collapsed_from;
    ktc_turn_phase = turn_phase;
    kdp_decision = decision_stage;
    kcl_cascade_state = cascade_state;
    kmc_compaction = compaction_stage;
    kcb_state;
    shared_measurement = measurement;
    invariants;
    is_live;
    last_outcome =
      (match entry.last_completed_turn with
       | Some lc ->
         Some {
           turn_id = lc.ct_turn_id;
           ended_at = lc.ct_ended_at;
           decision_stage = lc.ct_decision_stage;
           cascade_state = lc.ct_cascade_state;
           selected_model = lc.ct_selected_model;
         }
       | None -> None);
    fiber_stop_flag = Atomic.get entry.fiber_stop;
    fiber_wakeup_flag = Atomic.get entry.fiber_wakeup;
    consecutive_noop_count =
      entry.meta.runtime.proactive_rt.consecutive_noop_count;
    idle_seconds =
      (let last = entry.meta.runtime.proactive_rt.last_ts in
       if last <= 0.0 then 0
       else int_of_float (max 0.0 (Time_compat.now () -. last)));
  }

(* Fleet fold — observe every currently-registered keeper under
   [base_path] once. Preserves registry iteration order so downstream
   matrix rendering stays stable across successive polls.

   Used by GET /api/v1/keepers/composite (LT-16a). *)
let all_snapshots ~(base_path : string) () : snapshot list =
  Keeper_registry.all ~base_path ()
  |> List.map (fun entry -> observe entry)

(* JSON serialisation (RFC-0003 §7) *)

let invariants_to_json (inv : invariants_check) : Yojson.Safe.t =
  `Assoc [
    "phase_turn_alignment", `Bool inv.phase_turn_alignment;
    "no_cascade_before_measurement", `Bool inv.no_cascade_before_measurement;
    "compaction_atomicity", `Bool inv.compaction_atomicity;
    "event_priority_monotone", `Bool inv.event_priority_monotone;
  ]

let measurement_to_json (m : Keeper_state_machine.auto_rule_summary) : Yojson.Safe.t =
  `Assoc
    [
      "reflect", `Bool m.reflect;
      "plan", `Bool m.plan;
      "compact", `Bool m.compact;
      "handoff", `Bool m.handoff;
      "guardrail_stop", `Bool m.guardrail_stop;
      "guardrail_reason", (match m.guardrail_reason with Some s -> `String s | None -> `Null);
      "goal_drift", `Float m.goal_drift;
    ]

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    "correlation_id", `String s.correlation_id;
    "run_id", `String s.run_id;
    "ts", `Float s.ts;
    "phase", `String (ksm_phase_to_string s.ksm_phase);
    ( "collapsed_from",
      match s.collapsed_from with
      | Some phase -> `String (Keeper_state_machine.phase_to_string phase)
      | None -> `Null );
    "turn_phase", `String (turn_phase_to_string s.ktc_turn_phase);
    "decision", `Assoc [
      "stage", `String (decision_stage_to_string s.kdp_decision);
    ];
    "cascade", `Assoc [
      "state", `String (cascade_state_to_string s.kcl_cascade_state);
    ];
    "compaction", `Assoc [
      "stage", `String (compaction_stage_to_string s.kmc_compaction);
    ];
    "circuit_breaker", `Assoc [
      "state",
      `String
        (Keeper_failure_circuit_breaker.display_state_to_string
           s.kcb_state);
    ];
    "measurement", (match s.shared_measurement with
      | Some m -> `Assoc [
          "captured", `Bool true;
          "auto_rules", measurement_to_json m;
        ]
      | None -> `Assoc [
          "captured", `Bool false;
        ]);
    "invariants", invariants_to_json s.invariants;
    "is_live", `Bool s.is_live;
    "last_outcome", (match s.last_outcome with
      | Some lo -> `Assoc [
          "turn_id", `Int lo.turn_id;
          "ended_at", `Float lo.ended_at;
          "decision_stage",
            `String (decision_stage_to_string lo.decision_stage);
          "cascade_state",
            `String (cascade_state_to_string lo.cascade_state);
          "selected_model",
            (match lo.selected_model with
             | Some model -> `String model
             | None -> `Null);
        ]
      | None -> `Null);
    "fiber_stop_flag", `Bool s.fiber_stop_flag;
    "fiber_wakeup_flag", `Bool s.fiber_wakeup_flag;
    "consecutive_noop_count", `Int s.consecutive_noop_count;
    "idle_seconds", `Int s.idle_seconds;
  ]
