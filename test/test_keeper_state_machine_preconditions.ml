(** Precondition, attribution, and snapshot invariant tests for
    [test_keeper_state_machine].

    This module is compiled into the [test_keeper_state_machine] executable;
    the test runner remains in [test_keeper_state_machine.ml]. *)

open Alcotest

module SM = Keeper_state_machine
module IC = Masc.Keeper_invariant_check
module A = Attribution

(** Healthy running conditions. *)
let running_conditions : SM.conditions =
  { SM.default_conditions with fiber_alive = true }
;;

(** Apply event and extract the result, failing on error. *)
let apply_ok ~current_phase ~conditions ~event =
  match SM.apply_event ~current_phase ~conditions ~event ~now:1000.0 with
  | Ok tr -> tr
  | Error e -> fail (SM.transition_error_to_string e)
;;

(** Apply event and extract the error, failing on success. *)
let apply_err ~current_phase ~conditions ~event =
  match SM.apply_event ~current_phase ~conditions ~event ~now:1000.0 with
  | Ok tr ->
    fail
      (Printf.sprintf
         "expected error but got transition %s -> %s"
         (SM.phase_to_string tr.prev_phase)
         (SM.phase_to_string tr.new_phase))
  | Error e -> e
;;

let outcome_kind_of = function
  | A.Passed -> "passed"
  | A.Policy_failed _ -> "policy_failed"
  | A.Transition_blocked _ -> "transition_blocked"
  | A.Partial_pass _ -> "partial_pass"
;;

(** Helper: pin both the variant tag and the short stable reason. *)
let expect_precondition_reason ~current_phase ~conditions ~event ~expected_reason =
  match SM.apply_event ~current_phase ~conditions ~event ~now:1000.0 with
  | Error (SM.Precondition_violation r) ->
    check string "precondition reason" expected_reason r.reason
  | Error e ->
    fail
      ("expected Precondition_violation, got " ^ SM.transition_error_to_string e)
  | Ok _ -> fail "expected Precondition_violation, got Ok"
;;

let test_attribution_ok_passed () =
  let tr =
    apply_ok
      ~current_phase:SM.Running
      ~conditions:running_conditions
      ~event:SM.Turn_succeeded
  in
  let attr = SM.attribution_of_transition ~event:SM.Turn_succeeded (Ok tr) in
  check string "gate" "keeper_fsm" attr.gate;
  check bool "origin=Det" true (attr.origin = A.Det);
  check string "outcome kind" "passed" (outcome_kind_of attr.outcome);
  (* Evidence carries event + phase info. *)
  match attr.evidence with
  | `Assoc fields ->
    check bool "evidence has event" true (List.mem_assoc "event" fields);
    check bool "evidence has from_phase" true (List.mem_assoc "from_phase" fields);
    check bool "evidence has to_phase" true (List.mem_assoc "to_phase" fields);
    check bool "evidence has timestamp" true (List.mem_assoc "timestamp" fields)
  | _ -> Alcotest.fail "evidence must be object"
;;

let test_attribution_invalid_transition_blocked () =
  (* Build a synthetic transition_error (no legitimate apply_event path
     in this FSM emits Invalid_transition outside guard violations — we
     test the converter directly). *)
  let err =
    SM.Invalid_transition
      { from_phase = SM.Running
      ; to_phase = SM.Compacting
      ; reason = "guard violation: cannot compact while running"
      }
  in
  let attr = SM.attribution_of_transition ~event:SM.Compaction_started (Error err) in
  match attr.outcome with
  | A.Transition_blocked { from_state; to_state; reason } ->
    check string "from_state" "running" from_state;
    check string "to_state" "compacting" to_state;
    check string "reason" "guard violation: cannot compact while running" reason
  | other -> Alcotest.fail ("expected Transition_blocked, got " ^ outcome_kind_of other)
;;

let test_attribution_terminal_policy_failed () =
  let terminal_cond =
    { SM.default_conditions with
      stop_requested = true
    ; fiber_alive = false
    }
  in
  let result =
    SM.apply_event
      ~current_phase:SM.Stopped
      ~conditions:terminal_cond
      ~event:SM.Heartbeat_ok
      ~now:0.0
  in
  let attr = SM.attribution_of_transition ~event:SM.Heartbeat_ok result in
  (match result with
   | Error (SM.Terminal_state _) -> ()
   | _ -> Alcotest.fail "expected Terminal_state for event on Stopped phase");
  match attr.outcome with
  | A.Policy_failed { reason } ->
    check
      bool
      "reason mentions terminal"
      true
      (Astring.String.is_infix ~affix:"terminal" reason);
    check
      bool
      "reason mentions stopped phase"
      true
      (Astring.String.is_infix ~affix:"stopped" reason)
  | other -> Alcotest.fail ("expected Policy_failed, got " ^ outcome_kind_of other)
;;

let test_attribution_gate_and_origin_invariant () =
  (* Every attribution produced by this gate must carry gate="keeper_fsm"
     and origin=Det, regardless of the outcome branch. *)
  let cases : (SM.event * (SM.transition_result, SM.transition_error) result) list =
    [ ( SM.Turn_succeeded
      , Ok
          (apply_ok
             ~current_phase:SM.Running
             ~conditions:running_conditions
             ~event:SM.Turn_succeeded) )
    ; ( SM.Compaction_started
      , Error
          (SM.Invalid_transition
             { from_phase = SM.Running; to_phase = SM.Compacting; reason = "test" }) )
    ; ( SM.Heartbeat_ok
      , Error (SM.Terminal_state { current = SM.Dead; attempted_event = "Heartbeat_ok" })
      )
    ]
  in
  List.iter
    (fun (event, result) ->
       let attr = SM.attribution_of_transition ~event result in
       check string "gate invariant" "keeper_fsm" attr.gate;
       check bool "origin=Det invariant" true (attr.origin = A.Det))
    cases
;;

let overflowed_conditions : SM.conditions =
  { running_conditions with context_overflow = true }
;;

(* [event_to_string] for payload-carrying events appends the payload
   (e.g. "context_overflow_detected(limit=...)"), so we use
   prefix match rather than equality. *)
let assert_precondition_violation ~event_name err =
  match err with
  | SM.Precondition_violation { event; reason = _ } ->
    check
      bool
      ("event name prefix " ^ event_name ^ " in " ^ event)
      true
      (Astring.String.is_prefix ~affix:event_name event)
  | other ->
    Alcotest.fail
      ("expected Precondition_violation, got " ^ SM.transition_error_to_string other)
;;

let overflow_event =
  SM.Context_overflow_detected
    { limit_tokens = Some 200_000 }
;;

let test_pre_overflow_during_compaction () =
  let c = { running_conditions with compaction_active = true } in
  let err = apply_err ~current_phase:SM.Compacting ~conditions:c ~event:overflow_event in
  assert_precondition_violation ~event_name:"context_overflow_detected" err
;;

let test_pre_auto_compact_no_overflow () =
  let err =
    apply_err
      ~current_phase:SM.Running
      ~conditions:running_conditions
      ~event:SM.Auto_compact_triggered
  in
  assert_precondition_violation ~event_name:"auto_compact_triggered" err
;;

let test_pre_auto_compact_active () =
  let c = { overflowed_conditions with compaction_active = true } in
  let err =
    apply_err ~current_phase:SM.Compacting ~conditions:c ~event:SM.Auto_compact_triggered
  in
  assert_precondition_violation ~event_name:"auto_compact_triggered" err
;;

let test_pre_auto_compact_handoff_active () =
  let c = { overflowed_conditions with handoff_active = true } in
  let err =
    apply_err ~current_phase:SM.HandingOff ~conditions:c ~event:SM.Auto_compact_triggered
  in
  assert_precondition_violation ~event_name:"auto_compact_triggered" err
;;

let test_pre_operator_compact_during_compaction () =
  let c = { running_conditions with compaction_active = true } in
  let err =
    apply_err
      ~current_phase:SM.Compacting
      ~conditions:c
      ~event:SM.Operator_compact_requested
  in
  assert_precondition_violation ~event_name:"operator_compact_requested" err
;;

let test_pre_operator_compact_during_handoff () =
  let c = { running_conditions with handoff_active = true } in
  let err =
    apply_err
      ~current_phase:SM.HandingOff
      ~conditions:c
      ~event:SM.Operator_compact_requested
  in
  assert_precondition_violation ~event_name:"operator_compact_requested" err
;;

let test_pre_operator_clear_no_extra_precondition () =
  let c = { running_conditions with context_overflow = true } in
  let clear_event =
    SM.Operator_clear_requested
      { preserve_system = false; reason = "operator escape-hatch" }
  in
  match
    SM.apply_event ~current_phase:SM.Running ~conditions:c ~event:clear_event ~now:0.0
  with
  | Ok _ -> ()
  | Error (SM.Precondition_violation { event; _ }) ->
    Alcotest.fail
      ("Operator_clear_requested escape-hatch contract violated — \
        precondition layer rejected with event=" ^ event)
  | Error _ ->
    (* Matrix or terminal errors are out of scope for this test. *)
    ()
;;

let assert_snapshot_clean phase conditions =
  match IC.check_snapshot_invariants ~phase ~conditions with
  | [] -> ()
  | vs ->
    let names = List.map (fun (v : IC.violation) -> v.property) vs in
    Alcotest.fail
      ("expected no violations, got: " ^ String.concat ", " names)
;;

let assert_snapshot_fails ~property phase conditions =
  let vs = IC.check_snapshot_invariants ~phase ~conditions in
  check
    bool
    ("snapshot reports " ^ property)
    true
    (List.exists (fun (v : IC.violation) -> v.property = property) vs)
;;

let test_snapshot_running_ok () =
  assert_snapshot_clean SM.Running running_conditions
;;

let test_snapshot_running_requires_fiber () =
  (* fiber_alive=false but recorded phase=Running — but derive_phase would
     not actually produce Running, so DerivePhaseAgreement *also* fires.
     We just confirm RunningRequiresFiber is among reported violations. *)
  let c = { running_conditions with fiber_alive = false } in
  assert_snapshot_fails ~property:"RunningRequiresFiber" SM.Running c
;;

let test_snapshot_stopped_requires_drain () =
  let c = { running_conditions with stop_requested = false; drain_complete = false } in
  assert_snapshot_fails ~property:"StoppedRequiresDrain" SM.Stopped c
;;

let test_snapshot_dead_requires_tombstone () =
  let c = { running_conditions with fiber_alive = false } in
  assert_snapshot_fails ~property:"DeadRequiresTombstone" SM.Dead c
;;

let test_snapshot_derive_disagreement () =
  let c = SM.default_conditions in
  (* derive_phase = Crashed; manually claim Running. *)
  assert_snapshot_fails ~property:"DerivePhaseAgreement" SM.Running c
;;
