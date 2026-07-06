(** task-1743 — typed "metric unevaluated" state for the goal panel.

    A goal's [metric] is stored but never evaluated: task convergence may be
    checked, but no metric measurement source turns the declared metric into an
    observed value. The dashboard attainment projection derives its percentages
    from linked task completion, not from the metric, yet labels them
    "metric_target_*" — presenting task progress as a metric result. These
    tests pin the additive typed [metric_evaluation] field that keeps the two
    apart: a declared metric is "unevaluated" regardless of how the
    task-derived attainment looks, and that is distinct from a goal with no
    metric ("absent"). *)

open Alcotest
open Masc

let iso_now () = Masc_domain.now_iso ()

let make_goal ?metric ?target_value id title =
  {
    Goal_store.id;
    title;
    metric;
    target_value;
    due_date = None;
    priority = 3;
    status = Active;
    phase = Goal_phase.Executing;
    verifier_policy = None;
    require_completion_approval = false;
    active_verification_request_id = None;
    parent_goal_id = None;
    last_review_note = None;
    last_review_at = None;
    created_at = iso_now ();
    updated_at = iso_now ();
  }

module A = Dashboard_goals_types_attainment
module Acc = Dashboard_goals_types_accessor
module Timeline = Dashboard_goals_types_timeline
module MD = Masc_domain

let json_str j key = Yojson.Safe.Util.(j |> member key |> to_string)

let json_bool j key = Yojson.Safe.Util.(j |> member key |> to_bool)

let make_done_task id : MD.task =
  {
    id;
    title = "Task " ^ id;
    description = "";
    task_status =
      MD.Done { assignee = "keeper"; completed_at = iso_now (); notes = None };
    priority = 3;
    files = [];
    created_at = iso_now ();
    created_by = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    do_not_reclaim_reason = None;
  }

let make_node ?(tasks = []) goal : Acc.tree_node =
  {
    goal;
    children = [];
    tasks = List.map (fun task -> (task, "explicit")) tasks;
    convergence = 0.0;
    health = "ok";
    badges = [];
    last_activity_at = iso_now ();
    stagnation_seconds = 0;
    linked_keeper_names = [];
    pending_approval_count = 0;
    infra_risk_count = 0;
    linkage_source = "explicit";
    linkage_warning_count = 0;
    status_reason = "";
    blocking_source = "none";
    blocking_reason = "";
    latest_keeper_ref = None;
    latest_turn_ref = None;
    stalled_since = None;
    activity_observation = "none";
    stagnation_status = "fresh";
  }

let make_keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("agent_name", `String ("agent-" ^ name))
        ; ("trace_id", `String ("trace-" ^ name))
        ; ("goal", `String "goal timeline test")
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("make_keeper_meta: " ^ err)

(* (a) A goal that declares a metric is exposed as typed "unevaluated". *)
let test_declared_metric_is_unevaluated () =
  let g = make_goal ~metric:"test coverage %" ~target_value:"80%" "g1" "cov" in
  check string "declared metric -> unevaluated" "unevaluated"
    (A.metric_evaluation_to_string (A.metric_evaluation_of_goal g))

(* A goal with no metric is "absent" — a distinct state, not "unevaluated". *)
let test_absent_metric_is_absent () =
  let g = make_goal "g2" "no metric" in
  check string "no metric -> absent" "absent"
    (A.metric_evaluation_to_string (A.metric_evaluation_of_goal g))

(* (b) Even when the attainment projection looks fully attained (state
   "attained", pct 100 from 4/4 done tasks), metric_evaluation stays
   "unevaluated": the task-derived pct is not a metric measurement. *)
let test_attained_task_pct_still_unevaluated () =
  let g = make_goal ~metric:"coverage %" ~target_value:"80%" "g3" "cov" in
  let json =
    A.build_attainment_json ~state:"attained" ~basis:"metric_target_percent"
      ~task_done_count:4 ~task_count:4 ~target_parse_status:"parseable"
      ~unit:Acc.Percent ~observed_value:(Some 100.0) ~target_numeric:(Some 80.0)
      ~attainment_pct:(Some 100)
      ~note:"Derived from linked task completion against a percent target." g
  in
  check string "task-derived state is attained" "attained" (json_str json "state");
  check string "but the metric itself is unevaluated" "unevaluated"
    (json_str json "metric_evaluation")

(* (c) A metric goal with zero done tasks is still "unevaluated", not
   conflated with a genuine measured zero: the metric was never measured. *)
let test_zero_progress_metric_unevaluated () =
  let g = make_goal ~metric:"prs merged" ~target_value:"10" "g4" "prs" in
  let json =
    A.build_attainment_json ~state:"not_started" ~basis:"metric_target_count"
      ~task_done_count:0 ~task_count:3 ~target_parse_status:"parseable"
      ~unit:Acc.Count ~observed_value:(Some 0.0) ~target_numeric:(Some 10.0)
      ~attainment_pct:(Some 0)
      ~note:"Derived from completed linked tasks against a count target." g
  in
  check string "task-derived state can be not_started" "not_started"
    (json_str json "state");
  check string "metric remains unevaluated, not a measured 0" "unevaluated"
    (json_str json "metric_evaluation")

(* A goal with no metric surfaces "absent" in the JSON projection too. *)
let test_absent_metric_in_json () =
  let g = make_goal ~target_value:"5" "g5" "count only" in
  let json =
    A.build_attainment_json ~state:"in_progress" ~basis:"metric_target_count"
      ~task_done_count:1 ~task_count:5 ~target_parse_status:"parseable"
      ~unit:Acc.Count ~observed_value:(Some 1.0) ~target_numeric:(Some 5.0)
      ~attainment_pct:(Some 20) ~note:"..." g
  in
  check string "no metric declared -> absent" "absent"
    (json_str json "metric_evaluation")

let test_unevaluated_metric_allows_fallback_completion_ready () =
  let g = make_goal ~metric:"coverage %" ~target_value:"80%" "g6" "cov" in
  let attainment =
    A.build_attainment_json ~state:"attained" ~basis:"metric_target_percent"
      ~task_done_count:2 ~task_count:2 ~target_parse_status:"parseable"
      ~unit:Acc.Percent ~observed_value:(Some 100.0) ~target_numeric:(Some 80.0)
      ~attainment_pct:(Some 100)
      ~note:"Derived from linked task completion against a percent target." g
  in
  let node =
    make_node
      ~tasks:[ make_done_task "t1"; make_done_task "t2" ]
      g
  in
  let json =
    A.goal_completion_to_json ~effective_policy:None ~open_request:None g node
      ~attainment
  in
  check string "metric stays unevaluated" "unevaluated"
    (json_str json "metric_evaluation");
  check bool "unevaluated metric allows completion via fallback" true
    (json_bool json "ready_to_request_completion");
  check string "task-derived attainment is ready_for_completion" "ready_for_completion"
    (json_str json "state")

let test_keeper_receipt_timeline_missing_runtime_stays_missing () =
  let goal = make_goal "g7" "timeline" in
  let meta = make_keeper_meta "timeline-keeper" in
  let receipt =
    `Assoc
      [ ("outcome", `String "ok")
      ; ("ended_at", `String "2026-07-06T02:00:00Z")
      ]
  in
  let detail =
    Acc.
      { meta
      ; latest_receipt = Some receipt
      ; runtime_trust = `Assoc []
      }
  in
  let events = Timeline.build_goal_timeline (make_node goal) [ detail ] [] [] in
  let receipt_event =
    List.find
      (fun event -> String.equal (json_str event "kind") "keeper_receipt")
      events
  in
  check string
    "receipt without runtime does not borrow configured runtime"
    "ok · <missing receipt.runtime.name>"
    (json_str receipt_event "summary")

let () =
  run "goal metric unevaluated"
    [
      ( "metric_evaluation",
        [
          test_case "declared metric is unevaluated" `Quick
          test_declared_metric_is_unevaluated;
          test_case "absent metric is absent" `Quick test_absent_metric_is_absent;
          test_case "attained task pct still unevaluated" `Quick
          test_attained_task_pct_still_unevaluated;
          test_case "zero progress still unevaluated" `Quick
          test_zero_progress_metric_unevaluated;
          test_case "absent metric in json" `Quick test_absent_metric_in_json;
          test_case "unevaluated metric allows fallback completion ready" `Quick
          test_unevaluated_metric_allows_fallback_completion_ready;
          test_case "receipt timeline does not fabricate runtime" `Quick
          test_keeper_receipt_timeline_missing_runtime_stays_missing;
        ] );
    ]
