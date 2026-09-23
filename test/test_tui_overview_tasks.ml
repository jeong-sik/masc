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
let drawn ~height ~selected =
  Tasks.lines ~height ~selected tasks backlog
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
    (drawn ~height:10 ~selected:(Some 0))

let test_cut_says_how_many_are_left () =
  check (list string) "one held row, the count left out, the backlog line"
    [ "7200s task-1720"; "+3 more active"; "3 todo · oldest " ^ oldest_todo_seconds ]
    (drawn ~height:3 ~selected:None);
  check (list string) "the window follows the selection to the last held row"
    [ "60s task-1730"; "+3 more active"; "3 todo · oldest " ^ oldest_todo_seconds ]
    (drawn ~height:3 ~selected:(Some 3));
  check (list string) "two rows give up the backlog line before the count"
    [ "7200s task-1720"; "+3 more active" ]
    (drawn ~height:2 ~selected:(Some 0))

let test_rows_are_the_drawn_order () =
  check (list string) "rows are the drawn order"
    [ "task-1720"; "task-1710"; "task-1700"; "task-1730" ]
    (List.map (fun (task : Tui_decode.task) -> task.id) (Tasks.rows tasks));
  let indexes =
    Tasks.lines ~height:10 ~selected:None tasks backlog
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
    Tasks.lines ~height ~selected:None todo_only backlog
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

(* The selection is an id. The palette, a followed link, the agenda and
   the change view all set it to the opened task's id; the renderer, Enter
   and Ctrl-] look its row up in the rows of that moment. *)
let selected_id tasks ~selected =
  Option.map
    (fun (task : Tui_decode.task) -> task.id)
    (Tasks.selected_task tasks ~selected)

let test_open_todo_highlights_nothing () =
  let selected = Some "task-1501" in
  check (option int) "a todo task opened from the palette has no row" None
    (Tasks.selected_index tasks ~selected);
  check (option string) "Enter and Ctrl-] name nothing" None
    (selected_id tasks ~selected);
  check (option string) "j from there goes to the first row"
    (Some "task-1720")
    (Tasks.step tasks ~selected Tasks.Next)

let test_open_held_task_highlights_its_row () =
  let selected = Some "task-1710" in
  check (option int) "an in-progress task opened from a link is its row"
    (Some 1)
    (Tasks.selected_index tasks ~selected);
  check (option string) "j moves to its neighbour" (Some "task-1700")
    (Tasks.step tasks ~selected Tasks.Next);
  check (option string) "k moves to the row above" (Some "task-1720")
    (Tasks.step tasks ~selected Tasks.Previous)

(* One poll: task-1720, above the selected row, finishes and leaves the
   list. Every row below it moves up one. *)
let after_poll_without id =
  List.filter (fun (task : Tui_decode.task) -> not (String.equal task.id id)) tasks

let test_a_poll_does_not_move_the_selection () =
  let selected = Some "task-1700" in
  check (option int) "before the poll" (Some 2)
    (Tasks.selected_index tasks ~selected);
  let polled = after_poll_without "task-1720" in
  check (option int) "its row moved up" (Some 1)
    (Tasks.selected_index polled ~selected);
  check (option string) "Enter and Ctrl-] still name the same task"
    (Some "task-1700")
    (selected_id polled ~selected)

let test_a_finished_selection_selects_nothing () =
  let selected = Some "task-1700" in
  let polled = after_poll_without "task-1700" in
  check (option int) "no row is highlighted" None
    (Tasks.selected_index polled ~selected);
  check (option string) "Enter and Ctrl-] name nothing" None
    (selected_id polled ~selected)

let () =
  run "tui_overview_tasks"
    [ ( "overview tasks",
        [ test_case "held work first" `Quick test_held_work_first
        ; test_case "a cut says how many are left" `Quick
            test_cut_says_how_many_are_left
        ; test_case "rows are the drawn order" `Quick
            test_rows_are_the_drawn_order
        ; test_case "nothing held is said" `Quick test_nothing_held_is_said
        ; test_case "an open todo task highlights no row" `Quick
            test_open_todo_highlights_nothing
        ; test_case "an open held task highlights its row" `Quick
            test_open_held_task_highlights_its_row
        ; test_case "a poll does not move the selection" `Quick
            test_a_poll_does_not_move_the_selection
        ; test_case "a finished selection selects nothing" `Quick
            test_a_finished_selection_selects_nothing
        ] )
    ]
