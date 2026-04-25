(** #10421 — pin the [task_claim_next] auto-release reason
    classification.

    Pre-fix every [task_claim_next_auto_release] JSON event was
    opaque — operators saw 20 events on day 25 (and 35/37 of
    analyst's claims terminating as auto-release) but couldn't
    tell the polling-abuse signal (claim dropped within seconds
    without any work) from legitimate cleanup (long-held claim
    swapped in after a verifier or operator action).  The
    fleet-wide hot-potato pattern — task-056 claimed and dropped
    five times in a row — was hidden inside a single counter.

    Post-fix two pure helpers expose a small reason vocabulary
    suitable for a Prometheus label:

    - [auto_release_reason_for_age None             = "unknown_age"]
    - [auto_release_reason_for_age (Some <30s)      = "rapid_replacement"]
    - [auto_release_reason_for_age (Some >=30s)     = "stale_replacement"]

    [prev_claim_age_seconds] reads the [claimed_at] /
    [started_at] timestamp on the prior claim and returns
    [None] for terminal or untimestamped statuses.  Both
    helpers stay pure so the wiring inside
    [Coord_task_schedule.task_claim_next] is easy to audit and
    the threshold can move under test pressure rather than
    under fleet pressure. *)

open Alcotest

module CTS = Coord_task_schedule

(* --- 1. reason vocabulary --------------------------- *)

let test_unknown_age_when_none () =
  check string "None → unknown_age" "unknown_age"
    (CTS.auto_release_reason_for_age None)

let test_rapid_replacement_below_threshold () =
  check string "0.0s → rapid_replacement" "rapid_replacement"
    (CTS.auto_release_reason_for_age (Some 0.0));
  check string "5.0s → rapid_replacement" "rapid_replacement"
    (CTS.auto_release_reason_for_age (Some 5.0));
  check string "29.999s → rapid_replacement" "rapid_replacement"
    (CTS.auto_release_reason_for_age (Some 29.999))

let test_stale_replacement_at_or_above_threshold () =
  check string "30.0s → stale_replacement" "stale_replacement"
    (CTS.auto_release_reason_for_age (Some 30.0));
  check string "120.0s → stale_replacement" "stale_replacement"
    (CTS.auto_release_reason_for_age (Some 120.0));
  check string "3600.0s → stale_replacement" "stale_replacement"
    (CTS.auto_release_reason_for_age (Some 3600.0))

(* --- 2. prev_claim_age_seconds extracts timestamp ------- *)

let mk_task ~status : Types.task =
  {
    id = "task-test";
    title = "test";
    description = "";
    task_status = status;
    priority = 5;
    files = [];
    created_at = "2026-04-25T00:00:00Z";
    created_by = None;
    worktree = None;
    goal_id = None;
    stage = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    do_not_reclaim_reason = None;
  }

let now_for ~claimed_at offset_sec =
  match Types_core.parse_iso8601_opt claimed_at with
  | Some t -> t +. offset_sec
  | None -> failwith "fixture parse"

let test_age_for_claimed () =
  let claimed_at = "2026-04-25T12:00:00Z" in
  let task =
    mk_task
      ~status:(Types.Claimed { assignee = "kp"; claimed_at })
  in
  let now = now_for ~claimed_at 7.5 in
  match CTS.prev_claim_age_seconds ~now task with
  | None -> failf "expected Some, got None"
  | Some s -> check (float 0.001) "age preserves offset" 7.5 s

let test_age_for_in_progress () =
  let started_at = "2026-04-25T12:00:00Z" in
  let task =
    mk_task
      ~status:(Types.InProgress { assignee = "kp"; started_at })
  in
  let now = now_for ~claimed_at:started_at 45.0 in
  match CTS.prev_claim_age_seconds ~now task with
  | None -> failf "expected Some, got None"
  | Some s -> check (float 0.001) "InProgress uses started_at" 45.0 s

let test_age_floor_at_zero () =
  (* Clock skew: now is slightly earlier than claimed_at.  The
     helper clamps to 0 so callers don't see negative ages. *)
  let claimed_at = "2026-04-25T12:00:00Z" in
  let task =
    mk_task
      ~status:(Types.Claimed { assignee = "kp"; claimed_at })
  in
  let now = now_for ~claimed_at (-2.0) in
  match CTS.prev_claim_age_seconds ~now task with
  | None -> failf "expected Some, got None"
  | Some s -> check (float 0.001) "negative skew clamped to 0.0" 0.0 s

let test_age_none_for_todo () =
  let task = mk_task ~status:Types.Todo in
  check
    (option (float 0.001))
    "Todo task has no claim age"
    None
    (CTS.prev_claim_age_seconds ~now:0.0 task)

let test_age_none_for_done () =
  let task =
    mk_task
      ~status:
        (Types.Done
           {
             assignee = "kp";
             completed_at = "2026-04-25T12:00:00Z";
             notes = None;
           })
  in
  check
    (option (float 0.001))
    "Done task has no claim age"
    None
    (CTS.prev_claim_age_seconds ~now:0.0 task)

(* --- 3. metric name in vocabulary ------------------ *)

let test_metric_name_canonical () =
  check string "Prometheus metric name uses masc_ prefix"
    "masc_task_claim_auto_release_total"
    Masc_mcp.Prometheus.metric_task_claim_auto_release

let () =
  run "task_claim_auto_release_reason_10421"
    [
      ( "reason-vocabulary",
        [
          test_case "None → unknown_age" `Quick test_unknown_age_when_none;
          test_case "below threshold → rapid_replacement" `Quick
            test_rapid_replacement_below_threshold;
          test_case "at/above threshold → stale_replacement" `Quick
            test_stale_replacement_at_or_above_threshold;
        ] );
      ( "prev-claim-age",
        [
          test_case "Claimed reads claimed_at" `Quick test_age_for_claimed;
          test_case "InProgress reads started_at" `Quick
            test_age_for_in_progress;
          test_case "negative skew clamps to zero" `Quick
            test_age_floor_at_zero;
          test_case "Todo returns None" `Quick test_age_none_for_todo;
          test_case "Done returns None" `Quick test_age_none_for_done;
        ] );
      ( "metric-name",
        [
          test_case "metric name canonical" `Quick
            test_metric_name_canonical;
        ] );
    ]
