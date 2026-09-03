(** The execution payload's "recent" terminal tasks are the newest ones.

    The selection filtered by a 24h window and then truncated in backlog order,
    which is insertion order. Once more than the limit ended inside the window
    the surfaced rows were the oldest of them, because new tasks append — so a
    panel labelled "recent" omitted exactly the entries an operator opened it
    for. These tests pin the ordering, the bound, and the two exclusions. *)

open Alcotest
open Masc_domain

module DE = Dashboard_execution

(* 2026-08-04T00:00:00Z, so the fixtures below read as wall-clock times rather
   than offsets from a moving [now]. *)
let base_unix = 1785801600.0
let cutoff = base_unix -. 86_400.0

let iso_at offset_seconds =
  let seconds = int_of_float (base_unix +. offset_seconds) in
  let tm = Unix.gmtime (float_of_int seconds) in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900)
    (tm.tm_mon + 1)
    tm.tm_mday
    tm.tm_hour
    tm.tm_min
    tm.tm_sec
;;

let task ~id ~status =
  { id
  ; title = "Task " ^ id
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = iso_at (-100_000.0)
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

let done_at ~id ~offset =
  task ~id ~status:(Done { assignee = "keeper-a"; completed_at = iso_at offset; notes = None })
;;

let cancelled_at ~id ~offset =
  task
    ~id
    ~status:
      (Cancelled
         { cancelled_by = "keeper-b"; cancelled_at = iso_at offset; reason = Some "blocked" })
;;

let ids tasks = List.map (fun (t : task) -> t.id) tasks

let select tasks = DE.recent_terminal_tasks ~cutoff tasks

let test_orders_newest_first_regardless_of_backlog_order () =
  (* Backlog order is insertion order and says nothing about when a task ended:
     an old task can be cancelled a minute ago. *)
  let selected =
    select
      [ done_at ~id:"task-oldest" ~offset:(-80_000.0)
      ; cancelled_at ~id:"task-newest" ~offset:(-60.0)
      ; done_at ~id:"task-middle" ~offset:(-3_600.0)
      ]
  in
  check (list string) "newest terminal timestamp first"
    [ "task-newest"; "task-middle"; "task-oldest" ]
    (ids selected)
;;

let test_truncation_keeps_the_newest_not_the_first_inserted () =
  (* One more than the limit inside the window: the dropped row must be the
     oldest, not whichever happened to be appended last. *)
  let overflow = DE.recent_terminal_limit + 1 in
  let tasks =
    List.init overflow (fun i ->
      (* Index 0 is the oldest and is inserted first, mirroring append order. *)
      done_at
        ~id:(Printf.sprintf "task-%02d" i)
        ~offset:(-80_000.0 +. (float_of_int i *. 60.0)))
  in
  let selected = select tasks in
  check int "bounded by the limit" DE.recent_terminal_limit (List.length selected);
  check string "head is the newest" (Printf.sprintf "task-%02d" (overflow - 1))
    (List.hd (ids selected));
  check bool "the oldest is the one dropped" false
    (List.exists (String.equal "task-00") (ids selected))
;;

let test_excludes_non_terminal_and_out_of_window () =
  let selected =
    select
      [ task ~id:"task-todo" ~status:Todo
      ; task ~id:"task-claimed" ~status:(Claimed { assignee = "k"; claimed_at = iso_at (-60.0) })
      ; task
          ~id:"task-wip"
          ~status:(InProgress { assignee = "k"; started_at = iso_at (-60.0) })
      ; task
          ~id:"task-verify"
          ~status:
            (AwaitingVerification
               { assignee = "k"
               ; started_at = iso_at (-120.0)
               ; submitted_at = iso_at (-60.0)
               ; intent = Complete_task
               ; verification_id = "vrf-1"
               })
      ; done_at ~id:"task-stale" ~offset:(-90_000.0)
      ; done_at ~id:"task-inside" ~offset:(-60.0)
      ]
  in
  check (list string) "only terminal tasks inside the window" [ "task-inside" ] (ids selected)
;;

(* A row whose terminal timestamp does not parse belongs to neither the window
   nor the ordering, so it is left out rather than pinned to an invented time. *)
let test_unparseable_timestamp_is_excluded () =
  let selected =
    select
      [ task ~id:"task-bad" ~status:(Done { assignee = "k"; completed_at = "not-a-date"; notes = None })
      ; done_at ~id:"task-good" ~offset:(-60.0)
      ]
  in
  check (list string) "unparseable terminal timestamp is dropped" [ "task-good" ] (ids selected)
;;

(* Cancellations are terminal and belong in the same window as completions;
   dropping them here would hide them from the payload entirely. *)
let test_cancellations_are_interleaved_with_completions () =
  let selected =
    select
      [ done_at ~id:"task-done-old" ~offset:(-7_200.0)
      ; cancelled_at ~id:"task-cancelled-new" ~offset:(-60.0)
      ; done_at ~id:"task-done-new" ~offset:(-120.0)
      ; cancelled_at ~id:"task-cancelled-old" ~offset:(-10_800.0)
      ]
  in
  check (list string) "both terminal kinds ordered together"
    [ "task-cancelled-new"; "task-done-new"; "task-done-old"; "task-cancelled-old" ]
    (ids selected)
;;

let () =
  run
    "dashboard recent terminal tasks"
    [ ( "ordering"
      , [ test_case "newest first regardless of backlog order" `Quick
            test_orders_newest_first_regardless_of_backlog_order
        ; test_case "truncation keeps the newest" `Quick
            test_truncation_keeps_the_newest_not_the_first_inserted
        ; test_case "cancellations interleave with completions" `Quick
            test_cancellations_are_interleaved_with_completions
        ] )
    ; ( "exclusions"
      , [ test_case "non-terminal and out-of-window" `Quick
            test_excludes_non_terminal_and_out_of_window
        ; test_case "unparseable timestamp" `Quick test_unparseable_timestamp_is_excluded
        ] )
    ]
;;
