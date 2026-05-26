(** Composite observer — pure projection. See [.mli] for contract. *)

include Keeper_composite_observer_types

let take_fsm_guard_buckets limit buckets =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | bucket :: rest -> loop (remaining - 1) (bucket :: acc) rest
  in
  loop limit [] buckets
;;

let fsm_guard_violation_breakdown () =
  Prometheus.snapshot ()
  |> List.filter_map (fun (metric : Prometheus.metric) ->
    if String.equal metric.name Prometheus.metric_fsm_guard_violation
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

(* Derivation from registry entry *)

(* Exhaustive on [Keeper_state_machine.phase]: maps the raw 13-state
   keeper phase (post-Zombie #14707) to the turn phase projection when
   no live turn observation exists.  Spelling each branch out turns a
   future phase
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
    live_turn =
      (match entry.current_turn_observation with
       | Some obs ->
         Some
           {
             turn_id = obs.turn_id;
             started_at = obs.started_at;
             last_progress_at = obs.last_progress_at;
             last_progress_kind = obs.last_progress_kind;
           }
       | None -> None);
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
    fsm_guard_violation_breakdown = fsm_guard_violation_breakdown ();
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
    "conditions", Keeper_state_machine_json.conditions_to_json conditions;
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
    "live_turn", (match s.live_turn with
      | Some live ->
        `Assoc [
          "turn_id", `Int live.turn_id;
          "started_at", `Float live.started_at;
          "last_progress_at", `Float live.last_progress_at;
          "last_progress_kind",
            (match live.last_progress_kind with
             | Some kind -> `String kind
             | None -> `Null);
        ]
      | None -> `Null);
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
