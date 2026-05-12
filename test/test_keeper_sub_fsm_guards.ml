(** Tests for sub-FSM runtime transition guards (PR #14153).
    Mirrors the TLA+ transition matrix in executable form.
    Valid transitions must pass; forbidden transitions for [cascade_state]
    and [turn_phase] raise the typed [Cascade_transition_violation] /
    [Turn_phase_transition_violation] (RFC-0072 Phase 5) carrying the
    spec-violation payload, and bump [masc_fsm_guard_violation_total].
    [decision_stage] forbidden transitions are unrepresentable at the
    call site ([decision_stage_active] [to_] type) — a compile-time
    invariant, not a runtime check.  [compaction_stage] still raises
    [Assert_failure] (the resolver pattern has not reached that axis). *)

open Masc_mcp.Keeper_registry
module Obs = Masc_mcp.Keeper_composite_observer

(* ── KTC: turn_phase ─────────────────────────────────────── *)

let test_valid_turn_phase_transitions () =
  let cases : (packed_turn_phase * packed_turn_phase) list =
    [ (* from Turn_idle *)
      Packed Turn_idle, Packed Turn_idle
    ; Packed Turn_idle, Packed Turn_prompting (* from Turn_prompting *)
    ; Packed Turn_prompting, Packed Turn_prompting
    ; Packed Turn_prompting, Packed Turn_routing
    ; Packed Turn_prompting, Packed Turn_executing
    ; Packed Turn_prompting, Packed Turn_finalizing
    ; Packed Turn_prompting, Packed Turn_exhausted
      (* mark_terminal_error before any cascade attempt *)
      (* from Turn_routing *)
    ; Packed Turn_routing, Packed Turn_prompting
    ; Packed Turn_routing, Packed Turn_routing
    ; Packed Turn_routing, Packed Turn_executing
    ; Packed Turn_routing, Packed Turn_exhausted
      (* mark_terminal_error during cascade-fallback model selection *)
      (* from Turn_executing *)
    ; Packed Turn_executing, Packed Turn_prompting
    ; Packed Turn_executing, Packed Turn_routing
    ; Packed Turn_executing, Packed Turn_executing
    ; Packed Turn_executing, Packed Turn_compacting
    ; Packed Turn_executing, Packed Turn_finalizing
    ; Packed Turn_executing, Packed Turn_exhausted (* from Turn_compacting *)
    ; Packed Turn_compacting, Packed Turn_prompting
    ; Packed Turn_compacting, Packed Turn_compacting
    ; Packed Turn_compacting, Packed Turn_finalizing
    ; Packed Turn_compacting, Packed Turn_exhausted (* from Turn_finalizing *)
    ; Packed Turn_finalizing, Packed Turn_prompting
    ; Packed Turn_finalizing, Packed Turn_routing
    ; Packed Turn_finalizing, Packed Turn_executing
    ; Packed Turn_finalizing, Packed Turn_finalizing
    ; Packed Turn_finalizing, Packed Turn_exhausted (* from Turn_exhausted *)
    ; Packed Turn_exhausted, Packed Turn_prompting
    ; Packed Turn_exhausted, Packed Turn_routing
    ; Packed Turn_exhausted, Packed Turn_executing
    ; Packed Turn_exhausted, Packed Turn_exhausted
    ]
  in
  List.iter
    (fun (from, to_) ->
       try validate_turn_phase_transition ~from ~to_ with
       | Assert_failure _ | Turn_phase_transition_violation _ ->
         Alcotest.fail
           (Printf.sprintf
              "valid turn_phase %s -> %s rejected"
              (Obs.turn_phase_to_string from)
              (Obs.turn_phase_to_string to_)))
    cases
;;

let test_invalid_turn_phase_transitions () =
  let cases : (packed_turn_phase * packed_turn_phase) list =
    [ (* from Turn_idle *)
      Packed Turn_idle, Packed Turn_routing
    ; Packed Turn_idle, Packed Turn_executing
    ; Packed Turn_idle, Packed Turn_compacting
    ; Packed Turn_idle, Packed Turn_finalizing
    ; Packed Turn_idle, Packed Turn_exhausted (* from Turn_prompting *)
    ; Packed Turn_prompting, Packed Turn_idle
    ; Packed Turn_prompting, Packed Turn_compacting (* from Turn_routing *)
    ; Packed Turn_routing, Packed Turn_idle
    ; Packed Turn_routing, Packed Turn_compacting
    ; Packed Turn_routing, Packed Turn_finalizing (* from Turn_executing *)
    ; Packed Turn_executing, Packed Turn_idle (* from Turn_compacting *)
    ; Packed Turn_compacting, Packed Turn_idle
    ; Packed Turn_compacting, Packed Turn_routing
    ; Packed Turn_compacting, Packed Turn_executing (* from Turn_finalizing *)
    ; Packed Turn_finalizing, Packed Turn_idle
    ; Packed Turn_finalizing, Packed Turn_compacting (* from Turn_exhausted *)
    ; Packed Turn_exhausted, Packed Turn_idle
    ; Packed Turn_exhausted, Packed Turn_compacting
    ; Packed Turn_exhausted, Packed Turn_finalizing
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
       (* RFC-0072 Phase 5: forbidden pairs raise the typed exception, not
          a generic [Invalid_argument].  The payload's endpoints must match
          the pair under test. *)
       | Turn_phase_transition_violation { from = ef; to_ = et; _ } ->
         Alcotest.(check string)
           "violation.from matches"
           (packed_turn_phase_label from)
           (packed_turn_phase_label ef);
         Alcotest.(check string)
           "violation.to_ matches"
           (packed_turn_phase_label to_)
           (packed_turn_phase_label et))
    cases
;;

(* ── KDP: decision_stage ────────────────────────────────── *)

(* PR #14887 + this PR moved decision_stage forbidden transitions into the
   type system via [decision_stage_active] as the [to_] argument:
   [<active>_to_undecided] pairs are unrepresentable, so the prior
   [test_invalid_decision_transitions] and [test_decision_message_includes_labels]
   cases are gone (their contracts are now compile-time invariants — the only
   "test" that can fail is the build itself).  This remaining valid-transitions
   case enumerates the 12 admitted [(from, to_active)] pairs so that adding a
   new [decision_stage] / [decision_stage_active] constructor will fail
   compilation here, forcing a deliberate classification. *)
let test_valid_decision_transitions () =
  let cases : (decision_stage * decision_stage_active) list =
    [ (* from Decision_undecided *)
      Decision_undecided, Decision_active_guard_ok
    ; Decision_undecided, Decision_active_gate_rejected
    ; Decision_undecided, Decision_active_tool_policy_selected
      (* from Decision_guard_ok *)
    ; Decision_guard_ok, Decision_active_guard_ok
    ; Decision_guard_ok, Decision_active_gate_rejected
    ; Decision_guard_ok, Decision_active_tool_policy_selected
      (* from Decision_gate_rejected *)
    ; Decision_gate_rejected, Decision_active_guard_ok
    ; Decision_gate_rejected, Decision_active_gate_rejected
    ; Decision_gate_rejected, Decision_active_tool_policy_selected
      (* from Decision_tool_policy_selected *)
    ; Decision_tool_policy_selected, Decision_active_guard_ok
    ; Decision_tool_policy_selected, Decision_active_gate_rejected
    ; Decision_tool_policy_selected, Decision_active_tool_policy_selected
    ]
  in
  List.iter
    (fun (from, to_) ->
       try validate_decision_transition ~from ~to_ with
       | Assert_failure _ | Invalid_argument _ ->
         Alcotest.fail
           (Printf.sprintf
              "valid decision %s rejected"
              (Obs.decision_stage_to_string (stage_to_witness from))))
    cases
;;

(* ── KCL: cascade_state ─────────────────────────────────── *)

let test_valid_cascade_transitions () =
  let cases : (packed_cascade_state * packed_cascade_state) list =
    [ (* from Cascade_idle *)
      Packed Cascade_idle, Packed Cascade_idle
    ; Packed Cascade_idle, Packed Cascade_selecting (* from Cascade_selecting *)
    ; Packed Cascade_selecting, Packed Cascade_idle
    ; Packed Cascade_selecting, Packed Cascade_selecting
    ; Packed Cascade_selecting, Packed Cascade_trying (* from Cascade_trying *)
    ; Packed Cascade_trying, Packed Cascade_idle
    ; Packed Cascade_trying, Packed Cascade_selecting
    ; Packed Cascade_trying, Packed Cascade_trying
    ; Packed Cascade_trying, Packed Cascade_done
    ; Packed Cascade_trying, Packed Cascade_exhausted (* from Cascade_done *)
    ; Packed Cascade_done, Packed Cascade_idle
    ; Packed Cascade_done, Packed Cascade_selecting
    ; Packed Cascade_done, Packed Cascade_trying
    ; Packed Cascade_done, Packed Cascade_done (* from Cascade_exhausted *)
    ; Packed Cascade_exhausted, Packed Cascade_idle
    ; Packed Cascade_exhausted, Packed Cascade_selecting
    ; Packed Cascade_exhausted, Packed Cascade_trying
    ; Packed Cascade_exhausted, Packed Cascade_exhausted
    ]
  in
  List.iter
    (fun (from, to_) ->
       try validate_cascade_transition ~from ~to_ with
       | Assert_failure _ | Cascade_transition_violation _ ->
         Alcotest.fail
           (Printf.sprintf
              "valid cascade %s -> %s rejected"
              (Obs.cascade_state_to_string from)
              (Obs.cascade_state_to_string to_)))
    cases
;;

let test_invalid_cascade_transitions () =
  let cases : (packed_cascade_state * packed_cascade_state) list =
    [ (* from Cascade_idle *)
      Packed Cascade_idle, Packed Cascade_trying
      (* Regression: pre-fix [Keeper_unified_turn.retry_loop] line
           1138 era marked Cascade_trying immediately after budget
           resolution, jumping past Cascade_selecting.  The fix moves
           the trying mark into the disclosure hook so the matrix
           below keeps rejecting any future re-introduction of the
           direct jump. *)
    ; Packed Cascade_idle, Packed Cascade_done
    ; Packed Cascade_idle, Packed Cascade_exhausted (* from Cascade_selecting *)
    ; Packed Cascade_selecting, Packed Cascade_done
    ; Packed Cascade_selecting, Packed Cascade_exhausted (* from Cascade_done *)
    ; Packed Cascade_done, Packed Cascade_exhausted (* from Cascade_exhausted *)
    ; Packed Cascade_exhausted, Packed Cascade_done
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
       (* RFC-0072 Phase 5: forbidden pairs raise the typed exception. *)
       | Cascade_transition_violation { from = ef; to_ = et; _ } ->
         Alcotest.(check string)
           "violation.from matches"
           (packed_cascade_state_label from)
           (packed_cascade_state_label ef);
         Alcotest.(check string)
           "violation.to_ matches"
           (packed_cascade_state_label to_)
           (packed_cascade_state_label et))
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
       try validate_cascade_transition ~from ~to_ with
       | Assert_failure _ | Cascade_transition_violation _ ->
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
    [ Packed Cascade_idle, Packed Cascade_selecting
    ; Packed Cascade_selecting, Packed Cascade_trying
    ; Packed Cascade_trying, Packed Cascade_done
    ]
;;

let test_retry_attempt_sequence () =
  (* On retry the prior turn ended at [trying] (not idle).  The
     disclosure hook re-marks [selecting] then [trying]; the second
     attempt may fail and end at [exhausted]. *)
  walk_cascade_sequence
    "retry attempt"
    [ Packed Cascade_idle, Packed Cascade_selecting
    ; Packed Cascade_selecting, Packed Cascade_trying
    ; Packed Cascade_trying, Packed Cascade_selecting
    ; Packed Cascade_selecting, Packed Cascade_trying
    ; Packed Cascade_trying, Packed Cascade_exhausted
    ]
;;

(* ── KMC: compaction_stage ──────────────────────────────── *)

let test_valid_compaction_transitions () =
  let cases : (packed_compaction_stage * packed_compaction_stage) list =
    [ Packed Compaction_accumulating, Packed Compaction_compacting
    ; Packed Compaction_compacting, Packed Compaction_done
    ; Packed Compaction_compacting, Packed Compaction_accumulating
    ; Packed Compaction_accumulating, Packed Compaction_accumulating
    ; Packed Compaction_compacting, Packed Compaction_compacting
    ; Packed Compaction_done, Packed Compaction_done
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
  let cases : (packed_compaction_stage * packed_compaction_stage) list =
    [ Packed Compaction_accumulating, Packed Compaction_done
    ; Packed Compaction_done, Packed Compaction_accumulating
    ; Packed Compaction_done, Packed Compaction_compacting
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

(* ── Typed violation payload + Printexc rendering ────────── *)

let contains haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  if n_len = 0
  then true
  else if n_len > h_len
  then false
  else (
    let rec loop i =
      if i + n_len > h_len
      then false
      else if String.sub haystack i n_len = needle
      then true
      else loop (i + 1)
    in
    loop 0)
;;

let assert_str_contains ~haystack ~needle =
  Alcotest.(check bool)
    (Printf.sprintf "%S contains %S" haystack needle)
    true
    (contains haystack needle)
;;

let test_turn_phase_violation_payload () =
  (* Turn_routing -> Turn_compacting is a forbidden pair (you cannot
     compact while still routing).  The handler can pattern-match the
     typed [violation] constructor directly; the [Printexc] printer
     still renders a human-readable line for log output. *)
  let from : packed_turn_phase = Packed Turn_routing in
  let to_ : packed_turn_phase = Packed Turn_compacting in
  match validate_turn_phase_transition ~from ~to_ with
  | () -> Alcotest.fail "validator should have raised Turn_phase_transition_violation"
  | exception Turn_phase_transition_violation { where; from = ef; to_ = et; violation } ->
    Alcotest.(check string)
      "where names the validator"
      "validate_turn_phase_transition"
      where;
    Alcotest.(check string)
      "violation.from"
      (packed_turn_phase_label from)
      (packed_turn_phase_label ef);
    Alcotest.(check string)
      "violation.to_"
      (packed_turn_phase_label to_)
      (packed_turn_phase_label et);
    Alcotest.(check string)
      "violation tag"
      "routing->compacting"
      (turn_phase_transition_spec_violation_to_tag violation);
    let rendered =
      Printexc.to_string
        (Turn_phase_transition_violation { where; from = ef; to_ = et; violation })
    in
    assert_str_contains ~haystack:rendered ~needle:"validate_turn_phase_transition";
    assert_str_contains ~haystack:rendered ~needle:(packed_turn_phase_label from);
    assert_str_contains ~haystack:rendered ~needle:(packed_turn_phase_label to_)
;;

(* test_decision_message_includes_labels removed: validate_decision_transition
   no longer raises (the forbidden [<active>_to_undecided] pairs are
   unrepresentable through the [decision_stage_active] [to_] type). *)

let test_cascade_violation_payload () =
  let from : packed_cascade_state = Packed Cascade_idle in
  let to_ : packed_cascade_state = Packed Cascade_exhausted in
  match validate_cascade_transition ~from ~to_ with
  | () -> Alcotest.fail "validator should have raised Cascade_transition_violation"
  | exception Cascade_transition_violation { where; from = ef; to_ = et; violation } ->
    Alcotest.(check string)
      "where names the validator"
      "validate_cascade_transition"
      where;
    Alcotest.(check string)
      "violation.from"
      (packed_cascade_state_label from)
      (packed_cascade_state_label ef);
    Alcotest.(check string)
      "violation.to_"
      (packed_cascade_state_label to_)
      (packed_cascade_state_label et);
    Alcotest.(check string)
      "violation tag"
      "idle->exhausted"
      (cascade_transition_spec_violation_to_tag violation);
    let rendered =
      Printexc.to_string
        (Cascade_transition_violation { where; from = ef; to_ = et; violation })
    in
    assert_str_contains ~haystack:rendered ~needle:"validate_cascade_transition";
    assert_str_contains ~haystack:rendered ~needle:(packed_cascade_state_label from);
    assert_str_contains ~haystack:rendered ~needle:(packed_cascade_state_label to_)
;;

(* ── Test runner ────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Keeper_sub_fsm_guards"
    [ ( "turn_phase"
      , [ Alcotest.test_case "valid transitions" `Quick test_valid_turn_phase_transitions
        ; Alcotest.test_case
            "invalid transitions"
            `Quick
            test_invalid_turn_phase_transitions
        ] )
    ; ( "decision_stage"
      , [ Alcotest.test_case "valid transitions" `Quick test_valid_decision_transitions
          (* "invalid transitions" case removed: forbidden
             [<active>_to_undecided] pairs are unrepresentable through the
             [decision_stage_active] [to_] type — the test would not
             compile.  Compile-time enforcement supersedes runtime test. *)
        ] )
    ; ( "cascade_state"
      , [ Alcotest.test_case "valid transitions" `Quick test_valid_cascade_transitions
        ; Alcotest.test_case "invalid transitions" `Quick test_invalid_cascade_transitions
        ] )
    ; ( "cascade_sequences"
      , [ Alcotest.test_case "first-turn attempt" `Quick test_first_turn_attempt_sequence
        ; Alcotest.test_case "retry attempt" `Quick test_retry_attempt_sequence
        ] )
    ; ( "compaction_stage"
      , [ Alcotest.test_case "valid transitions" `Quick test_valid_compaction_transitions
        ; Alcotest.test_case
            "invalid transitions"
            `Quick
            test_invalid_compaction_transitions
        ] )
    ; ( "typed_violation_payload"
      , [ Alcotest.test_case
            "turn_phase violation carries typed payload + Printexc text"
            `Quick
            test_turn_phase_violation_payload
          (* "decision rejection" removed: validate_decision_transition no
             longer raises (the forbidden pairs are unrepresentable, see
             runner note above). *)
        ; Alcotest.test_case
            "cascade violation carries typed payload + Printexc text"
            `Quick
            test_cascade_violation_payload
        ] )
    ]
;;
