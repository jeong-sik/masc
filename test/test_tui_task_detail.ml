(** Task-detail lookup on the Overview surface (#29684).

    The detail view reads the same domain rows the Overview list was
    projected from, so these tests pin the two behaviors the fallback
    depends on: an id that left the backlog answers [None] (the renderer
    then draws the list, like Board and Planning detail), and a row that
    is terminal but still present answers [Some] (the active list would
    have dropped it, the detail must not). *)

open Alcotest

module Selection = Masc_tui_task_selection

let domain_task ~id ~(status : Masc_domain.task_status) () :
    Masc_domain.task =
  { Masc_domain.
    id
  ; title = "title " ^ id
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-08-23T00:00:00Z"
  ; created_by = Some "producer"
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Masc_domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }

let detail_row ~detail_id tasks =
  Selection.detail_row ~detail_id ~tasks

let task_option =
  testable
    (fun fmt -> function
      | None -> Format.fprintf fmt "None"
      | Some (task : Masc_domain.task) ->
          Format.fprintf fmt "Some %s" task.Masc_domain.id)
    ( = )

let claimed =
  Masc_domain.Claimed { assignee = "agent"; claimed_at = "2026-08-23T01:00:00Z" }

let test_detail_finds_open_id () =
  check task_option "claimed task found by id"
    (Some (domain_task ~id:"task-2" ~status:claimed ()))
    (detail_row ~detail_id:(Some "task-2")
       [ domain_task ~id:"task-1" ~status:Masc_domain.Todo ()
       ; domain_task ~id:"task-2" ~status:claimed ()
       ])

let test_detail_id_left_backlog_answers_none () =
  check task_option "id no longer in backlog answers None" None
    (detail_row ~detail_id:(Some "task-gone")
       [ domain_task ~id:"task-1" ~status:Masc_domain.Todo () ])

let test_no_detail_open_answers_none () =
  check task_option "no detail open answers None" None
    (detail_row ~detail_id:None
       [ domain_task ~id:"task-1" ~status:Masc_domain.Todo () ])

let test_terminal_row_still_reachable () =
  (* The Overview list drops terminal rows; the detail view must not, or a
     task that finishes while its detail is open would blank the screen. *)
  let cancelled =
    Masc_domain.Cancelled
      { cancelled_by = "operator"; cancelled_at = "2026-08-23T02:00:00Z"
      ; reason = Some "superseded" }
  in
  check task_option "terminal task still found by id"
    (Some (domain_task ~id:"task-9" ~status:cancelled ()))
    (detail_row ~detail_id:(Some "task-9")
       [ domain_task ~id:"task-9" ~status:cancelled () ])

let () =
  run "tui task detail"
    [ ( "lookup"
      , [ test_case "detail finds open id" `Quick test_detail_finds_open_id
        ; test_case "id that left the backlog answers none" `Quick
            test_detail_id_left_backlog_answers_none
        ; test_case "no detail open answers none" `Quick
            test_no_detail_open_answers_none
        ; test_case "terminal row still reachable" `Quick
            test_terminal_row_still_reachable
        ] )
    ]
