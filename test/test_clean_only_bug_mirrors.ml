(** Tests mirroring TLA+ Bug Models for clean-only specs that gained
    buggy.cfg counterparts in this PR.

    Each test reconstructs the post-bug state declared in TLA+ and
    asserts that the corresponding invariant predicate flags the
    violation.  This is the OCaml analogue of [TLC SpecBuggy] reporting
    the invariant violated.

    Helper predicates are inlined here (not added to production
    modules) — the goal is spec parity verification, not runtime
    enforcement.  Where a production guard already exists (e.g.,
    Keeper_composite_observer), that pattern is preferred. *)

(* ============================================================
   2. KeeperTraceSpec / BugDerivePhaseMismatch
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
   3. KeeperTurnCycle / BugSelectingWithoutToolPolicy
   ============================================================ *)

type runtime_state_tc =
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
  | Ds_tool_policy_selected

(* TLA+ SelectingRequiresToolPolicy ==
     runtime_state = "selecting" =>
       turn_live /\ turn_phase = "prompting"
       /\ decision_stage = "tool_policy_selected" *)
let check_selecting_requires_tool_policy
    ~(runtime_state : runtime_state_tc)
    ~(turn_live : bool)
    ~(turn_phase : turn_phase_tc)
    ~(decision_stage : decision_stage_tc)
  =
  match runtime_state with
  | Cs_selecting ->
    turn_live && turn_phase = Tp_prompting && decision_stage = Ds_tool_policy_selected
  | _ -> true
;;

let test_bug_selecting_without_tool_policy_caught () =
  let invariant_holds =
    check_selecting_requires_tool_policy
      ~runtime_state:Cs_selecting
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

let test_clean_holds_selecting_with_tool_policy () =
  Alcotest.(check bool)
    "Selecting with tool_policy is fine"
    true
    (check_selecting_requires_tool_policy
       ~runtime_state:Cs_selecting
       ~turn_live:true
       ~turn_phase:Tp_prompting
       ~decision_stage:Ds_tool_policy_selected);
  Alcotest.(check bool)
    "Idle runtime unconditional"
    true
    (check_selecting_requires_tool_policy
       ~runtime_state:Cs_idle
       ~turn_live:false
       ~turn_phase:Tp_idle
       ~decision_stage:Ds_undecided)
;;

(* ── Test runner ─────────────────────────────────────────── *)
let () =
  Alcotest.run
    "Clean_only_bug_mirrors"
    [ ( "KeeperTraceSpec"
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
