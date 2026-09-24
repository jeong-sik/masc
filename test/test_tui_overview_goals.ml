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
       ; intent = Masc_domain.Complete_task
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

let draw ?(rows = 10) ?(tasks = live_tasks) reading =
  Goals.lines ~now:captured_at ~localtime:Unix.gmtime ~inner_width:120 ~rows
    ~tasks:(Ok tasks) reading
  |> List.map strip_ansi

let find_row ~sub rows =
  match List.find_opt (contains ~sub) rows with
  | Some row -> row
  | None -> failf "no row mentions %S in:\n%s" sub (String.concat "\n" rows)

let test_live_fleet_moves_no_goal () =
  let goals = decode_fixture () in
  check int "every goal of the tree is read" 8 (List.length goals);
  check (list string) "drawn goals by priority, then due date"
    [ "goal-1790086689552-6c127e32"
    ; "goal-audit-cross-verification-20260911"
    ; "goal-reliable-change-g1-20260909"
    ; "goal-1790125941892-ccfcc7ac"
    ; "goal-msx-play-token-cost"
    ]
    (List.map
       (fun (goal : Tui_decode.overview_goal) -> goal.og_id)
       (Goals.drawn_goals goals));
  let rows = draw (Types.Goals_read goals) in
  check int "the headline and one row per executing goal" 6 (List.length rows);
  check bool "the headline counts no active task toward a goal" true
    (contains ~sub:"active work toward a goal: 0 of 13 tasks" (List.hd rows));
  let audit = find_row ~sub:"6일간" rows in
  check bool "the bar row counts the goal's tasks" true
    (contains ~sub:"\xe2\x96\x91\xe2\x96\x91  0/6 tasks" audit);
  check bool "the bar row prints how long the goal has been idle" true
    (contains ~sub:"idle 1d" audit);
  let release = find_row ~sub:"v0.37.0" rows in
  check bool "a goal with no task says so instead of a zero" true
    (contains ~sub:"no tasks" release);
  check bool "a due date counts down" true
    (contains ~sub:"due 10-07 (D-14)" release)

(* The input that splits the headline: one of the active tasks is a task an
   executing goal lists. *)
let test_an_active_goal_task_counts () =
  let goals = decode_fixture () in
  let tasks = in_progress "task-1501" :: live_tasks in
  let rows = draw ~tasks (Types.Goals_read goals) in
  check bool "the linked task is counted toward a goal" true
    (contains ~sub:"active work toward a goal: 1 of 14 tasks" (List.hd rows))

let test_a_short_budget_says_what_it_cut () =
  let goals = decode_fixture () in
  let rows = draw ~rows:3 (Types.Goals_read goals) in
  check int "the budget is kept" 3 (List.length rows);
  check bool "the headline says how many goals are drawn" true
    (contains ~sub:"2 of 5 goals shown" (List.hd rows))

let test_a_failed_read_is_one_explicit_line () =
  check (list string) "a failure is named, not drawn as an empty section"
    [ "GOALS   goals unavailable: goals load failed: connection refused" ]
    (draw (Types.Goals_failed "goals load failed: connection refused"));
  check int "a failed read asks for its one line" 1
    (Goals.wanted_rows (Types.Goals_failed "x"))

let test_an_unread_backlog_is_not_a_zero () =
  let goals = decode_fixture () in
  let rows =
    Goals.lines ~now:captured_at ~localtime:Unix.gmtime ~inner_width:120 ~rows:10
      ~tasks:(Error "backlog.json unreadable") (Types.Goals_read goals)
    |> List.map strip_ansi
  in
  check bool "the headline names the unread backlog" true
    (contains ~sub:"active work unread: backlog.json unreadable" (List.hd rows));
  check bool "and counts nothing" false (contains ~sub:"of 13" (List.hd rows))

(* 2026-09-23T15:30:00Z is already 00:30 on the 24th in KST. The operator's
   calendar says the release is 13 days away; UTC days would say 14. *)
let test_the_countdown_uses_the_operator_calendar () =
  let goals = decode_fixture () in
  let just_after_kst_midnight = 1790177400.0 in
  let kst now = Unix.gmtime (now +. (9. *. 3600.)) in
  let rows =
    Goals.lines ~now:just_after_kst_midnight ~localtime:kst ~inner_width:120
      ~rows:10 ~tasks:(Ok live_tasks) (Types.Goals_read goals)
    |> List.map strip_ansi
  in
  check bool "the countdown is from the local date" true
    (contains ~sub:"due 10-07 (D-13)" (find_row ~sub:"v0.37.0" rows))

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
  check int "an empty tree asks for one row" 1 (Goals.wanted_rows empty);
  check (list string) "the headline says no goal is open"
    [ "GOALS   active work toward a goal: 0 of 13 tasks  \xc2\xb7 no goal is \
       executing, verifying or awaiting confirmation" ]
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

let () =
  run "tui_overview_goals"
    [ ( "overview goals"
      , [ test_case "the live fleet moves no goal" `Quick
            test_live_fleet_moves_no_goal
        ; test_case "an active goal task counts" `Quick
            test_an_active_goal_task_counts
        ; test_case "a short budget says what it cut" `Quick
            test_a_short_budget_says_what_it_cut
        ; test_case "a failed read is one explicit line" `Quick
            test_a_failed_read_is_one_explicit_line
        ; test_case "an unread backlog is not a zero" `Quick
            test_an_unread_backlog_is_not_a_zero
        ; test_case "the countdown uses the operator calendar" `Quick
            test_the_countdown_uses_the_operator_calendar
        ; test_case "a goal without children is refused" `Quick
            test_a_goal_without_children_is_refused
        ; test_case "an empty tree is one headline" `Quick
            test_an_empty_tree_is_one_headline
        ; test_case "an unknown phase is refused" `Quick
            test_an_unknown_phase_is_refused
        ] )
    ]
