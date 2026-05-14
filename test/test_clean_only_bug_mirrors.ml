(** Tests mirroring TLA+ Bug Models for clean-only specs that gained
    buggy.cfg counterparts in this PR.

    Each test reconstructs the post-bug state declared in TLA+ and
    asserts that the corresponding invariant predicate flags the
    violation.  This is the OCaml analogue of [TLC SpecBuggy] reporting
    the invariant violated.

    Helper predicates are inlined here (not added to production
    modules) — the goal is spec parity verification, not runtime
    enforcement.  Where a production guard already exists (e.g.,
    Keeper_composite_observer for KeeperCompositeLifecycle), that
    pattern is preferred.  These four specs lacked such guards. *)

(* ============================================================
   1. AmbiguousPartialCommit / BugOrphanMutations
   ============================================================ *)

type turn_phase_amb =
  | Init
  | Running_amb
  | Completed_amb
  | Failed_amb
  | Continue_gate

(* TLA+ MutationsNeverOrphan ==
     ~(turn_phase = "failed" /\ mutating_committed > 0) *)
let check_mutations_never_orphan ~(turn_phase : turn_phase_amb) ~(mutating_committed : int) =
  not (turn_phase = Failed_amb && mutating_committed > 0)
;;

let test_bug_orphan_mutations_caught () =
  let invariant_holds =
    check_mutations_never_orphan ~turn_phase:Failed_amb ~mutating_committed:1
  in
  Alcotest.(check bool)
    "MutationsNeverOrphan violated by BugOrphanMutations"
    false
    invariant_holds
;;

(* ============================================================
   2. KeeperSocialModelMagenticLedger / BugStalledWithoutCause
   ============================================================ *)

type social_phase =
  | Quiet
  | Stalled
  | Advancing
  | Reactive

(* TLA+ StalledNeedsGoalOrFailure ==
     phase = "stalled" => has_active_goals \/ failure_observed *)
let check_stalled_needs_goal_or_failure
    ~(phase : social_phase)
    ~(has_active_goals : bool)
    ~(failure_observed : bool)
  =
  match phase with
  | Stalled -> has_active_goals || failure_observed
  | _ -> true
;;

let test_bug_stalled_without_cause_caught () =
  let invariant_holds =
    check_stalled_needs_goal_or_failure
      ~phase:Stalled
      ~has_active_goals:false
      ~failure_observed:false
  in
  Alcotest.(check bool)
    "StalledNeedsGoalOrFailure violated by BugStalledWithoutCause"
    false
    invariant_holds
;;

(* ============================================================
   3. KeeperTraceSpec / BugDerivePhaseMismatch
   ============================================================ *)

type derived_phase =
  | Phase_offline
  | Phase_running
  | Phase_failing
  | Phase_overflowed
  | Phase_compacting
  | Phase_handing_off
  | Phase_draining
  | Phase_paused
  | Phase_stopped
  | Phase_crashed
  | Phase_restarting
  | Phase_dead

(* TLA+ DerivePhaseAgreement == recorded_phase = DerivePhase *)
let check_derive_phase_agreement
    ~(recorded_phase : derived_phase)
    ~(derived_phase : derived_phase)
  =
  recorded_phase = derived_phase
;;

let test_bug_derive_phase_mismatch_caught () =
  let invariant_holds =
    check_derive_phase_agreement
      ~recorded_phase:Phase_running
      ~derived_phase:Phase_offline
  in
  Alcotest.(check bool)
    "DerivePhaseAgreement violated by BugDerivePhaseMismatch"
    false
    invariant_holds
;;

(* ============================================================
   4. KeeperTurnCycle / BugSelectingWithoutToolPolicy
   ============================================================ *)

type cascade_state_tc =
  | Cs_idle
  | Cs_selecting
  | Cs_trying
  | Cs_done
  | Cs_exhausted

type turn_phase_tc =
  | Tp_idle
  | Tp_prompting
  | Tp_executing
  | Tp_compacting
  | Tp_finalizing

type decision_stage_tc =
  | Ds_undecided
  | Ds_guard_ok
  | Ds_gate_rejected
  | Ds_tool_policy_selected

(* TLA+ SelectingRequiresToolPolicy ==
     cascade_state = "selecting" =>
       turn_live /\ turn_phase = "prompting"
       /\ decision_stage = "tool_policy_selected" *)
let check_selecting_requires_tool_policy
    ~(cascade_state : cascade_state_tc)
    ~(turn_live : bool)
    ~(turn_phase : turn_phase_tc)
    ~(decision_stage : decision_stage_tc)
  =
  match cascade_state with
  | Cs_selecting ->
    turn_live && turn_phase = Tp_prompting && decision_stage = Ds_tool_policy_selected
  | _ -> true
;;

let test_bug_selecting_without_tool_policy_caught () =
  let invariant_holds =
    check_selecting_requires_tool_policy
      ~cascade_state:Cs_selecting
      ~turn_live:true
      ~turn_phase:Tp_prompting
      ~decision_stage:Ds_guard_ok
  in
  Alcotest.(check bool)
    "SelectingRequiresToolPolicy violated by BugSelectingWithoutToolPolicy"
    false
    invariant_holds
;;

(* Sanity tests — clean states must hold *)

let test_clean_holds_mutations_never_orphan () =
  Alcotest.(check bool)
    "Running with mutations is fine"
    true
    (check_mutations_never_orphan ~turn_phase:Running_amb ~mutating_committed:3);
  Alcotest.(check bool)
    "Continue_gate with mutations is fine"
    true
    (check_mutations_never_orphan ~turn_phase:Continue_gate ~mutating_committed:3);
  Alcotest.(check bool)
    "Failed with no mutations is fine"
    true
    (check_mutations_never_orphan ~turn_phase:Failed_amb ~mutating_committed:0)
;;

let test_clean_holds_stalled_with_goal () =
  Alcotest.(check bool)
    "Stalled with goal is fine"
    true
    (check_stalled_needs_goal_or_failure
       ~phase:Stalled
       ~has_active_goals:true
       ~failure_observed:false);
  Alcotest.(check bool)
    "Stalled with failure is fine"
    true
    (check_stalled_needs_goal_or_failure
       ~phase:Stalled
       ~has_active_goals:false
       ~failure_observed:true);
  Alcotest.(check bool)
    "Quiet without cause is fine"
    true
    (check_stalled_needs_goal_or_failure
       ~phase:Quiet
       ~has_active_goals:false
       ~failure_observed:false)
;;

let test_clean_holds_selecting_with_tool_policy () =
  Alcotest.(check bool)
    "Selecting with tool_policy is fine"
    true
    (check_selecting_requires_tool_policy
       ~cascade_state:Cs_selecting
       ~turn_live:true
       ~turn_phase:Tp_prompting
       ~decision_stage:Ds_tool_policy_selected);
  Alcotest.(check bool)
    "Idle cascade unconditional"
    true
    (check_selecting_requires_tool_policy
       ~cascade_state:Cs_idle
       ~turn_live:false
       ~turn_phase:Tp_idle
       ~decision_stage:Ds_undecided)
;;

(* ── Test runner ─────────────────────────────────────────── *)
let () =
  Alcotest.run
    "Clean_only_bug_mirrors"
    [ ( "AmbiguousPartialCommit"
      , [ Alcotest.test_case
            "BugOrphanMutations caught"
            `Quick
            test_bug_orphan_mutations_caught
        ; Alcotest.test_case
            "clean states hold"
            `Quick
            test_clean_holds_mutations_never_orphan
        ] )
    ; ( "KeeperSocialModelMagenticLedger"
      , [ Alcotest.test_case
            "BugStalledWithoutCause caught"
            `Quick
            test_bug_stalled_without_cause_caught
        ; Alcotest.test_case "clean states hold" `Quick test_clean_holds_stalled_with_goal
        ] )
    ; ( "KeeperTraceSpec"
      , [ Alcotest.test_case
            "BugDerivePhaseMismatch caught"
            `Quick
            test_bug_derive_phase_mismatch_caught
        ] )
    ; ( "KeeperTurnCycle"
      , [ Alcotest.test_case
            "BugSelectingWithoutToolPolicy caught"
            `Quick
            test_bug_selecting_without_tool_policy_caught
        ; Alcotest.test_case
            "clean states hold"
            `Quick
            test_clean_holds_selecting_with_tool_policy
        ] )
    ]
;;
