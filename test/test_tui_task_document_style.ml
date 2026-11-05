(** What the Task document does with styles, not where it puts them.

    A row the document prepares carries a style only when the document put it
    there, and a style never outlives its row. Neither check reads a width, a
    heading or a label: the constitution keeps those out of tests, and the
    screen captures in the pull request are the evidence for them. *)

open Alcotest

module Document = Masc_tui_task_document

let reset = Masc_tui_ansi.Ansi.reset

(* A sequence the document itself never draws: the red a task's own text
   might ask for. *)
let hostile_style = "\027[31m"

let todo = Masc_domain.Todo

let claimed =
  Masc_domain.Claimed { assignee = "agent"; claimed_at = "2026-11-05T01:00:00Z" }

let in_progress =
  Masc_domain.InProgress { assignee = "agent"; started_at = "2026-11-05T01:00:00Z" }

let awaiting_verification =
  Masc_domain.AwaitingVerification
    { assignee = "agent"
    ; started_at = "2026-11-05T01:00:00Z"
    ; submitted_at = "2026-11-05T02:00:00Z"
    ; verification_id = "verification-1"
    }

let done_ =
  Masc_domain.Done
    { assignee = "agent"; completed_at = "2026-11-05T03:00:00Z"; notes = Some "shipped" }

let cancelled =
  Masc_domain.Cancelled
    { cancelled_by = "operator"
    ; cancelled_at = "2026-11-05T03:00:00Z"
    ; reason = Some "superseded"
    }

let task ~title ~created_by ~status : Masc_domain.task =
  { Masc_domain.
    id = "task-1"
  ; title
  ; description = "first line\nsecond line"
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-11-05T00:00:00Z"
  ; created_by
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Masc_domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 0
  ; skills = []
  }

let body_rows ~cols task =
  Document.prepare (Document.body ~cols ~goals:(Document.Membership [ "goal-1" ]) task)

let contains ~affix text =
  let affix_length = String.length affix in
  let rec from index =
    index + affix_length <= String.length text
    && (String.equal (String.sub text index affix_length) affix || from (index + 1))
  in
  from 0

let every_status =
  [ todo; claimed; in_progress; awaiting_verification; done_; cancelled ]

let test_task_text_cannot_put_a_style_on_a_row () =
  List.iter
    (fun status ->
      let rows =
        body_rows ~cols:100
          (task ~title:("before " ^ hostile_style ^ "after") ~created_by:(Some hostile_style)
             ~status)
      in
      check bool "the sequence a task's text carries reaches no row" false
        (List.exists (contains ~affix:hostile_style) rows))
    every_status

let check_every_style_is_reset rows =
  List.iter
    (fun row ->
      if String.contains row '\027' then
        check bool "a row that carries a style ends by resetting it" true
          (String.ends_with ~suffix:reset row))
    rows

let test_a_style_ends_with_its_row () =
  List.iter
    (fun status ->
      List.iter
        (fun cols ->
          check_every_style_is_reset
            (body_rows ~cols (task ~title:"a title" ~created_by:(Some "producer") ~status)))
        [ 40; 100; 200 ])
    every_status

let test_the_history_heading_ends_with_its_row () =
  List.iter
    (fun width -> check_every_style_is_reset (Document.history_heading_rows ~width))
    [ 10; 40; 120 ]

let () =
  run "tui task document style"
    [ ( "style"
      , [ test_case "task text cannot put a style on a row" `Quick
            test_task_text_cannot_put_a_style_on_a_row
        ; test_case "a style ends with its row" `Quick test_a_style_ends_with_its_row
        ; test_case "the history heading ends with its row" `Quick
            test_the_history_heading_ends_with_its_row
        ] )
    ]
