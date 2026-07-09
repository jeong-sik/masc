(** RFC-keeper-proactive-wake-actionability-invariant T2 — advisory-only affordance never drives a proactive wake.

    [affordance_can_mutate] is the single source of truth for "can a keeper
    woken by this signal clear it".  This file pins:

    1. The taxonomy: [Task_audit] is the sole advisory-only affordance; every
       other affordance grants at least one task/world-state mutating tool.
    2. Consistency with [tools_for_affordance]: an affordance is advisory-only
       iff none of its tools can change task/world state (the "can clear a
       signal" axis — NOT the durable-evidence axis of [is_mutating_tool], which
       classifies Masc_workspace as non-mutating).  A future affordance added
       with only read-only tools is caught here.
    3. The wake predicate [actionable_signal_present] excludes a failed-task-only
       observation while keeping claimable and pending_verification.

    Mirrors the axis-drift guard pattern in
    [test_no_progress_loop_detector] (capability axis pinned by enumeration). *)

open Alcotest

module ATS = Masc.Keeper_agent_tool_surface
module WO = Masc.Keeper_world_observation

let all_affordances : ATS.turn_affordance list =
  [ Board_curation
  ; Board_post_or_comment
  ; Message_sweep
  ; Task_claim
  ; Task_audit
  ; Task_verify
  ]
;;

let label (aff : ATS.turn_affordance) =
  match aff with
  | Board_curation -> "Board_curation"
  | Board_post_or_comment -> "Board_post_or_comment"
  | Message_sweep -> "Message_sweep"
  | Task_claim -> "Task_claim"
  | Task_audit -> "Task_audit"
  | Task_verify -> "Task_verify"
;;

(* Tools that change task/board state and therefore can clear the signal that
   surfaced their affordance.  This is the wake-relevant "can mutate" axis,
   distinct from the durable-evidence oracle [is_mutating_tool] (which treats
   Masc_workspace as non-mutating). *)
let signal_clearing_tools =
  [ "keeper_task_claim"
  ; "keeper_task_done"
  ; "masc_transition"
  ; "keeper_board_post"
  ; "keeper_board_comment"
  ; "masc_broadcast"
  ; "keeper_board_curation_submit"
  ; "masc_messages"
  ; "masc_keeper_msg"
  ]
;;

(* The taxonomy: only Task_audit is advisory-only. *)
let test_affordance_can_mutate_taxonomy () =
  List.iter
    (fun aff ->
      let expected = (match aff with ATS.Task_audit -> false | _ -> true) in
      Alcotest.(check bool)
        (label aff ^ " affordance_can_mutate")
        expected
        (ATS.affordance_can_mutate aff))
    all_affordances
;;

(* affordance_can_mutate must agree with whether tools_for_affordance grants a
   signal-clearing tool.  Drift (e.g. a read-only tool added to a mutating
   affordance, or vice versa) fails here. *)
let test_affordance_can_mutate_consistent_with_tools () =
  List.iter
    (fun aff ->
      let tools = ATS.tools_for_affordance aff in
      let has_clearing_tool =
        List.exists (fun t -> List.mem t signal_clearing_tools) tools
      in
      Alcotest.(check bool)
        (label aff ^ " mutate matches tool surface")
        has_clearing_tool
        (ATS.affordance_can_mutate aff))
    all_affordances
;;

(* RFC-0323 G-4: a verify turn must be able to clear pending_verification.
   Only masc_transition can act on awaiting_verification (action=approve /
   reject); keeper_task_done hardcodes action="done", which the FSM rejects
   there, so its presence on the verify surface burned turns on
   guaranteed-invalid transitions. *)
let test_task_verify_surface_can_approve () =
  let tools = ATS.tools_for_affordance ATS.Task_verify in
  Alcotest.(check bool)
    "Task_verify grants masc_transition" true
    (List.mem "masc_transition" tools);
  Alcotest.(check bool)
    "Task_verify does not grant keeper_task_done" false
    (List.mem "keeper_task_done" tools);
  let preferred = ATS.preferred_tool_names_for_turn_affordances [ "task_verify" ] in
  Alcotest.(check (list string))
    "verify-turn preferred tools are exactly the approve-capable one"
    [ "masc_transition" ]
    preferred
;;

let base_obs : WO.world_observation =
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = 0
  ; active_goals = []
  ; continuity_summary = ""
  ; context_ratio = lazy 0.0
  ; unclaimed_task_count = 0
  ; claimable_task_count = 0
  ; provider_capacity_blocked_task_count = 0
  ; failed_task_count = 0
  ; pending_verification_count = 0
  ; scheduled_automation = WO.empty_scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous = false
  ; running_keeper_fiber_count = 1
  ; connected_surfaces = []
  }
;;

(* The wake predicate must drop a failed-task-only observation (advisory-only
   Task_audit) while keeping claimable (Task_claim) and verification
   (Task_verify). *)
let test_actionable_signal_excludes_failed_only () =
  Alcotest.(check bool)
    "failed-only is NOT an actionable signal"
    false
    (WO.actionable_signal_present { base_obs with failed_task_count = 2 });
  Alcotest.(check bool)
    "claimable IS an actionable signal"
    true
    (WO.actionable_signal_present { base_obs with claimable_task_count = 1 });
  Alcotest.(check bool)
    "pending_verification IS an actionable signal"
    true
    (WO.actionable_signal_present { base_obs with pending_verification_count = 1 })
;;

let () =
  run "advisory_only_affordance_never_drives_wake"
    [ ( "taxonomy"
      , [ test_case "only Task_audit is advisory-only" `Quick
            test_affordance_can_mutate_taxonomy
        ; test_case "mutate matches tool surface" `Quick
            test_affordance_can_mutate_consistent_with_tools
        ; test_case "verify surface can approve (RFC-0323 G-4)" `Quick
            test_task_verify_surface_can_approve
        ] )
    ; ( "wake_predicate"
      , [ test_case "actionable_signal_present excludes failed-only" `Quick
            test_actionable_signal_excludes_failed_only
        ] )
    ]
;;
