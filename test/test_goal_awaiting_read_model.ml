(** RFC-0323 G-6 — AwaitingVerification is the normal completion lane in
    every goal read model.

    Pre-G-6 the read models treated a linked [AwaitingVerification] task as
    a problem: the goals tree fed it into [at_risk] (health degraded to
    "at_risk", blocking_source "task_fsm") and the briefing/execution
    operation projections rendered it as "paused" with a warn tone. Under
    RFC-0323 approve-only completion, every completing task passes through
    AwaitingVerification — flagging it as risk would mark all healthy
    completion traffic at-risk.

    Pinned here:
    - differential build_tree: swapping a linked task's status from
      InProgress to AwaitingVerification must not change health or
      blocking_source (awaiting is never worse than in-progress), and must
      surface the "task_verification_pending" badge (visibility is kept,
      reclassified from risk to pending).
    - unit pins on the renamed [verification_pending] axis in
      [Dashboard_goals_types_health]. *)

open Alcotest
open Masc

let iso_now () = Masc_domain.now_iso ()

let make_goal id title =
  {
    Goal_store.id;
    title;
    metric = None;
    target_value = None;
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

let make_task ~status id : Masc_domain.task =
  {
    id;
    title = "linked task";
    description = "";
    task_status = status;
    priority = 3;
    files = [];
    created_at = iso_now ();
    created_by = None;
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    do_not_reclaim_reason = None;
  }

let build_single_goal_tree ~task =
  let goal = make_goal "goal-g6" "G-6 read model" in
  let goal_task_index : (string, string list) Hashtbl.t = Hashtbl.create 4 in
  Hashtbl.replace goal_task_index task.Masc_domain.id [ goal.Goal_store.id ];
  let context =
    {
      Dashboard_goals_types.now_ts = Time_compat.now ();
      all_tasks = [ task ];
      pending_approvals = [];
      keeper_metas = [];
      latest_receipts = [];
      latest_runtime_trusts = [];
      goal_task_index;
    }
  in
  Dashboard_goals_types.build_tree context [ goal ] goal

let awaiting_status : Masc_domain.task_status =
  Masc_domain.AwaitingVerification
    {
      assignee = "worker-a";
      submitted_at = iso_now ();
      verification_id = "vrf-g6-read-model";
      phase = Masc_domain.Awaiting_verifier;
    }

let in_progress_status : Masc_domain.task_status =
  Masc_domain.InProgress { assignee = "worker-a"; started_at = iso_now () }

let test_awaiting_task_never_worse_than_in_progress () =
  let in_progress =
    build_single_goal_tree ~task:(make_task ~status:in_progress_status "task-ip")
  in
  let awaiting =
    build_single_goal_tree ~task:(make_task ~status:awaiting_status "task-av")
  in
  check string "health identical to the in-progress baseline"
    in_progress.Dashboard_goals_types.health awaiting.Dashboard_goals_types.health;
  check string "blocking_source identical to the in-progress baseline"
    in_progress.Dashboard_goals_types.blocking_source
    awaiting.Dashboard_goals_types.blocking_source;
  check bool "blocking_source is never task_fsm" false
    (String.equal awaiting.Dashboard_goals_types.blocking_source "task_fsm");
  check bool "verification-pending badge surfaces" true
    (List.mem "task_verification_pending" awaiting.Dashboard_goals_types.badges);
  check bool "no pending badge on the in-progress baseline" false
    (List.mem "task_verification_pending" in_progress.Dashboard_goals_types.badges)

let test_health_axis_verification_pending_is_not_risk () =
  let badges =
    Dashboard_goals_types.tree_badges ~pending_approvals:0 ~sandbox_risk:false
      ~runtime_risk:false ~verification_pending:true ~stalled:false
      ~activity_unobserved:false
  in
  check (list string) "pending badge only" [ "task_verification_pending" ] badges;
  let reason =
    Dashboard_goals_types.goal_health_reason ~goal_phase:Goal_phase.Executing
      ~blocked_by_receipt:false ~child_blocked:false ~pending_approvals:0
      ~sandbox_risk:false ~runtime_risk:false ~verification_pending:true
      ~stalled:false ~stagnation_seconds:0 ~child_at_risk:false
      ~linkage_warning_reason:None ~activity_observation:"task"
      ~stagnation_status:"recent"
  in
  check string "reason names the normal lane, not remediation"
    "Linked task is awaiting verification (normal completion lane)." reason

let () =
  run "Goal awaiting read model (RFC-0323 G-6)"
    [
      ( "g6",
        [
          test_case "awaiting never worse than in-progress" `Quick
            test_awaiting_task_never_worse_than_in_progress;
          test_case "verification_pending axis is badge-only" `Quick
            test_health_axis_verification_pending_is_not_risk;
        ] );
    ]
