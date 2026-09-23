(* The Overview Tasks section. The 2026-09-23 capture listed the oldest todo
   tasks while the in-progress and awaiting ones, the work actually moving,
   were not on screen. The fixture mixes the two so the order is what is
   read: held work first, the backlog as one line. *)

open Alcotest
module Tasks = Masc_tui_overview_tasks
module Tui_decode = Masc.Tui_decode

let now =
  match Masc_domain.parse_iso8601_opt "2026-09-23T12:00:00Z" with
  | Some at -> at
  | None -> Alcotest.fail "fixture clock does not parse"

let row id status : Tui_decode.task =
  { id; title = "title of " ^ id; status; priority = 2; goal_ids = [] }

let in_progress started_at =
  Masc_domain.InProgress { assignee = "rondo"; started_at }

let awaiting submitted_at =
  Masc_domain.AwaitingVerification
    { assignee = "geek-scout"
    ; started_at = "2026-09-23T08:00:00Z"
    ; submitted_at
    ; intent = Masc_domain.Complete_task
    ; verification_id = "v-1"
    }

let domain_todo id created_at : Masc_domain.task =
  { Masc_domain.id
  ; title = "title of " ^ id
  ; description = ""
  ; task_status = Masc_domain.Todo
  ; priority = 3
  ; files = []
  ; created_at
  ; created_by = Some "producer"
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Masc_domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  ; skills = []
  }

(* Backlog order, oldest first, the way the loader hands it over: the todo
   rows come before the held ones, which is how they filled the section. *)
let tasks =
  [ row "task-1501" Masc_domain.Todo
  ; row "task-1502" Masc_domain.Todo
  ; row "task-1519" Masc_domain.Todo
  ; row "task-1700" (awaiting "2026-09-23T11:20:00Z")
  ; row "task-1710" (in_progress "2026-09-23T11:55:00Z")
  ; row "task-1720" (in_progress "2026-09-23T10:00:00Z")
  ; row "task-1730"
      (Masc_domain.Claimed
         { assignee = "rondo"; claimed_at = "2026-09-23T11:59:00Z" })
  ]

let backlog =
  Tasks.backlog
    [ domain_todo "task-1501" "2026-09-11T12:00:00Z"
    ; domain_todo "task-1502" "2026-09-11T13:00:00Z"
    ; domain_todo "task-1519" "2026-09-12T00:00:00Z"
    ]

(* Seconds as a plain count, so the test reads the arithmetic rather than
   the renderer's unit choice. *)
let seconds_text seconds = string_of_int seconds ^ "s"

(* What the renderer draws, without its colours: a task row is its age and
   id, every other line its summary text. *)
let drawn ~height ~cursor =
  Tasks.lines ~height ~cursor tasks backlog
  |> List.map (fun line ->
         match line with
         | Tasks.Task_row { task; _ } ->
             Tasks.age_text ~age_text:seconds_text ~now (Tasks.held_since task)
             ^ " " ^ task.id
         | Tasks.More_active _ | Tasks.Nothing_active | Tasks.Todo_backlog _ ->
             Option.value ~default:"<no text>"
               (Tasks.summary_text ~age_text:seconds_text ~now line))

(* 2026-09-11T12:00Z to the fixture clock. *)
let oldest_todo_seconds = string_of_int (12 * 24 * 3600) ^ "s"

let test_held_work_first () =
  check (list string)
    "in progress longest first, then awaiting, then claimed, then the backlog line"
    [ "7200s task-1720"
    ; "300s task-1710"
    ; "2400s task-1700"
    ; "60s task-1730"
    ; "3 todo · oldest " ^ oldest_todo_seconds
    ]
    (drawn ~height:10 ~cursor:0)

let test_cut_says_how_many_are_left () =
  check (list string) "one held row, the count left out, the backlog line"
    [ "7200s task-1720"; "+3 more active"; "3 todo · oldest " ^ oldest_todo_seconds ]
    (drawn ~height:3 ~cursor:0);
  check (list string) "the window follows the cursor to the last held row"
    [ "60s task-1730"; "+3 more active"; "3 todo · oldest " ^ oldest_todo_seconds ]
    (drawn ~height:3 ~cursor:3);
  check (list string) "two rows give up the backlog line before the count"
    [ "7200s task-1720"; "+3 more active" ]
    (drawn ~height:2 ~cursor:0)

let test_rows_are_the_cursor_order () =
  check (list string) "the cursor indexes the drawn order"
    [ "task-1720"; "task-1710"; "task-1700"; "task-1730" ]
    (List.map (fun (task : Tui_decode.task) -> task.id) (Tasks.rows tasks));
  let indexes =
    Tasks.lines ~height:10 ~cursor:0 tasks backlog
    |> List.filter_map (function
         | Tasks.Task_row { index; _ } -> Some index
         | Tasks.More_active _ | Tasks.Nothing_active | Tasks.Todo_backlog _ ->
             None)
  in
  check (list int) "row indexes" [ 0; 1; 2; 3 ] indexes

let test_nothing_held_is_said () =
  let todo_only =
    List.filter
      (fun (task : Tui_decode.task) ->
        match task.status with
        | Masc_domain.Todo -> true
        | Masc_domain.Claimed _ | Masc_domain.InProgress _
        | Masc_domain.AwaitingVerification _ | Masc_domain.Done _
        | Masc_domain.Cancelled _ ->
            false)
      tasks
  in
  let text ~height =
    Tasks.lines ~height ~cursor:0 todo_only backlog
    |> List.filter_map (Tasks.summary_text ~age_text:seconds_text ~now)
  in
  check (list string) "said, then the backlog line"
    [ "no task in progress"; "3 todo · oldest " ^ oldest_todo_seconds ]
    (text ~height:2);
  check (list string) "one row keeps the backlog line"
    [ "3 todo · oldest " ^ oldest_todo_seconds ]
    (text ~height:1);
  check int "the layout asks for both lines" 2
    (Tasks.line_count todo_only backlog)

let () =
  run "tui_overview_tasks"
    [ ( "overview tasks",
        [ test_case "held work first" `Quick test_held_work_first
        ; test_case "a cut says how many are left" `Quick
            test_cut_says_how_many_are_left
        ; test_case "rows are the cursor order" `Quick
            test_rows_are_the_cursor_order
        ; test_case "nothing held is said" `Quick test_nothing_held_is_said
        ] )
    ]
