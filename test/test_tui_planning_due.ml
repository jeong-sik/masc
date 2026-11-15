(* Planning's due standing (#39571). A Goal at work three days past its due
   date drew the same row as one due next week. The standing decides which
   it is from the phase, the due date and a moment the caller fixes; here the
   moment is fixed, so no case reads a clock. A Goal falls due at 23:59:59
   UTC of its day (Goal_due). *)

open Alcotest
module Due = Masc_tui_planning_due
module Tui_decode = Masc.Tui_decode

let utc year month day hour minute second =
  match Ptime.of_date_time ((year, month, day), ((hour, minute, second), 0)) with
  | Some instant -> instant
  | None -> failwith "test setup: not a calendar instant"

let goal ?due phase : Tui_decode.planning_goal =
  { pg_id = "goal-due"
  ; pg_criterion_revision = None
  ; pg_title = "goal-due"
  ; pg_phase = phase
  ; pg_priority = 1
  ; pg_due_date = due
  ; pg_metric = None
  ; pg_target_value = None
  ; pg_proof = Tui_decode.Proof_idle
  ; pg_criterion_review = Tui_decode.Criterion_unavailable "fixture has no criterion review"
  ; pg_retry_binding = None
  ; pg_verifier_unreconciled = None
  ; pg_last_review_note = None
  ; pg_last_review_at = None
  ; pg_created_at = None
  ; pg_updated_at = None
  }

let show = function
  | Due.Due_passed -> "Due_passed"
  | Due.Due_ahead -> "Due_ahead"
  | Due.Not_in_progress -> "Not_in_progress"
  | Due.No_due -> "No_due"
  | Due.Unreadable_due raw -> Printf.sprintf "Unreadable_due %S" raw

let standing = testable (fun formatter value -> Format.pp_print_string formatter (show value)) ( = )

let at_work = [ ("executing", Goal_phase.Executing); ("verifying", Goal_phase.Verifying) ]

let not_at_work =
  [ ("awaiting confirmation", Goal_phase.Awaiting_confirmation)
  ; ("completed", Goal_phase.Completed)
  ; ("dropped", Goal_phase.Dropped)
  ; ("paused", Goal_phase.Paused Goal_phase.Resume_executing)
  ; ("blocked", Goal_phase.Blocked Goal_phase.Resume_verifying)
  ]

let expect ~now ?due phases expected =
  List.iter
    (fun (name, phase) ->
      check standing name expected (Due.standing ~now (goal ?due phase)))
    phases

let test_a_goal_at_work_past_its_day_is_past_due () =
  expect ~now:(utc 2026 11 15 0 0 0) ~due:"2026-11-14" at_work Due.Due_passed

(* The last second of the day is still the day: the Goal falls due then, and
   only the next moment is past it. *)
let test_the_due_day_itself_is_not_past_due () =
  expect ~now:(utc 2026 11 14 23 0 0) ~due:"2026-11-14" at_work Due.Due_ahead;
  expect ~now:(utc 2026 11 14 23 59 59) ~due:"2026-11-14" at_work Due.Due_ahead

let test_a_goal_not_at_work_has_no_race_with_its_date () =
  let now = utc 2026 11 15 0 0 0 in
  expect ~now ~due:"2026-11-14" not_at_work Due.Not_in_progress;
  expect ~now ~due:"2026-13-01" not_at_work Due.Not_in_progress;
  expect ~now not_at_work Due.Not_in_progress

let test_a_goal_at_work_without_a_due_date () =
  expect ~now:(utc 2026 11 15 0 0 0) at_work Due.No_due

(* A date nobody can read is not taken for no date: whether it passed is
   unknown, and the operator is told so with the value as it was written. *)
let test_an_unreadable_due_date_stays_unreadable () =
  let now = utc 2026 11 15 0 0 0 in
  expect ~now ~due:"2026-13-01" at_work (Due.Unreadable_due "2026-13-01");
  expect ~now ~due:"" at_work (Due.Unreadable_due "")

let () =
  run "tui_planning_due"
    [ ( "due standing"
      , [ test_case "a goal at work past its day is past due" `Quick
            test_a_goal_at_work_past_its_day_is_past_due
        ; test_case "the due day itself is not past due" `Quick
            test_the_due_day_itself_is_not_past_due
        ; test_case "a goal not at work has no race with its date" `Quick
            test_a_goal_not_at_work_has_no_race_with_its_date
        ; test_case "a goal at work without a due date" `Quick
            test_a_goal_at_work_without_a_due_date
        ; test_case "an unreadable due date stays unreadable" `Quick
            test_an_unreadable_due_date_stays_unreadable
        ] )
    ]
