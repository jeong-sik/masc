(** Composite observer — pure projection. See [.mli] for contract. *)

type turn_phase = Keeper_registry.turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_routing
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing
  | Turn_exhausted

let all_turn_phases : Keeper_registry.packed_turn_phase list =
  [ Keeper_registry.Packed Turn_idle
  ; Keeper_registry.Packed Turn_prompting
  ; Keeper_registry.Packed Turn_routing
  ; Keeper_registry.Packed Turn_executing
  ; Keeper_registry.Packed Turn_compacting
  ; Keeper_registry.Packed Turn_finalizing
  ; Keeper_registry.Packed Turn_exhausted
  ]

type decision_stage = Keeper_registry.decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

let all_decision_stages : Keeper_registry.packed_decision_stage list =
  [ Keeper_registry.Packed Decision_undecided
  ; Keeper_registry.Packed Decision_guard_ok
  ; Keeper_registry.Packed Decision_gate_rejected
  ; Keeper_registry.Packed Decision_tool_policy_selected
  ]

type cascade_state = Keeper_registry.cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

let all_cascade_states : Keeper_registry.packed_cascade_state list =
  [ Keeper_registry.Packed Cascade_idle
  ; Keeper_registry.Packed Cascade_selecting
  ; Keeper_registry.Packed Cascade_trying
  ; Keeper_registry.Packed Cascade_done
  ; Keeper_registry.Packed Cascade_exhausted
  ]

type compaction_stage = Keeper_registry.compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

let all_compaction_stages : Keeper_registry.packed_compaction_stage list =
  [ Keeper_registry.Packed Compaction_accumulating
  ; Keeper_registry.Packed Compaction_compacting
  ; Keeper_registry.Packed Compaction_done
  ]

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
  | Invariant_phase_derivation_agreement

let all_invariant_keys =
  [
    Invariant_phase_turn_alignment; Invariant_no_cascade_before_measurement;
    Invariant_compaction_atomicity; Invariant_event_priority_monotone;
    Invariant_phase_derivation_agreement;
  ]

type invariants_check = {
  phase_turn_alignment : bool;
  no_cascade_before_measurement : bool;
  compaction_atomicity : bool;
  event_priority_monotone : bool;
  phase_derivation_agreement : bool;
}

type last_outcome = {
  turn_id : int;
  ended_at : float;
  decision_stage : Keeper_registry.packed_decision_stage;
  cascade_state : Keeper_registry.packed_cascade_state;
  selected_model : string option;
}

type snapshot = {
  keeper_name : string;
  correlation_id : string;
  run_id : string;
  ts : float;
  phase : Keeper_state_machine.phase;
  ktc_turn_phase : Keeper_registry.packed_turn_phase;
  kdp_decision : Keeper_registry.packed_decision_stage;
  kcl_cascade_state : Keeper_registry.packed_cascade_state;
  kmc_compaction : Keeper_registry.packed_compaction_stage;
  kcb_state : Keeper_failure_circuit_breaker.display_state;
  shared_measurement : Keeper_state_machine.auto_rule_summary option;
  invariants : invariants_check;
  conditions : Keeper_state_machine.conditions;
  is_live : bool;
  last_outcome : last_outcome option;
  fiber_stop_flag : bool;
  fiber_wakeup_flag : bool;
  consecutive_noop_count : int;
  idle_seconds : int;
  last_turn_ts : float;
  fsm_guard_violations : int;
}

let turn_phase_to_string (tp : Keeper_registry.packed_turn_phase) =
  match tp with
  | Keeper_registry.Packed Turn_idle -> "idle"
  | Keeper_registry.Packed Turn_prompting -> "prompting"
  | Keeper_registry.Packed Turn_routing -> "routing"
  | Keeper_registry.Packed Turn_executing -> "executing"
  | Keeper_registry.Packed Turn_compacting -> "compacting"
  | Keeper_registry.Packed Turn_finalizing -> "finalizing"
  | Keeper_registry.Packed Turn_exhausted -> "exhausted"

let turn_phase_of_string = function
  | "idle" -> Some Turn_idle
  | "prompting" -> Some Turn_prompting
  | "routing" -> Some Turn_routing
  | "executing" -> Some Turn_executing
  | "compacting" -> Some Turn_compacting
  | "finalizing" -> Some Turn_finalizing
  | "exhausted" -> Some Turn_exhausted
  | _ -> None

let decision_stage_to_string (s : Keeper_registry.packed_decision_stage) =
  match s with
  | Keeper_registry.Packed Decision_undecided -> "undecided"
  | Keeper_registry.Packed Decision_guard_ok -> "guard_ok"
  | Keeper_registry.Packed Decision_gate_rejected -> "gate_rejected"
  | Keeper_registry.Packed Decision_tool_policy_selected -> "tool_policy_selected"

let decision_stage_of_string = function
  | "undecided" -> Some Decision_undecided
  | "guard_ok" -> Some Decision_guard_ok
  | "gate_rejected" -> Some Decision_gate_rejected
  | "tool_policy_selected" -> Some Decision_tool_policy_selected
  | _ -> None

let cascade_state_to_string (s : Keeper_registry.packed_cascade_state) =
  match s with
  | Keeper_registry.Packed Cascade_idle -> "idle"
  | Keeper_registry.Packed Cascade_selecting -> "selecting"
  | Keeper_registry.Packed Cascade_trying -> "trying"
  | Keeper_registry.Packed Cascade_done -> "done"
  | Keeper_registry.Packed Cascade_exhausted -> "exhausted"

let cascade_state_of_string = function
  | "idle" -> Some Cascade_idle
  | "selecting" -> Some Cascade_selecting
  | "trying" -> Some Cascade_trying
  | "done" -> Some Cascade_done
  | "exhausted" -> Some Cascade_exhausted
  | _ -> None

let compaction_stage_to_string (s : Keeper_registry.packed_compaction_stage) =
  match s with
  | Keeper_registry.Packed Compaction_accumulating -> "accumulating"
  | Keeper_registry.Packed Compaction_compacting -> "compacting"
  | Keeper_registry.Packed Compaction_done -> "done"

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
  | Invariant_phase_derivation_agreement -> "PhaseDerivationAgreement"

let invariant_key_of_string = function
  | "PhaseTurnAlignment" -> Some Invariant_phase_turn_alignment
  | "NoCascadeBeforeMeasurement" -> Some Invariant_no_cascade_before_measurement
  | "CompactionAtomicity" -> Some Invariant_compaction_atomicity
  | "EventPriorityMonotone" -> Some Invariant_event_priority_monotone
  | "PhaseDerivationAgreement" -> Some Invariant_phase_derivation_agreement
  | _ -> None

(* Derivation from registry entry *)

(* Exhaustive on [Keeper_state_machine.phase]: maps the raw 12-state
   keeper phase to the turn phase projection when no live turn
   observation exists.  Spelling each branch out turns a future phase
   addition into a compile error. *)
let live_turn_phase (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.turn_phase
  | None ->
      (match entry.phase with
       | Keeper_state_machine.Compacting ->
           Keeper_registry.Packed Turn_compacting
       | Keeper_state_machine.HandingOff
       | Keeper_state_machine.Draining ->
           Keeper_registry.Packed Turn_finalizing
       | Keeper_state_machine.Running
       | Keeper_state_machine.Failing
       | Keeper_state_machine.Overflowed
       | Keeper_state_machine.Offline
       | Keeper_state_machine.Paused
       | Keeper_state_machine.Stopped
       | Keeper_state_machine.Crashed
       | Keeper_state_machine.Restarting
       | Keeper_state_machine.Dead
       | Keeper_state_machine.Zombie ->
           Keeper_registry.Packed Turn_idle)

let live_decision_stage (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.decision_stage
  | None -> Keeper_registry.Packed Decision_undecided

let live_cascade_state (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some obs -> obs.cascade_state
  | None -> Keeper_registry.Packed Cascade_idle

let live_measurement (entry : Keeper_registry.registry_entry) =
  match entry.current_turn_observation with
  | Some { measurement = Some measurement; _ } -> Some measurement.tm_auto_rules
  | _ -> None

(* Invariants *)

let check_phase_turn_alignment
    (phase : Keeper_state_machine.phase)
    (turn_phase : Keeper_registry.packed_turn_phase)
    : bool =
  match turn_phase with
  | Keeper_registry.Packed Turn_compacting ->
      (phase = Keeper_state_machine.Compacting)
  | Keeper_registry.Packed Turn_idle
  | Keeper_registry.Packed Turn_prompting
  | Keeper_registry.Packed Turn_routing
  | Keeper_registry.Packed Turn_executing
  | Keeper_registry.Packed Turn_finalizing
  | Keeper_registry.Packed Turn_exhausted ->
      not (phase = Keeper_state_machine.Compacting)

let check_compaction_atomicity
    (phase : Keeper_state_machine.phase)
    (compaction_stage : Keeper_registry.packed_compaction_stage)
    : bool =
  match compaction_stage with
  | Keeper_registry.Packed Compaction_compacting ->
      (phase = Keeper_state_machine.Compacting)
  | Keeper_registry.Packed Compaction_accumulating
  | Keeper_registry.Packed Compaction_done ->
      not (phase = Keeper_state_machine.Compacting)

let check_no_cascade_before_measurement
    ~(cascade_state : Keeper_registry.packed_cascade_state)
    ~(measurement_captured : bool)
    : bool =
  match cascade_state with
  | Packed Cascade_idle -> true
  | Packed (Cascade_selecting | Cascade_trying | Cascade_done | Cascade_exhausted) ->
      measurement_captured

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
    ~(cascade_state : Keeper_registry.packed_cascade_state)
    ~(compaction_stage : Keeper_registry.packed_compaction_stage)
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
    phase_derivation_agreement = check_phase_derivation_agreement entry;
  }

(* Prometheus bump — one counter tick per violated invariant per snapshot.
   Called from [observe]. PromQL rate/increase distinguishes transient
   from steady-state violations. Labels bounded: keeper × invariant (5)
   ≤ ~250 series on a 50-keeper host. Mirrors the naming pattern in
   [Cascade_strategy_trace.bump_prometheus_counter]. *)
let bump_invariant_violations ~(keeper_name : string) (inv : invariants_check) =
  let bump key satisfied =
    if not satisfied then
      Prometheus.inc_counter Keeper_metrics.metric_keeper_invariant_violations
        ~labels:[
          ("keeper", keeper_name);
          ("invariant", invariant_key_to_string key);
        ]
        ()
  in
  bump Invariant_phase_turn_alignment inv.phase_turn_alignment;
  bump Invariant_no_cascade_before_measurement inv.no_cascade_before_measurement;
  bump Invariant_compaction_atomicity inv.compaction_atomicity;
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
  let compaction_stage = entry.compaction_stage in
  let decision_stage = live_decision_stage entry in
  let cascade_state = live_cascade_state entry in
  let measurement = live_measurement entry in
  let measurement_captured = Option.is_some measurement in
  let invariants =
    compute_invariants
      entry
      ~phase:entry.phase
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
    keeper_name = entry.name;
    correlation_id;
    run_id;
    ts;
    phase = entry.phase;
    ktc_turn_phase = turn_phase;
    kdp_decision = decision_stage;
    kcl_cascade_state = cascade_state;
    kmc_compaction = compaction_stage;
    kcb_state;
    shared_measurement = measurement;
    invariants;
    conditions = entry.conditions;
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
    last_turn_ts = entry.meta.runtime.usage.last_turn_ts;
    fsm_guard_violations =
      Prometheus.metric_total Prometheus.metric_fsm_guard_violation
      |> int_of_float;
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
    "phase_derivation_agreement", `Bool inv.phase_derivation_agreement;
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
    row "stopped_clean_drain" "Stopped: clean drain complete" 1
      (c.stop_requested && c.drain_complete
       && not c.compaction_active && not c.handoff_active)
      Keeper_state_machine.Stopped;
    row "offline_launch_pending" "Offline: launch pending without fiber" 2
      (c.launch_pending && not c.fiber_alive)
      Keeper_state_machine.Offline;
    row "zombie_terminal_failure" "Zombie: terminal failure latched" 3
      c.terminal_failure_latched
      Keeper_state_machine.Zombie;
    row "dead_no_fiber_no_budget" "Dead: fiber down and restart budget exhausted" 4
      ((not c.fiber_alive) && not c.restart_budget_remaining)
      Keeper_state_machine.Dead;
    row "restarting_backoff_elapsed" "Restarting: fiber down with elapsed backoff" 5
      ((not c.fiber_alive) && c.restart_budget_remaining && c.backoff_elapsed)
      Keeper_state_machine.Restarting;
    row "crashed_restart_budget" "Crashed: fiber down with restart budget" 6
      ((not c.fiber_alive) && c.restart_budget_remaining)
      Keeper_state_machine.Crashed;
    row "draining_stop_requested" "Draining: stop requested" 7
      c.stop_requested
      Keeper_state_machine.Draining;
    row "failing_guardrail" "Failing: guardrail triggered" 8
      c.guardrail_triggered
      Keeper_state_machine.Failing;
    row "paused_operator_or_retry_exhausted" "Paused: operator pause or compact retry exhausted" 9
      (c.operator_paused || (c.context_overflow && c.compact_retry_exhausted))
      Keeper_state_machine.Paused;
    row "handing_off_active" "HandingOff: handoff active" 10
      c.handoff_active
      Keeper_state_machine.HandingOff;
    row "compacting_active" "Compacting: compaction active" 11
      c.compaction_active
      Keeper_state_machine.Compacting;
    row "overflowed_context" "Overflowed: context overflow awaiting compaction" 12
      c.context_overflow
      Keeper_state_machine.Overflowed;
    row "failing_unhealthy" "Failing: heartbeat or turn unhealthy" 13
      ((not c.heartbeat_healthy) || not c.turn_healthy)
      Keeper_state_machine.Failing;
    row "running_fiber_alive" "Running: fiber alive" 14
      c.fiber_alive
      Keeper_state_machine.Running;
    row "offline_fallback" "Offline: fallback" 15
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
    "conditions", Keeper_state_machine.conditions_to_json conditions;
    "determining_condition",
      (match determining with
       | Some key -> `String key
       | None -> `Null);
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
    "phase_diagnosis", phase_diagnosis_to_json
      ~current_phase:s.phase s.conditions;
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
    "last_turn_ts", `Float s.last_turn_ts;
    "fsm_guard_violations", `Int s.fsm_guard_violations;
  ]
