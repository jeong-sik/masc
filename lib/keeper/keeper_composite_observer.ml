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
  [
    Ksm_running;
    Ksm_failing;
    Ksm_overflowed;
    Ksm_compacting;
    Ksm_handing_off;
    Ksm_draining;
    Ksm_stable;
  ]

type turn_phase =
  | Turn_idle
  | Turn_prompting
  | Turn_executing
  | Turn_compacting
  | Turn_finalizing

let all_turn_phases =
  [ Turn_idle; Turn_prompting; Turn_executing; Turn_compacting; Turn_finalizing ]

type decision_stage =
  | Decision_undecided
  | Decision_guard_ok
  | Decision_gate_rejected
  | Decision_tool_policy_selected

let all_decision_stages =
  [
    Decision_undecided;
    Decision_guard_ok;
    Decision_gate_rejected;
    Decision_tool_policy_selected;
  ]

type cascade_state =
  | Cascade_idle
  | Cascade_selecting
  | Cascade_trying
  | Cascade_done
  | Cascade_exhausted

let all_cascade_states =
  [
    Cascade_idle;
    Cascade_selecting;
    Cascade_trying;
    Cascade_done;
    Cascade_exhausted;
  ]

type compaction_stage =
  | Compaction_accumulating
  | Compaction_compacting
  | Compaction_done

let all_compaction_stages =
  [ Compaction_accumulating; Compaction_compacting; Compaction_done ]

type invariants_check = {
  phase_turn_alignment : bool;
  no_cascade_before_measurement : bool;
  compaction_atomicity : bool;
  event_priority_monotone : bool;
}

type last_outcome = {
  turn_id : int;
  ended_at : float;
}

type snapshot = {
  correlation_id : string;
  run_id : string;
  ts : float;
  ksm_phase : ksm_phase;
  ktc_turn_phase : turn_phase;
  kdp_decision : decision_stage;
  kcl_cascade_state : cascade_state;
  kmc_compaction : compaction_stage;
  shared_measurement : Keeper_state_machine.auto_rule_summary option;
  invariants : invariants_check;
  is_live : bool;
  last_outcome : last_outcome option;
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

(* ================================================================ *)
(* Derivation from registry entry                                   *)
(* ================================================================ *)

(* The turn-cycle phase is derived from the keeper lifecycle phase.
   Per-turn-internal sub-phases (Prompting, Executing) are not visible
   to the observer — those live inside a single [run_unified_turn] call.
   Post-turn hooks (PR follow-up) will update shared state so the
   observer can distinguish them. *)
(* Turn-cycle phase derivation (issue #7122).

   The Compacting/Finalizing branches reflect KSM lifecycle phases that
   the keeper enters between turns. Within a normal turn the phase
   defaults to [Idle] unless [current_turn_observation] is [Some _],
   in which case the keeper is actively in [`Executing`] — the OAS
   call is in flight, between [mark_turn_started] and
   [mark_turn_finished]. Finer-grained breakdown
   ([Prompting]/[ToolCall]) requires Event_bus subscription and is
   tracked as Phase 2 of #7122. *)
(* KSM projection rule from KeeperCompositeLifecycle.tla Comment A.

   The observer cares only about parent phases that materially affect
   cross-FSM ordering. Turn-external or terminal phases collapse to
   [Ksm_stable]; [Overflowed] remains explicit because it is a distinct
   pre-compaction lifecycle edge in both the OCaml FSM and the TLA+
   projection. *)
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

let derive_turn_phase
    ~(ksm_phase : ksm_phase)
    ~(is_live : bool)
    : turn_phase =
  match ksm_phase with
  | Ksm_compacting -> Turn_compacting
  | Ksm_handing_off
  | Ksm_draining -> Turn_finalizing
  | _ -> if is_live then Turn_executing else Turn_idle

(* Compaction sub-FSM: compaction_active is the authoritative condition.
   Phase [Compacting] MUST coincide with this condition under the
   [PhaseTurnAlignment] invariant; any drift is a safety signal. *)
let derive_compaction_stage (conds : Keeper_state_machine.conditions)
    : compaction_stage =
  if conds.compaction_active then Compaction_compacting
  else Compaction_accumulating

(* Decision pipeline stage.

   Three inputs determine the decision projection:
   1. [guardrail_triggered] (sticky condition) → [Gate_rejected].
   2. [current_turn_observation <> None] (is_live) → the turn started,
      so guards MUST have passed. This is a logical implication, not a
      guess: the turn loop calls guard evaluation before
      [mark_turn_started], and a guard rejection prevents the turn from
      starting at all. Projecting [Guard_ok] when a turn is running is
      provably correct.
   3. Otherwise → [Undecided]. No turn is running, no guardrail tripped.

   [Tool_policy_selected] remains a Phase 2 follow-up (#7122) since it
   requires knowing whether tool selection has occurred within the
   current turn, which is per-call-internal state. *)
let derive_decision_stage
    (conds : Keeper_state_machine.conditions)
    ~(is_live : bool)
    : decision_stage =
  if conds.guardrail_triggered then Decision_gate_rejected
  else if is_live then Decision_guard_ok
  else Decision_undecided

(* Cascade state.

   [is_live] means the OAS worker call is in flight. During that window
   the cascade is either selecting a provider or executing inference —
   both map to [`Trying`] at the dashboard granularity. When the turn
   finishes ([is_live = false]), the cascade is no longer active, so
   [`Idle`] is correct.

   This avoids the "stale state on idle keepers" problem that ruled out
   the post-hoc-persist approach (see #7122), because the projection
   derives from [current_turn_observation] which is atomically cleared
   by [mark_turn_finished].

   Finer-grained live cascade state ([`Selecting`] vs [`Trying`] vs
   [`Done`]) remains a Phase 2 follow-up (#7122) requiring Event_bus
   subscription. *)
let derive_cascade_state ~(is_live : bool) : cascade_state =
  if is_live then Cascade_trying else Cascade_idle

(* ================================================================ *)
(* Invariants                                                       *)
(* ================================================================ *)

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
    (conds : Keeper_state_machine.conditions)
    : bool =
  let phase_is_compacting = phase = Ksm_compacting in
  phase_is_compacting = conds.compaction_active

(* NoCascadeBeforeMeasurement from KeeperCompositeLifecycle.tla:
   when the cascade sub-FSM is active, a measurement snapshot must
   already have been captured. Cascade work pulled through a provider
   without a preceding measurement indicates the auto-rule gate was
   bypassed.

   With [derive_cascade_state] projecting [`Trying`] when is_live (#7319),
   this invariant is now observable from a single snapshot: cascade
   non-idle AND measurement absent is the violation. *)
let check_no_cascade_before_measurement
    ~(cascade_state : cascade_state)
    ~(measurement_captured : bool)
    : bool =
  match cascade_state with
  | Cascade_idle -> true
  | Cascade_selecting | Cascade_trying | Cascade_done | Cascade_exhausted ->
      measurement_captured
let compute_invariants
    ~(phase : ksm_phase)
    ~(conds : Keeper_state_machine.conditions)
    ~(turn_phase : turn_phase)
    ~(cascade_state : cascade_state)
    ~(measurement_captured : bool)
    : invariants_check =
  {
    phase_turn_alignment = check_phase_turn_alignment phase turn_phase;
    no_cascade_before_measurement =
      check_no_cascade_before_measurement
        ~cascade_state
        ~measurement_captured;
    compaction_atomicity = check_compaction_atomicity phase conds;
    event_priority_monotone = true;
    (* per-snapshot view cannot witness event ordering; this invariant
       becomes checkable when the event-bus broadcast carries priority
       annotations (follow-up to #7122). *)
  }

(* ================================================================ *)
(* Public API                                                       *)
(* ================================================================ *)

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
  let conds = entry.conditions in
  let is_live = entry.current_turn_observation <> None in
  let ksm_phase = derive_ksm_phase entry.phase in
  let turn_phase = derive_turn_phase ~ksm_phase ~is_live in
  let compaction_stage = derive_compaction_stage conds in
  let decision_stage = derive_decision_stage conds ~is_live in
  let cascade_state = derive_cascade_state ~is_live in
  let measurement_captured = entry.last_auto_rules <> None in
  let invariants =
    compute_invariants
      ~phase:ksm_phase
      ~conds
      ~turn_phase
      ~cascade_state
      ~measurement_captured
  in
  {
    correlation_id;
    run_id;
    ts;
    ksm_phase;
    ktc_turn_phase = turn_phase;
    kdp_decision = decision_stage;
    kcl_cascade_state = cascade_state;
    kmc_compaction = compaction_stage;
    shared_measurement =
      (match entry.last_auto_rules with
       | Some (_ts, summary) -> Some summary
       | None -> None);
    (* Registry retains the last [Context_measured] auto-rule summary in
       [last_auto_rules]. The wall-clock timestamp is discarded here
       because the snapshot's [ts] field already carries it; if callers
       ever need the original measurement timestamp, extend the snapshot
       type rather than widening [shared_measurement]. *)
    invariants;
    is_live;
    last_outcome =
      (match entry.last_completed_turn with
       | Some lc ->
         Some {
           turn_id = lc.ct_turn_id;
           ended_at = lc.ct_ended_at;
         }
       | None -> None);
  }

(* ================================================================ *)
(* JSON serialisation (RFC-0003 §7)                                *)
(* ================================================================ *)

let invariants_to_json (inv : invariants_check) : Yojson.Safe.t =
  `Assoc [
    "phase_turn_alignment", `Bool inv.phase_turn_alignment;
    "no_cascade_before_measurement", `Bool inv.no_cascade_before_measurement;
    "compaction_atomicity", `Bool inv.compaction_atomicity;
    "event_priority_monotone", `Bool inv.event_priority_monotone;
  ]

let measurement_to_json (m : Keeper_state_machine.auto_rule_summary)
    : Yojson.Safe.t =
  `Assoc [
    "reflect", `Bool m.reflect;
    "plan", `Bool m.plan;
    "compact", `Bool m.compact;
    "handoff", `Bool m.handoff;
    "guardrail_stop", `Bool m.guardrail_stop;
    "guardrail_reason", (match m.guardrail_reason with
      | Some s -> `String s
      | None -> `Null);
    "goal_drift", `Float m.goal_drift;
  ]

let snapshot_to_json (s : snapshot) : Yojson.Safe.t =
  `Assoc [
    "correlation_id", `String s.correlation_id;
    "run_id", `String s.run_id;
    "ts", `Float s.ts;
    "phase", `String (ksm_phase_to_string s.ksm_phase);
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
        ]
      | None -> `Null);
  ]
