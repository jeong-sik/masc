(* The Overview GOALS section. The fixture is GET /api/v1/dashboard/goals as
   the live workspace answered it at 2026-09-23T14:46:18Z, cut to the members
   the section reads (the metric and target texts, timelines and proof blocks
   are left out). Eight goals: five executing, three dropped, every executing
   one idle for 13h to 11d with no done task.

   The backlog beside it is the same day's shape from /api/v1/dashboard/planning:
   5 in progress and 8 awaiting verification, none of them linked to a goal,
   and the 8 goal-linked tasks all todo. The active task ids are made up; the
   planning payload counts them without naming them. *)

open Alcotest
module Goals = Masc_tui_overview_goals
module Tasks = Masc_tui_overview_tasks
module Types = Masc_tui_types
module Tui_decode = Masc.Tui_decode

let captured_at = 1790174778.0 (* 2026-09-23T14:46:18Z *)

let fixture = {goals|
{
 "generated_at": "2026-09-23T14:46:18Z",
 "tree": [
  {
   "id": "goal-release-v0-36-0",
   "title": "v0.36.0 continuity 열차 — 2026-10-07 12:00Z 컷, 진입 조건 breaks-continuity 8건 닫힘 (GitHub milestone #10)",
   "phase": "dropped",
   "priority": 1,
   "due_date": "2026-10-07",
   "task_count": 0,
   "task_done_count": 0,
   "stagnation_seconds": 88055,
   "last_activity_at": "2026-09-22T14:18:43Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [],
   "children": []
  },
  {
   "id": "goal-1790086689552-6c127e32",
   "title": "v0.37.0 릴리스 — 게이트 선행 열차 (태그 전 RC behavior green + 진입 조건 종결 + 노트 정합 확인 후 컷; 컷 후보 2026-10-07 12:00Z)",
   "phase": "executing",
   "priority": 1,
   "due_date": "2026-10-07",
   "task_count": 0,
   "task_done_count": 0,
   "stagnation_seconds": 88089,
   "last_activity_at": "2026-09-22T14:18:09Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [],
   "children": []
  },
  {
   "id": "goal-release-v0-35-22",
   "title": "v0.35.22 릴리스 — 2026-09-23 12:00Z 컷, 태그 전 게이트 4개 통과 후 퍼블리시 (GitHub milestone #9)",
   "phase": "dropped",
   "priority": 1,
   "due_date": "2026-09-23",
   "task_count": 0,
   "task_done_count": 0,
   "stagnation_seconds": 95887,
   "last_activity_at": "2026-09-22T12:08:11Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [],
   "children": []
  },
  {
   "id": "goal-audit-cross-verification-20260911",
   "title": "최근 6일간 MASC 코드베이스 회귀·SSOT 위반·스트링 휴리스틱 교차 검증",
   "phase": "executing",
   "priority": 1,
   "due_date": null,
   "task_count": 6,
   "task_done_count": 0,
   "stagnation_seconds": 129676,
   "last_activity_at": "2026-09-22T02:45:02Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [
    {
     "id": "task-1501",
     "status": "todo"
    },
    {
     "id": "task-1502",
     "status": "todo"
    },
    {
     "id": "task-1519",
     "status": "todo"
    },
    {
     "id": "task-1521",
     "status": "todo"
    },
    {
     "id": "task-1522",
     "status": "todo"
    },
    {
     "id": "task-1523",
     "status": "todo"
    }
   ],
   "children": []
  },
  {
   "id": "goal-reliable-change-g1-20260909",
   "title": "G1 요청부터 검증 결과까지 측정이 끊기지 않는다 (계약 revision 2, 2026-09-12)",
   "phase": "executing",
   "priority": 1,
   "due_date": null,
   "task_count": 1,
   "task_done_count": 0,
   "stagnation_seconds": 952356,
   "last_activity_at": "2026-09-12T14:13:42Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [
    {
     "id": "task-1478",
     "status": "todo"
    }
   ],
   "children": []
  },
  {
   "id": "goal-lane-addon-v0",
   "title": "기존 Keeper·MSX·Browser 활동을 보존하는 Lane Add-on v0",
   "phase": "dropped",
   "priority": 2,
   "due_date": null,
   "task_count": 0,
   "task_done_count": 0,
   "stagnation_seconds": 129717,
   "last_activity_at": "2026-09-22T02:44:21Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [],
   "children": []
  },
  {
   "id": "goal-1790125941892-ccfcc7ac",
   "title": "graceful restart — 빌드 성공 → SIGTERM graceful 종료(exit-reason 확인) → 새 바이너리 재기동 자동화",
   "phase": "executing",
   "priority": 3,
   "due_date": null,
   "task_count": 0,
   "task_done_count": 0,
   "stagnation_seconds": 48837,
   "last_activity_at": "2026-09-23T01:12:21Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [],
   "children": []
  },
  {
   "id": "goal-msx-play-token-cost",
   "title": "MSX 게임 플레이 keeper의 파악 비용을 자릿수로 낮춘다",
   "phase": "executing",
   "priority": 3,
   "due_date": null,
   "task_count": 1,
   "task_done_count": 0,
   "stagnation_seconds": 129683,
   "last_activity_at": "2026-09-22T02:44:55Z",
   "linked_keeper_names": [],
   "pending_approval_count": 0,
   "tasks": [
    {
     "id": "task-1484",
     "status": "todo"
    }
   ],
   "children": []
  }
 ],
 "summary": {
  "total_goals": 8,
  "active_goals": 5,
  "phase_counts": {
   "executing": 5,
   "verifying": 0,
   "awaiting_confirmation": 0,
   "completed": 0,
   "dropped": 3
  },
  "total_tasks": 8,
  "done_tasks": 0,
  "pending_approvals": 0
 }
}|goals}

let task id status : Tui_decode.task =
  { id; title = "title of " ^ id; status; priority = 2; goal_ids = [] }

let in_progress id =
  task id
    (Masc_domain.InProgress
       { assignee = "keeper-a"; started_at = "2026-09-23T00:00:00Z" })

let awaiting id =
  task id
    (Masc_domain.AwaitingVerification
       { assignee = "keeper-a"
       ; started_at = "2026-09-23T00:00:00Z"
       ; submitted_at = "2026-09-23T00:10:00Z"
       ; verification_id = "v-" ^ id
       })

let todo id = task id Masc_domain.Todo

let goal_linked_todo =
  List.map todo
    [ "task-1501"; "task-1502"; "task-1519"; "task-1521"; "task-1522"
    ; "task-1523"; "task-1478"; "task-1484" ]

let live_tasks =
  List.map in_progress (List.init 5 (fun i -> Printf.sprintf "task-91%02d" i))
  @ List.map awaiting (List.init 8 (fun i -> Printf.sprintf "task-92%02d" i))
  @ goal_linked_todo

let decode_fixture () =
  match Tui_decode.decode_overview_goals (Yojson.Safe.from_string fixture) with
  | Ok goals -> goals
  | Error error ->
      failf "fixture did not decode: %s"
        (Tui_decode.overview_goals_error_to_string error)

(* Escape sequences carry no text; the assertions read what a person sees. *)
let strip_ansi text =
  let buf = Buffer.create (String.length text) in
  let length = String.length text in
  let rec skip_csi i =
    if i >= length then i
    else
      match text.[i] with
      | '@' .. '~' -> i + 1
      | _ -> skip_csi (i + 1)
  in
  let rec walk i =
    if i < length then
      if text.[i] = '\027' && i + 1 < length && text.[i + 1] = '[' then
        walk (skip_csi (i + 2))
      else begin
        Buffer.add_char buf text.[i];
        walk (i + 1)
      end
  in
  walk 0;
  Buffer.contents buf

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

let draw ?(rows = 25) ?(tasks = live_tasks) reading =
  Goals.lines ~now:captured_at ~inner_width:120 ~rows
    ~tasks:(Tasks.Rows_read tasks) reading
  |> List.map strip_ansi

let find_row ~sub rows =
  match List.find_opt (contains ~sub) rows with
  | Some row -> row
  | None -> failf "no row mentions %S in:\n%s" sub (String.concat "\n" rows)

let test_live_fleet_moves_no_goal () =
  let goals = decode_fixture () in
  check int "every goal of the tree is read" 8 (List.length goals);
  let rows = draw (Types.Goals_read goals) in
  check int "one headline and one row per executing goal" 6 (List.length rows);
  check bool "headline counts linked active tasks" true
    (contains ~sub:"active tasks linked: 0/13" (List.hd rows));
  let audit = find_row ~sub:"6일간" rows in
  check bool "the linked task count is explicit" true
    (contains ~sub:"0/6 tasks" audit);
  check bool "task progress is not drawn as goal progress" false
    (contains ~sub:"░" audit || contains ~sub:"idle" audit);
  let release = find_row ~sub:"v0.37.0" rows in
  check bool "a goal with no tasks says so" true
    (contains ~sub:"no tasks" release);
  check bool "due date appears once" true
    (contains ~sub:"due 10-07 (D-14)" release)

let test_one_row_fits_a_short_viewport () =
  let goal =
    match Goals.drawn_goals (decode_fixture ()) with
    | first :: _ -> first
    | [] -> fail "fixture has no drawn goal"
  in
  let rows =
    Goals.lines ~now:captured_at ~inner_width:46
      ~rows:2 ~tasks:(Tasks.Rows_read live_tasks)
      (Types.Goals_read [ goal ])
    |> List.map strip_ansi
  in
  check int "a headline and goal fit" 2 (List.length rows);
  check bool "goal title remains visible" true
    (contains ~sub:"v0.37" (List.nth rows 1));
  check bool "the goal stays inside its 46-cell frame" true
    (Masc_tui_message_layout.display_width (List.nth rows 1) <= 46)

let test_narrow_goal_keeps_identity_and_attention () =
  let goal =
    match Goals.drawn_goals (decode_fixture ()) with
    | first :: _ ->
        { first with
          og_phase = Goal_phase.Verifying
        ; og_completion = Some "proof_refuted"
        ; og_due_date = Some "2026-09-01"
        }
    | [] -> fail "fixture has no drawn goal"
  in
  let row =
    Goals.lines ~now:captured_at ~inner_width:46
      ~rows:2 ~tasks:(Tasks.Rows_read live_tasks) (Types.Goals_read [ goal ])
    |> List.map strip_ansi |> fun rows -> List.nth rows 1
  in
  check bool "the title still identifies the goal" true
    (contains ~sub:"v0.37.0" row);
  check bool "both warnings and stage remain visible" true
    (contains ~sub:"refuted" row && contains ~sub:"overdue" row
     && contains ~sub:"verify" row);
  check bool "row stays within 46 cells" true
    (Masc_tui_message_layout.display_width row <= 46)

(* The input that splits the headline: one of the active tasks is a task an
   executing goal lists. *)
let test_an_active_goal_task_counts () =
  let goals = decode_fixture () in
  let tasks = in_progress "task-1501" :: live_tasks in
  let rows = draw ~tasks (Types.Goals_read goals) in
  check bool "the linked task is counted toward a goal" true
    (contains ~sub:"active tasks linked: 1/14" (List.hd rows))

let test_a_short_budget_says_what_it_cut () =
  let goals = decode_fixture () in
  let rows = draw ~rows:3 (Types.Goals_read goals) in
  check int "the budget is kept" 3 (List.length rows);
  check bool "the headline says how many goals are drawn" true
    (contains ~sub:"2 of 5 goals shown" (List.hd rows))

let test_a_failed_read_is_one_explicit_line () =
  check (list string) "a failure is named, not drawn as an empty section"
    [ "Goals unavailable: goals load failed: connection refused" ]
    (draw ~rows:1 (Types.Goals_failed "goals load failed: connection refused"));
  check int "a failed read asks for one row" 1
    (Goals.wanted_rows
       (Types.Goals_failed "x"))

let test_an_unread_goals_read_names_the_unknown_in_one_row () =
  check (list string) "one allocated row includes the unread reason"
    [ "Goals   No goal data read yet." ]
    (draw ~rows:1 Types.Goals_unread);
  check int "an unread read asks for one row" 1
    (Goals.wanted_rows
       Types.Goals_unread)

let test_an_unread_backlog_is_not_a_zero () =
  let goals = decode_fixture () in
  let rows =
    Goals.lines ~now:captured_at ~inner_width:120 ~rows:10
      ~tasks:(Tasks.Rows_unavailable "backlog.json unreadable")
      (Types.Goals_read goals)
    |> List.map strip_ansi
  in
  check bool "the headline names the unread backlog" true
    (contains ~sub:"active work unread: backlog.json unreadable" (List.hd rows));
  check bool "and counts nothing" false (contains ~sub:"of 13" (List.hd rows))

(* Before the first tasks read the list is [] with no error. The headline
   says the backlog is unread instead of counting "0 of 0". *)
let test_a_backlog_not_read_yet_is_not_a_zero () =
  let goals = decode_fixture () in
  let rows =
    Goals.lines ~now:captured_at ~inner_width:120 ~rows:10
      ~tasks:Tasks.Rows_unread
      (Types.Goals_read goals)
    |> List.map strip_ansi
  in
  check bool "the headline says active work is unread" true
    (contains ~sub:"active work unread" (List.hd rows));
  check bool "and counts nothing" false (contains ~sub:"0 of 0" (List.hd rows));
  check bool "and names no reason it does not have" false
    (contains ~sub:"unread:" (List.hd rows))

(* An operator whose clock is nine hours ahead of UTC. POSIX TZ syntax, so the
   test needs no zoneinfo on the host. A test binary is its own process, and an
   unset TZ came from the host, so UTC stands in for it afterwards. *)
let in_kst f =
  let previous = Sys.getenv_opt "TZ" in
  Unix.putenv "TZ" "KST-9";
  Fun.protect
    ~finally:(fun () -> Unix.putenv "TZ" (Option.value previous ~default:"UTC"))
    f

let release_row ~now =
  let goals = decode_fixture () in
  Goals.lines ~now ~inner_width:120 ~rows:10 ~tasks:(Tasks.Rows_read live_tasks)
    (Types.Goals_read goals)
  |> List.map strip_ansi |> find_row ~sub:"v0.37.0"

(* A due date is a UTC day (Goal_due). 2026-09-23T15:30:00Z is already 00:30 on
   the 24th for an operator in KST; the release is still 14 days away by the
   UTC calendar. *)
let test_the_countdown_counts_utc_days_in_any_zone () =
  let just_after_kst_midnight = 1790177400.0 in
  in_kst (fun () ->
      check bool "00:30 KST on the 24th still counts from the 23rd" true
        (contains ~sub:"due 10-07 (D-14)"
           (release_row ~now:just_after_kst_midnight)))

(* The countdown turns over at 00:00:00 UTC, not a second before. *)
let test_the_countdown_turns_over_at_utc_midnight () =
  let last_second_of_the_23rd = 1790207999.0 in
  let first_second_of_the_24th = 1790208000.0 in
  check bool "23:59:59Z is still the 23rd" true
    (contains ~sub:"due 10-07 (D-14)" (release_row ~now:last_second_of_the_23rd));
  check bool "00:00:00Z is the 24th" true
    (contains ~sub:"due 10-07 (D-13)" (release_row ~now:first_second_of_the_24th))

let test_a_goal_without_children_is_refused () =
  let json =
    Yojson.Safe.from_string
      {|{"tree":[{"id":"goal-x","title":"x","phase":"executing","priority":1,
          "due_date":null,"task_count":0,"task_done_count":0,
          "stagnation_seconds":null,"tasks":[]}]}|}
  in
  match Tui_decode.decode_overview_goals json with
  | Error (Tui_decode.Overview_goals_malformed _) -> ()
  | Error other ->
      failf "refused for another reason: %s"
        (Tui_decode.overview_goals_error_to_string other)
  | Ok _ -> fail "a goal with no children field decoded"

let test_an_empty_tree_is_one_headline () =
  let empty = Types.Goals_read [] in
  check int "an empty tree asks for one row" 1
    (Goals.wanted_rows
       empty);
  check (list string) "the empty section gives the next fact"
    [ "Goals (0)   No goal is executing or verifying." ]
    (draw empty)

let test_an_unknown_phase_is_refused () =
  let json =
    Yojson.Safe.from_string
      {|{"tree":[{"id":"goal-x","title":"x","phase":"paused","priority":1,
          "due_date":null,"task_count":0,"task_done_count":0,
          "stagnation_seconds":null,"tasks":[],"children":[]}]}|}
  in
  match Tui_decode.decode_overview_goals json with
  | Error (Tui_decode.Overview_goal_phase_unknown { goal_id; phase }) ->
      check string "the refused goal" "goal-x" goal_id;
      check string "the refused phase" "paused" phase
  | Error other ->
      failf "refused for another reason: %s"
        (Tui_decode.overview_goals_error_to_string other)
  | Ok _ -> fail "an unknown phase decoded"

let test_explicit_measurement_requires_the_current_criterion () =
  let document revision =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"tree":[{"id":"goal-x","title":"x","phase":"executing","priority":1,
            "criterion_revision":"r2","metric":"passing checks","target_value":"5",
            "measurement":{"state":"reported","record":{"goal_id":"goal-x",
              "criterion_revision":"%s","observed_value":"3","evidence":"artifact:checks",
              "actor":"planner","recorded_at":"2026-09-24T00:00:00Z"}},
            "due_date":null,"task_count":0,"task_done_count":0,
            "stagnation_seconds":null,"tasks":[],"children":[]}]}|}
         revision)
  in
  (match Tui_decode.decode_overview_goals (document "r2") with
   | Ok [ { og_measurement = Tui_decode.Goal_measurement_reported { value; _ }; _ } ] ->
       check string "value is reported, not inferred" "3" value
   | Ok _ | Error _ -> fail "current explicit observation was not decoded");
  (match Tui_decode.decode_overview_goals (document "r1") with
   | Error (Tui_decode.Overview_goals_malformed _) -> ()
   | Ok _ | Error _ -> fail "stale criterion was accepted")

let row_of_goal ?(now = captured_at) goal =
  let rows =
    Goals.lines ~now ~inner_width:120
      ~rows:2 ~tasks:(Tasks.Rows_read live_tasks)
      (Types.Goals_read [ goal ])
    |> List.map strip_ansi
  in
  List.nth rows 1

(* #39571: a Goal whose latest verdict was a rejection reads as refuted, not as
   one that is simply executing again. *)
let test_a_refuted_goal_is_shown_as_refuted () =
  let goal =
    match Goals.drawn_goals (decode_fixture ()) with
    | first :: _ -> { first with og_completion = Some "proof_refuted" }
    | [] -> fail "fixture has no drawn goal"
  in
  check bool "the refuted goal is named refuted" true
    (contains ~sub:"refuted" (row_of_goal goal))

(* #39571: overdue appears only after due_date, and only for a Goal still
   executing or verifying. captured_at is 2026-09-23. *)
let test_overdue_appears_only_after_due_date () =
  let base =
    match Goals.drawn_goals (decode_fixture ()) with
    | first :: _ -> first
    | [] -> fail "fixture has no drawn goal"
  in
  let past =
    { base with og_phase = Goal_phase.Executing; og_due_date = Some "2026-09-01" }
  in
  let future =
    { base with og_phase = Goal_phase.Executing; og_due_date = Some "2026-10-07" }
  in
  let dropped =
    { base with og_phase = Goal_phase.Dropped; og_due_date = Some "2026-09-01" }
  in
  check bool "a past due date on an executing goal is overdue" true
    (contains ~sub:"overdue" (row_of_goal past));
  check bool "a future due date is not overdue" false
    (contains ~sub:"overdue" (row_of_goal future));
  check bool "a dropped goal is not drawn, so never overdue" false
    (contains ~sub:"overdue" (String.concat " " (draw (Types.Goals_read [ dropped ]))))

let first_drawn_goal () =
  match Goals.drawn_goals (decode_fixture ()) with
  | first :: _ -> first
  | [] -> fail "fixture has no drawn goal"

(* Due 2026-09-23 falls due at 23:59:59Z that day. The row reads overdue from
   the first instant after it, not from the operator's midnight. *)
let test_overdue_turns_on_after_23_59_59_utc () =
  let due_on_the_23rd =
    { (first_drawn_goal ()) with
      og_phase = Goal_phase.Executing
    ; og_due_date = Some "2026-09-23"
    }
  in
  in_kst (fun () ->
      let at_the_last_second = row_of_goal ~now:1790207999.0 due_on_the_23rd in
      let a_second_later = row_of_goal ~now:1790208000.0 due_on_the_23rd in
      check bool "23:59:59Z is not overdue" false
        (contains ~sub:"overdue" at_the_last_second);
      check bool "the due day counts D-0" true
        (contains ~sub:"due 09-23 (D-0)" at_the_last_second);
      check bool "00:00:00Z the next day is overdue" true
        (contains ~sub:"overdue" a_second_later);
      check bool "and counts D+1" true
        (contains ~sub:"due 09-23 (D+1)" a_second_later))

(* A value that is not YYYY-MM-DD is drawn as written, with no countdown, and
   is never overdue. Goal_due does not guess what "2026-9-3" or "tomorrow"
   meant. *)
let test_an_unreadable_due_date_is_drawn_as_written () =
  let base = first_drawn_goal () in
  List.iter
    (fun raw ->
      let row =
        row_of_goal
          { base with og_phase = Goal_phase.Executing; og_due_date = Some raw }
      in
      check bool (raw ^ " is drawn as written") true
        (contains ~sub:("due " ^ raw) row);
      check bool (raw ^ " has no countdown") false
        (contains ~sub:"(D-" row || contains ~sub:"(D+" row);
      check bool (raw ^ " is never overdue") false
        (contains ~sub:"overdue" row))
    [ "tomorrow"; "2026-9-3"; "2026-13-01"; "2026-02-30"
    ; "2000-01-01T00:00:00Z" ]

(* Goals of one priority order by the day they fall due. A value that is not a
   due date has no day, so it sorts with the goals that have none. *)
let test_an_unreadable_due_date_sorts_with_the_undated () =
  let base = first_drawn_goal () in
  let goal og_id og_due_date =
    { base with
      og_id
    ; og_phase = Goal_phase.Executing
    ; og_priority = 1
    ; og_due_date
    }
  in
  let order =
    Goals.drawn_goals
      [ goal "unreadable" (Some "tomorrow")
      ; goal "undated" None
      ; goal "later" (Some "2026-10-07")
      ; goal "sooner" (Some "2026-09-30")
      ]
    |> List.map (fun (drawn : Tui_decode.overview_goal) -> drawn.og_id)
  in
  check (list string) "dated goals first, the rest in the order they came"
    [ "sooner"; "later"; "unreadable"; "undated" ]
    order

let () =
  run "tui_overview_goals"
    [ ( "overview goals"
      , [ test_case "the live fleet moves no goal" `Quick
            test_live_fleet_moves_no_goal
        ; test_case "a goal fits one short row" `Quick
            test_one_row_fits_a_short_viewport
        ; test_case "a narrow goal keeps identity and attention" `Quick
            test_narrow_goal_keeps_identity_and_attention
        ; test_case "a refuted goal is shown as refuted" `Quick
            test_a_refuted_goal_is_shown_as_refuted
        ; test_case "overdue appears only after due_date" `Quick
            test_overdue_appears_only_after_due_date
        ; test_case "an active goal task counts" `Quick
            test_an_active_goal_task_counts
        ; test_case "a short budget says what it cut" `Quick
            test_a_short_budget_says_what_it_cut
        ; test_case "a failed read is one explicit line" `Quick
            test_a_failed_read_is_one_explicit_line
        ; test_case "one unread goal row names the unknown" `Quick
            test_an_unread_goals_read_names_the_unknown_in_one_row
        ; test_case "an unread backlog is not a zero" `Quick
            test_an_unread_backlog_is_not_a_zero
        ; test_case "a backlog not read yet is not a zero" `Quick
            test_a_backlog_not_read_yet_is_not_a_zero
        ; test_case "the countdown counts UTC days in any zone" `Quick
            test_the_countdown_counts_utc_days_in_any_zone
        ; test_case "the countdown turns over at UTC midnight" `Quick
            test_the_countdown_turns_over_at_utc_midnight
        ; test_case "overdue turns on after 23:59:59 UTC" `Quick
            test_overdue_turns_on_after_23_59_59_utc
        ; test_case "an unreadable due date is drawn as written" `Quick
            test_an_unreadable_due_date_is_drawn_as_written
        ; test_case "an unreadable due date sorts with the undated" `Quick
            test_an_unreadable_due_date_sorts_with_the_undated
        ; test_case "a goal without children is refused" `Quick
            test_a_goal_without_children_is_refused
        ; test_case "an empty tree is one headline" `Quick
            test_an_empty_tree_is_one_headline
        ; test_case "an unknown phase is refused" `Quick
            test_an_unknown_phase_is_refused
        ; test_case "measurement is bound to the current criterion" `Quick
            test_explicit_measurement_requires_the_current_criterion
        ] )
    ]
