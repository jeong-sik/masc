(** Tests for sub-FSM runtime transition guards (PR #14153).
    Mirrors the TLA+ transition matrix in executable form.
    Valid transitions must pass; invalid transitions must raise
    [Assert_failure] and bump [masc_fsm_guard_violation_total]. *)

open Masc_mcp.Keeper_registry
module Obs = Masc_mcp.Keeper_composite_observer

(* ── KTC: turn_phase ─────────────────────────────────────── *)

let test_valid_turn_phase_transitions () =
  let cases =
    [ Turn_idle, Turn_prompting
    ; Turn_prompting, Turn_executing
    ; Turn_prompting, Turn_finalizing
    ; Turn_executing, Turn_compacting
    ; Turn_executing, Turn_finalizing
    ; Turn_compacting, Turn_prompting
    ; Turn_idle, Turn_idle
    ; Turn_prompting, Turn_prompting
    ; Turn_executing, Turn_executing
    ; Turn_compacting, Turn_compacting
    ; Turn_finalizing, Turn_finalizing
    ]
  in
  List.iter
    (fun (from, to_) ->
       try validate_turn_phase_transition ~from ~to_ with
       | Assert_failure _ ->
         Alcotest.fail
           (Printf.sprintf
              "valid turn_phase %s -> %s rejected"
              (Obs.turn_phase_to_string from)
              (Obs.turn_phase_to_string to_)))
    cases
;;

let test_invalid_turn_phase_transitions () =
  let cases =
    [ Turn_idle, Turn_executing
    ; Turn_idle, Turn_compacting
    ; Turn_idle, Turn_finalizing
    ; Turn_prompting, Turn_idle
    ; Turn_prompting, Turn_compacting
    ; Turn_executing, Turn_idle
    ; Turn_executing, Turn_prompting
    ; Turn_compacting, Turn_idle
    ; Turn_compacting, Turn_executing
    ; Turn_compacting, Turn_finalizing
    ; Turn_finalizing, Turn_idle
    ; Turn_finalizing, Turn_prompting
    ]
  in
  List.iter
    (fun (from, to_) ->
       try
         validate_turn_phase_transition ~from ~to_;
         Alcotest.fail
           (Printf.sprintf
              "invalid turn_phase %s -> %s should raise"
              (Obs.turn_phase_to_string from)
              (Obs.turn_phase_to_string to_))
       with
       | Assert_failure _ -> ())
    cases
;;

(* ── KDP: decision_stage ────────────────────────────────── *)

let test_valid_decision_transitions () =
  let cases =
    [ Decision_undecided, Decision_guard_ok
    ; Decision_undecided, Decision_gate_rejected
    ; Decision_guard_ok, Decision_tool_policy_selected
    ; Decision_undecided, Decision_undecided
    ; Decision_guard_ok, Decision_guard_ok
    ; Decision_gate_rejected, Decision_gate_rejected
    ; Decision_tool_policy_selected, Decision_tool_policy_selected
    ]
  in
  List.iter
    (fun (from, to_) ->
       try validate_decision_transition ~from ~to_ with
       | Assert_failure _ ->
         Alcotest.fail
           (Printf.sprintf
              "valid decision %s -> %s rejected"
              (Obs.decision_stage_to_string from)
              (Obs.decision_stage_to_string to_)))
    cases
;;

let test_invalid_decision_transitions () =
  let cases =
    [ Decision_undecided, Decision_tool_policy_selected
    ; Decision_guard_ok, Decision_undecided
    ; Decision_guard_ok, Decision_gate_rejected
    ; Decision_gate_rejected, Decision_undecided
    ; Decision_gate_rejected, Decision_guard_ok
    ; Decision_tool_policy_selected, Decision_undecided
    ; Decision_tool_policy_selected, Decision_guard_ok
    ]
  in
  List.iter
    (fun (from, to_) ->
       try
         validate_decision_transition ~from ~to_;
         Alcotest.fail
           (Printf.sprintf
              "invalid decision %s -> %s should raise"
              (Obs.decision_stage_to_string from)
              (Obs.decision_stage_to_string to_))
       with
       | Assert_failure _ -> ())
    cases
;;

(* ── KCL: cascade_state ─────────────────────────────────── *)

let test_valid_cascade_transitions () =
  let cases =
    [ Cascade_idle, Cascade_selecting
    ; Cascade_selecting, Cascade_trying
    ; Cascade_trying, Cascade_done
    ; Cascade_trying, Cascade_exhausted
    ; Cascade_trying, Cascade_selecting
    ; Cascade_idle, Cascade_idle
    ; Cascade_selecting, Cascade_selecting
    ; Cascade_trying, Cascade_trying
    ; Cascade_done, Cascade_done
    ; Cascade_exhausted, Cascade_exhausted
    ]
  in
  List.iter
    (fun (from, to_) ->
       try validate_cascade_transition ~from ~to_ with
       | Assert_failure _ ->
         Alcotest.fail
           (Printf.sprintf
              "valid cascade %s -> %s rejected"
              (Obs.cascade_state_to_string from)
              (Obs.cascade_state_to_string to_)))
    cases
;;

let test_invalid_cascade_transitions () =
  let cases =
    [ Cascade_idle, Cascade_trying
        (* Regression: pre-fix [Keeper_unified_turn.retry_loop] line
           1138 era marked Cascade_trying immediately after budget
           resolution, jumping past Cascade_selecting.  The fix moves
           the trying mark into the disclosure hook so the matrix
           below keeps rejecting any future re-introduction of the
           direct jump. *)
    ; Cascade_idle, Cascade_done
    ; Cascade_idle, Cascade_exhausted
    ; Cascade_selecting, Cascade_done
    ; Cascade_selecting, Cascade_exhausted
    ; Cascade_done, Cascade_idle
    ; Cascade_done, Cascade_selecting
    ; Cascade_exhausted, Cascade_idle
    ; Cascade_exhausted, Cascade_selecting
    ]
  in
  List.iter
    (fun (from, to_) ->
       try
         validate_cascade_transition ~from ~to_;
         Alcotest.fail
           (Printf.sprintf
              "invalid cascade %s -> %s should raise"
              (Obs.cascade_state_to_string from)
              (Obs.cascade_state_to_string to_))
       with
       | Assert_failure _ -> ())
    cases
;;

(* ── Cascade sequence simulations ────────────────────────── *)

(** Spec [KeeperCascadeLifecycle]/[KeeperTurnCycle] mandate the
    atomic group [SelectToolPolicy(idle->selecting) ->
    CascadeTrying(selecting->trying)] inside the disclosure hook.
    Pre-fix [Keeper_unified_turn.retry_loop] line 1138 era marked
    Cascade_trying before disclosure ran, producing the rejected
    [idle -> trying] jump that this PR removes.  These end-to-end
    sequence tests guard the full retry_loop trajectory rather than
    individual transitions.

    See [KeeperCascadeLifecycle.tla] (SelectToolPolicy /
    CascadeTrying actions) and the bug-model
    [BugCascadeBeforeMeasurement] for the formal contract. *)

let walk_cascade_sequence label seq =
  List.iter
    (fun (from, to_) ->
       try validate_cascade_transition ~from ~to_
       with Assert_failure _ ->
         Alcotest.fail
           (Printf.sprintf
              "%s step %s -> %s should pass"
              label
              (Obs.cascade_state_to_string from)
              (Obs.cascade_state_to_string to_)))
    seq
;;

let test_first_turn_attempt_sequence () =
  walk_cascade_sequence
    "first-turn attempt"
    [ Cascade_idle, Cascade_selecting
    ; Cascade_selecting, Cascade_trying
    ; Cascade_trying, Cascade_done
    ]
;;

let test_retry_attempt_sequence () =
  (* On retry the prior turn ended at [trying] (not idle).  The
     disclosure hook re-marks [selecting] then [trying]; the second
     attempt may fail and end at [exhausted]. *)
  walk_cascade_sequence
    "retry attempt"
    [ Cascade_idle, Cascade_selecting
    ; Cascade_selecting, Cascade_trying
    ; Cascade_trying, Cascade_selecting
    ; Cascade_selecting, Cascade_trying
    ; Cascade_trying, Cascade_exhausted
    ]
;;

(* ── KMC: compaction_stage ──────────────────────────────── *)

let test_valid_compaction_transitions () =
  let cases =
    [ Compaction_accumulating, Compaction_compacting
    ; Compaction_compacting, Compaction_done
    ; Compaction_compacting, Compaction_accumulating
    ; Compaction_accumulating, Compaction_accumulating
    ; Compaction_compacting, Compaction_compacting
    ; Compaction_done, Compaction_done
    ]
  in
  List.iter
    (fun (from, to_) ->
       try validate_compaction_transition ~from ~to_ with
       | Assert_failure _ ->
         Alcotest.fail
           (Printf.sprintf
              "valid compaction %s -> %s rejected"
              (Obs.compaction_stage_to_string from)
              (Obs.compaction_stage_to_string to_)))
    cases
;;

let test_invalid_compaction_transitions () =
  let cases =
    [ Compaction_accumulating, Compaction_done
    ; Compaction_done, Compaction_accumulating
    ; Compaction_done, Compaction_compacting
    ]
  in
  List.iter
    (fun (from, to_) ->
       try
         validate_compaction_transition ~from ~to_;
         Alcotest.fail
           (Printf.sprintf
              "invalid compaction %s -> %s should raise"
              (Obs.compaction_stage_to_string from)
              (Obs.compaction_stage_to_string to_))
       with
       | Assert_failure _ -> ())
    cases
;;

(* ── Test runner ────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Keeper_sub_fsm_guards"
    [ ( "turn_phase"
      , [ Alcotest.test_case
            "valid transitions"
            `Quick
            test_valid_turn_phase_transitions
        ; Alcotest.test_case
            "invalid transitions"
            `Quick
            test_invalid_turn_phase_transitions
        ] )
    ; ( "decision_stage"
      , [ Alcotest.test_case
            "valid transitions"
            `Quick
            test_valid_decision_transitions
        ; Alcotest.test_case
            "invalid transitions"
            `Quick
            test_invalid_decision_transitions
        ] )
    ; ( "cascade_state"
      , [ Alcotest.test_case
            "valid transitions"
            `Quick
            test_valid_cascade_transitions
        ; Alcotest.test_case
            "invalid transitions"
            `Quick
            test_invalid_cascade_transitions
        ] )
    ; ( "cascade_sequences"
      , [ Alcotest.test_case
            "first-turn attempt"
            `Quick
            test_first_turn_attempt_sequence
        ; Alcotest.test_case
            "retry attempt"
            `Quick
            test_retry_attempt_sequence
        ] )
    ; ( "compaction_stage"
      , [ Alcotest.test_case
            "valid transitions"
            `Quick
            test_valid_compaction_transitions
        ; Alcotest.test_case
            "invalid transitions"
            `Quick
            test_invalid_compaction_transitions
        ] )
    ]
;;
