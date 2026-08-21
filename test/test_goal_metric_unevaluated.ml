(** task-1743 — typed "metric unevaluated" state for the goal panel.

    A goal's [metric] is stored but never evaluated: linked Task completion may be
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
    phase = Goal_phase.Executing;
    last_review_note = None;
    last_review_at = None;
    created_at = iso_now ();
    updated_at = iso_now ();
  }

module A = Dashboard_goals_types_attainment
module Acc = Dashboard_goals_types_accessor
module B = Dashboard_goals_types_builder
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
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    execution_links = Masc_domain.no_execution_links;
    do_not_reclaim_reason = None;
  }

let make_node ?(tasks = []) goal : Acc.tree_node =
  {
    goal;
    children = [];
    tasks;
    last_activity_at = iso_now ();
    stagnation_seconds = Some 0;
    linked_keeper_names = [];
    pending_approval_count = 0;
    latest_keeper_ref = None;
    latest_turn_ref = None;
    activity_observation = "none";
  }

let make_keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ ("name", `String name)
        ; ("agent_name", `String (Masc.Keeper_identity.keeper_agent_name name))
        ; ("trace_id", `String ("trace-" ^ name))
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("make_keeper_meta: " ^ err)

let empty_build_context ?(pending_approvals = []) now_ts : B.build_context =
  {
    now_ts;
    all_tasks = [];
    pending_approvals;
    keeper_metas = [];
    latest_receipts = [];
    latest_runtime_trusts = [];
    goal_task_index = Hashtbl.create 0;
  }

let test_goal_projection_surfaces_invalid_activity_time () =
  let goal =
    { (make_goal "invalid-time" "Invalid time") with updated_at = "invalid" }
  in
  let node = B.build_tree (empty_build_context 2.0) [ goal ] goal in
  check (option int) "invalid time has no fabricated idle duration" None
    node.stagnation_seconds;
  check string "invalid time is explicit" "unavailable"
    node.activity_observation

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

let test_unevaluated_metric_is_display_only_for_completion () =
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
    A.goal_completion_to_json g node
      ~attainment
  in
  check string "metric stays unevaluated" "unevaluated"
    (json_str json "metric_evaluation");
  check bool "unevaluated metric does not gate completion" true
    (json_bool json "ready_to_request_completion");
  check string "executing goal is completion-ready" "ready_for_completion"
    (json_str json "state")

(* The unit comes from the target value, not from English nouns in the metric
   name. A Korean metric that ends in 수 (count) with a numeric target is
   measured as a count; the removed word list required one of
   task/todo/issue/ticket/pr/done to appear as an ASCII token, and this
   metric tokenizes to ["end"; "to"; "end"], so it reported
   [unsupported_metric] instead. *)
let test_korean_count_metric_is_measured () =
  let g =
    make_goal ~metric:"end-to-end 설계+구현 완료 서비스 수" ~target_value:"1개 이상"
      "g-ko" "korean count goal"
  in
  let node = make_node ~tasks:[ make_done_task "t1" ] g in
  let json = A.goal_attainment_to_json g node in
  check string "count target is measured" "metric_target_count"
    (json_str json "basis");
  check string "unit is a count" "count" (json_str json "unit");
  check string "target parsed" "parseable" (json_str json "target_parse_status")

(* A metric name whose words used to imply a percentage no longer does. Only
   the target value's own marker selects [Percent]. *)
let test_metric_word_does_not_select_percent () =
  let g =
    make_goal ~metric:"weekly completion rate" ~target_value:"12" "g-rate"
      "rate-named goal"
  in
  let node = make_node ~tasks:[ make_done_task "t1" ] g in
  let json = A.goal_attainment_to_json g node in
  check string "unit follows the target value" "count" (json_str json "unit");
  let pct_goal =
    make_goal ~metric:"weekly completion rate" ~target_value:"80%" "g-pct"
      "percent target"
  in
  let pct_json = A.goal_attainment_to_json pct_goal (make_node ~tasks:[ make_done_task "t1" ] pct_goal) in
  check string "an explicit percent target still selects percent" "percent"
    (json_str pct_json "unit")

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

let test_goals_tree_preserves_approval_queue_unavailable () =
  let base_path = "/tmp/masc-goals-approval-unavailable" in
  let config = Masc.Workspace.default_config base_path in
  let requested_base_path = ref None in
  let read_pending ~base_path =
    requested_base_path := Some base_path;
    let error : Masc.Keeper_approval_queue.storage_error =
      {
        path = Filename.concat base_path ".masc/keeper_approval_queue.json";
        reason = "injected queue read failure";
      }
    in
    Error error
  in
  let json =
    Dashboard_goals.For_testing
    .dashboard_goals_tree_json_with_pending_reader
      ~read_pending ~config
  in
  check (option string) "uses the requested workspace" (Some base_path)
    !requested_base_path;
  let state =
    match Yojson.Safe.Util.member "approval_queue_state" json with
    | `Assoc _ as state -> state
    | _ -> fail "approval queue state must be an object"
  in
  check string "queue is unavailable" "unavailable"
    (json_str state "state");
  check string "queue severity is bad" "bad"
    (json_str state "severity");
  check bool "tree is not synthesized" true
    (Yojson.Safe.Util.member "tree" json = `Null);
  check bool "summary is not synthesized" true
    (Yojson.Safe.Util.member "summary" json = `Null)

(* A cancellation that has aged out of the execution payload's window reaches
   the Work surface through this tree alone. Emitting only status left the card
   as a bare "cancelled" with no actor and no explanation, while the status it
   was built from carries both. [reason] is emitted only when the canceller
   gave one, so an unexplained cancellation stays distinguishable from one
   whose stated reason was empty. *)
let cancelled_task id ~reason : MD.task =
  { (make_done_task id) with
    task_status =
      MD.Cancelled
        { cancelled_by = "keeper-rondo-agent"; cancelled_at = iso_now (); reason }
  }

let tree_field name json =
  match json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

(* The explanation may have arrived on the handoff context rather than the
   status field, and this payload carries no handoff_context for the reader to
   fall back through. Serializing only [Cancelled.reason] left the card blank
   for exactly the cancellations the broadcast and the author wake explain. *)
let cancelled_with_handoff id ~handoff_reason ~summary : MD.task =
  { (make_done_task id) with
    task_status =
      MD.Cancelled
        { cancelled_by = "keeper-rondo-agent"; cancelled_at = iso_now (); reason = None }
  ; handoff_context =
      Some
        { MD.summary
        ; MD.reason = handoff_reason
        ; next_step = None
        ; failure_mode = None
        ; reclaim_policy = None
        ; evidence_refs = []
        ; updated_at = None
        ; updated_by = None
        }
  }

let test_tree_task_falls_through_to_the_handoff_reason () =
  let json =
    Timeline.task_to_tree_json
      (cancelled_with_handoff "task-handoff" ~handoff_reason:(Some "sandbox lacks the service")
          ~summary:"returning to backlog"
)
  in
  check (option string) "the handoff reason is projected" (Some "sandbox lacks the service")
    (match tree_field "reason" json with Some (`String v) -> Some v | _ -> None)

let test_tree_task_falls_through_to_the_handoff_summary () =
  let json =
    Timeline.task_to_tree_json
      (cancelled_with_handoff "task-summary" ~handoff_reason:None
          ~summary:"returning to backlog until the sandbox ships it"
)
  in
  check (option string) "the handoff summary is projected"
    (Some "returning to backlog until the sandbox ships it")
    (match tree_field "reason" json with Some (`String v) -> Some v | _ -> None)

let test_tree_task_carries_the_cancellation_actor_and_reason () =
  let json = Timeline.task_to_tree_json (cancelled_task "task-aged" ~reason:(Some "superseded by G-2")) in
  check (option string) "the canceller is projected" (Some "keeper-rondo-agent")
    (match tree_field "cancelled_by" json with Some (`String v) -> Some v | _ -> None);
  check (option string) "the reason is projected" (Some "superseded by G-2")
    (match tree_field "reason" json with Some (`String v) -> Some v | _ -> None)

let test_tree_task_omits_an_absent_cancellation_reason () =
  let json = Timeline.task_to_tree_json (cancelled_task "task-bare" ~reason:None) in
  check bool "the canceller is still projected" true
    (Option.is_some (tree_field "cancelled_by" json));
  check bool "no reason field when none was given" false
    (Option.is_some (tree_field "reason" json))

let test_tree_task_without_cancellation_carries_no_cancellation_fields () =
  let json = Timeline.task_to_tree_json (make_done_task "task-done") in
  check bool "no canceller on a completed task" false
    (Option.is_some (tree_field "cancelled_by" json));
  check bool "no reason on a completed task" false
    (Option.is_some (tree_field "reason" json))

(* #29117 — the lifecycle phase is not a measurement.

   [goal_attainment_to_json] used to special-case [Completed] with
   [basis "goal_phase"], a hardcoded observed 100.0 and [attainment_pct]
   100. Since [request_complete] requires no judgment and no evidence,
   completing a goal produced the very number that justified completing it,
   and the OTel gauges reported [measured = 1] for a goal nobody measured.

   The phase is already projected on its own axis by
   [goal_completion_to_json] ("state", "is_complete"), so attainment now
   answers only from linked evidence, whatever the phase. *)

let make_todo_task id : MD.task =
  { (make_done_task id) with task_status = MD.Todo }

let json_int_opt j key =
  match Yojson.Safe.Util.member key j with
  | `Int n -> Some n
  | _ -> None

let completed (goal : Goal_store.goal) : Goal_store.goal =
  { goal with phase = Goal_phase.Completed }

(* A completed goal whose only linked task never finished reports the
   evidence, not the phase. Before the fix this answered 100%. *)
let test_completed_goal_does_not_fabricate_attainment () =
  let g = completed (make_goal "g-29117-a" "completed with unfinished work") in
  let node = make_node ~tasks:[ make_todo_task "t1" ] g in
  let json = A.goal_attainment_to_json g node in
  check (option int) "0 of 1 done is 0%, not 100%" (Some 0)
    (json_int_opt json "attainment_pct");
  check string "basis names the evidence, not the phase" "linked_tasks"
    (json_str json "basis");
  check string "state follows the evidence" "not_started" (json_str json "state")

(* Partial evidence survives completion instead of being rounded up. *)
let test_completed_goal_reports_partial_evidence () =
  let g = completed (make_goal "g-29117-b" "completed at 3 of 4") in
  let node =
    make_node
      ~tasks:
        [ make_done_task "t1"; make_done_task "t2"; make_done_task "t3"
        ; make_todo_task "t4" ]
      g
  in
  let json = A.goal_attainment_to_json g node in
  check (option int) "3 of 4 done is 75%" (Some 75)
    (json_int_opt json "attainment_pct");
  check string "state is in_progress even though the goal is completed"
    "in_progress" (json_str json "state")

(* No linked evidence and no target is "unmeasured". This is what keeps the
   OTel [goal_attainment_measured] gauge at 0 rather than claiming a
   measurement that never happened. *)
let test_completed_goal_without_evidence_is_unmeasured () =
  let g = completed (make_goal "g-29117-c" "completed with no evidence") in
  let json = A.goal_attainment_to_json g (make_node g) in
  check (option int) "no evidence yields no percentage" None
    (json_int_opt json "attainment_pct");
  check string "state is unmeasured" "unmeasured" (json_str json "state");
  check string "basis is unmeasured" "unmeasured" (json_str json "basis")

(* Completion is still visible — on the axis that owns it. *)
let test_completion_summary_still_reports_the_phase () =
  let g = completed (make_goal "g-29117-d" "completed with unfinished work") in
  let node = make_node ~tasks:[ make_todo_task "t1" ] g in
  let attainment = A.goal_attainment_to_json g node in
  let json = A.goal_completion_to_json g node ~attainment in
  check string "lifecycle state is still completed" "completed"
    (json_str json "state");
  check bool "is_complete is still true" true (json_bool json "is_complete");
  check string "and the attainment axis disagrees, which is the point"
    "not_started"
    (json_str json "attainment_state")

(* Regression guard: no phase may reintroduce a phase-derived basis. *)
let test_no_phase_derived_basis () =
  List.iter
    (fun phase ->
      let g : Goal_store.goal =
        { (make_goal "g-29117-e" "phase sweep") with phase }
      in
      let node = make_node ~tasks:[ make_todo_task "t1" ] g in
      let basis = json_str (A.goal_attainment_to_json g node) "basis" in
      check bool
        (Printf.sprintf "%s does not derive attainment from the phase"
           (Goal_phase.to_string phase))
        false
        (String.equal basis "goal_phase"))
    Goal_phase.all

(* An executing goal with complete evidence is unchanged. *)
let test_executing_goal_with_full_evidence_is_attained () =
  let g = make_goal "g-29117-f" "executing and done" in
  let node = make_node ~tasks:[ make_done_task "t1"; make_done_task "t2" ] g in
  let json = A.goal_attainment_to_json g node in
  check (option int) "2 of 2 done is 100%" (Some 100)
    (json_int_opt json "attainment_pct");
  check string "state is attained" "attained" (json_str json "state")
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
          test_case "unevaluated metric is display-only for completion" `Quick
            test_unevaluated_metric_is_display_only_for_completion;
          test_case "receipt timeline does not fabricate runtime" `Quick
            test_keeper_receipt_timeline_missing_runtime_stays_missing;
          test_case "invalid activity time stays unavailable" `Quick
            test_goal_projection_surfaces_invalid_activity_time;
          test_case "queue failure remains typed unavailable" `Quick
            test_goals_tree_preserves_approval_queue_unavailable;
          test_case "tree task carries the cancellation actor and reason" `Quick
            test_tree_task_carries_the_cancellation_actor_and_reason;
          test_case "tree task falls through to the handoff reason" `Quick
            test_tree_task_falls_through_to_the_handoff_reason;
          test_case "tree task falls through to the handoff summary" `Quick
            test_tree_task_falls_through_to_the_handoff_summary;
          test_case "tree task omits an absent cancellation reason" `Quick
            test_tree_task_omits_an_absent_cancellation_reason;
          test_case "non-cancelled tree task carries no cancellation fields" `Quick
            test_tree_task_without_cancellation_carries_no_cancellation_fields;
          test_case "korean count metric is measured" `Quick
            test_korean_count_metric_is_measured;
          test_case "metric wording does not select percent" `Quick
            test_metric_word_does_not_select_percent;
        ] );
      ( "phase is not a measurement (#29117)",
        [
          test_case "completed goal does not fabricate attainment" `Quick
            test_completed_goal_does_not_fabricate_attainment;
          test_case "completed goal reports partial evidence" `Quick
            test_completed_goal_reports_partial_evidence;
          test_case "completed goal without evidence is unmeasured" `Quick
            test_completed_goal_without_evidence_is_unmeasured;
          test_case "completion summary still reports the phase" `Quick
            test_completion_summary_still_reports_the_phase;
          test_case "no phase derives attainment from itself" `Quick
            test_no_phase_derived_basis;
          test_case "executing goal with full evidence is attained" `Quick
            test_executing_goal_with_full_evidence_is_attained;
        ] );
    ]
