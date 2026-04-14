(** Composite observer — pure projection. See [.mli] for contract. *)

type turn_phase =
  [ `Idle
  | `Prompting
  | `Executing
  | `Compacting
  | `Finalizing ]

type decision_stage =
  [ `Undecided
  | `Guard_ok
  | `Gate_rejected
  | `Tool_policy_selected ]

type cascade_state =
  [ `Idle
  | `Selecting
  | `Trying
  | `Done
  | `Exhausted ]

type compaction_stage =
  [ `Accumulating
  | `Compacting
  | `Done ]

type invariants_check = {
  phase_turn_alignment : bool;
  no_cascade_before_measurement : bool;
  compaction_atomicity : bool;
  event_priority_monotone : bool;
  recovery_two_store_sync : bool;
}

type snapshot = {
  correlation_id : string;
  run_id : string;
  ts : float;
  ksm_phase : Keeper_state_machine.phase;
  ktc_turn_phase : turn_phase;
  kdp_decision : decision_stage;
  kcl_cascade_state : cascade_state;
  kmc_compaction : compaction_stage;
  shared_measurement : Keeper_state_machine.auto_rule_summary option;
  reconcile_data : bool;
  reconcile_fsm : bool;
  invariants : invariants_check;
}

let turn_phase_to_string = function
  | `Idle -> "idle"
  | `Prompting -> "prompting"
  | `Executing -> "executing"
  | `Compacting -> "compacting"
  | `Finalizing -> "finalizing"

let decision_stage_to_string = function
  | `Undecided -> "undecided"
  | `Guard_ok -> "guard_ok"
  | `Gate_rejected -> "gate_rejected"
  | `Tool_policy_selected -> "tool_policy_selected"

let cascade_state_to_string = function
  | `Idle -> "idle"
  | `Selecting -> "selecting"
  | `Trying -> "trying"
  | `Done -> "done"
  | `Exhausted -> "exhausted"

let compaction_stage_to_string = function
  | `Accumulating -> "accumulating"
  | `Compacting -> "compacting"
  | `Done -> "done"

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
let derive_turn_phase (entry : Keeper_registry.registry_entry) : turn_phase =
  match entry.phase with
  | Keeper_state_machine.Compacting -> `Compacting
  | Keeper_state_machine.HandingOff
  | Keeper_state_machine.Draining -> `Finalizing
  | _ ->
    (match entry.current_turn_observation with
     | Some _ -> `Executing
     | None -> `Idle)

(* Compaction sub-FSM: compaction_active is the authoritative condition.
   Phase [Compacting] MUST coincide with this condition under the
   [PhaseTurnAlignment] invariant; any drift is a safety signal. *)
let derive_compaction_stage (conds : Keeper_state_machine.conditions)
    : compaction_stage =
  if conds.compaction_active then `Compacting
  else `Accumulating

(* Decision pipeline stage (issue #7122 Phase 2 follow-up).

   Only [Gate_rejected] is observable from the registry today
   ([guardrail_triggered] is a sticky condition). [Guard_ok] and
   [Tool_policy_selected] are per-turn-internal and require either
   Event_bus subscription (TurnStarted → Guard pass) or an explicit
   field on [current_turn_observation] populated by the decision
   audit. Returning [Undecided] for the non-rejected case is the
   honest placeholder — we do not have observability for the
   intermediate states yet. Anything else would be a stale-state lie. *)
let derive_decision_stage (conds : Keeper_state_machine.conditions)
    : decision_stage =
  if conds.guardrail_triggered then `Gate_rejected
  else `Undecided

(* Cascade state (issue #7122 Phase 2 follow-up).

   [cascade_observation] is produced by [Oas_worker.run_named] only
   on the success path, after the cascade has already terminated.
   Persisting it into the registry post-hoc would surface stale
   [`Done`/`Trying`] on idle keepers — strictly worse than [`Idle`].
   Live cascade state requires Event_bus subscription on
   [TurnStarted]/[ToolCalled] events that flow through the OAS
   pipeline. Until that wiring lands, the only honest projection
   is [`Idle`]. See #7122 for the design constraints that ruled out
   the post-hoc-persist approach. *)
let derive_cascade_state (_ : Keeper_registry.registry_entry) : cascade_state =
  `Idle

(* Two-store reconcile pair (RFC-0003 §8, absorbed from P4).
   - [reconcile_data]: a prior turn left an ambiguous side-effect record
     that still requires operator resolution. Sourced from
     [last_failure_reason] when the reason is classified as requiring
     manual reconcile.
   - [reconcile_fsm]: the keeper's own state machine still carries
     [manual_reconcile_required] as an observable condition. *)
let derive_reconcile (entry : Keeper_registry.registry_entry) : bool * bool =
  let reconcile_data =
    match entry.last_failure_reason with
    | None -> false
    | Some reason ->
      Keeper_registry.failure_reason_requires_manual_reconcile reason
  in
  let reconcile_fsm = entry.conditions.manual_reconcile_required in
  (reconcile_data, reconcile_fsm)

(* ================================================================ *)
(* Invariants                                                       *)
(* ================================================================ *)

let check_phase_turn_alignment
    (phase : Keeper_state_machine.phase)
    (turn_phase : turn_phase)
    : bool =
  match phase, turn_phase with
  | Keeper_state_machine.Compacting, `Compacting -> true
  | Keeper_state_machine.Compacting, _ -> false
  | _, `Compacting -> false
  | _ -> true

let check_compaction_atomicity
    (phase : Keeper_state_machine.phase)
    (conds : Keeper_state_machine.conditions)
    : bool =
  let phase_is_compacting = phase = Keeper_state_machine.Compacting in
  phase_is_compacting = conds.compaction_active

(* RecoveryTwoStoreSync from KeeperCompositeLifecycle.tla:
   the dangerous ordering is [reconcile_data cleared /\ reconcile_fsm still set],
   which indicates a prior clear raced ahead of the FSM condition update.
   The normal [(T,T) → (F,T) → (F,F)] path passes through [(F,T)] but only
   as a transient; if observed, it may just be an in-flight reconcile.
   For the snapshot-level check we flag only the reverse-order anomaly:
   [reconcile_fsm cleared while reconcile_data still set]. *)
let check_recovery_two_store_sync
    ~(reconcile_data : bool)
    ~(reconcile_fsm : bool)
    : bool =
  not (reconcile_data && not reconcile_fsm)

let compute_invariants
    ~(phase : Keeper_state_machine.phase)
    ~(conds : Keeper_state_machine.conditions)
    ~(turn_phase : turn_phase)
    ~(reconcile_data : bool)
    ~(reconcile_fsm : bool)
    : invariants_check =
  {
    phase_turn_alignment = check_phase_turn_alignment phase turn_phase;
    no_cascade_before_measurement = true;
    (* trivially true until cascade state is observable — see
       [derive_cascade_state]. *)
    compaction_atomicity = check_compaction_atomicity phase conds;
    event_priority_monotone = true;
    (* per-snapshot view cannot witness event ordering; this invariant
       becomes checkable when the event-bus broadcast carries priority
       annotations (follow-up). *)
    recovery_two_store_sync =
      check_recovery_two_store_sync ~reconcile_data ~reconcile_fsm;
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
  let turn_phase = derive_turn_phase entry in
  let compaction_stage = derive_compaction_stage conds in
  let decision_stage = derive_decision_stage conds in
  let cascade_state = derive_cascade_state entry in
  let (reconcile_data, reconcile_fsm) = derive_reconcile entry in
  let invariants =
    compute_invariants
      ~phase:entry.phase
      ~conds
      ~turn_phase
      ~reconcile_data
      ~reconcile_fsm
  in
  {
    correlation_id;
    run_id;
    ts;
    ksm_phase = entry.phase;
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
    reconcile_data;
    reconcile_fsm;
    invariants;
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
    "recovery_two_store_sync", `Bool inv.recovery_two_store_sync;
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
    "phase", `String (Keeper_state_machine.phase_to_string s.ksm_phase);
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
    "recovery", `Assoc [
      "data_record", `Bool s.reconcile_data;
      "fsm_condition", `Bool s.reconcile_fsm;
    ];
    "invariants", invariants_to_json s.invariants;
  ]
