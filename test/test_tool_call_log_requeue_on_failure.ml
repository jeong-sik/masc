(** A queued tool-call row is not lost when its write is cut.

    [drain_queued_appends] takes an entry out of the queue and then writes it.
    [append_to_store_result] re-raises [Eio.Cancel.Cancelled] on purpose, to
    keep it apart from the failures it counts, and the flush daemon's
    [Cancelled -> ()] arm swallowed it — one row gone per cancellation, with no
    counter and no log line (masc#30619).

    This pins the wiring: the drain puts the entry back before the exception
    leaves. That re-marking on failure is what keeps data scheduled is the
    behaviour, and it is pinned end to end by
    [test_board_vote_persistence]'s "flush: cancellation cannot cut the write",
    against the writer that already had this shape (#26168). Driving the async
    daemon here to observe one queue slot would prove less at more cost.

    [Ast_grep] rather than a substring: this file names both identifiers in the
    paragraphs above, and a text search would count them. *)

open Alcotest

let module_path = "lib/keeper_tool_call_log.ml"

let calls ~binding_name ~callee =
  Ast_grep.count_calls_in_value_binding ~module_path ~binding_name ~callee
;;

let test_drain_requeues_before_reraising () =
  check
    int
    "the drain puts a failed entry back on the queue"
    1
    (calls ~binding_name:"drain_queued_appends" ~callee:"requeue_append_front");
  check
    bool
    "and the failure still leaves the drain"
    true
    (calls ~binding_name:"drain_queued_appends" ~callee:"Printexc.raise_with_backtrace" >= 1)
;;

(* Order is the reason for the transfer dance: a plain [Queue.add] would put the
   retried row behind everything enqueued since, and a tool-call log read in
   order would show the retry after rows that happened later. *)
let test_requeue_restores_order () =
  check
    bool
    "the requeue rebuilds the queue rather than appending at the back"
    true
    (calls ~binding_name:"requeue_append_front" ~callee:"Stdlib.Queue.transfer" = 2)
;;

let () =
  run
    "tool call log requeue on failure"
    [ ( "drain"
      , [ test_case "requeues before re-raising" `Quick test_drain_requeues_before_reraising
        ; test_case "requeue restores order" `Quick test_requeue_restores_order
        ] )
    ]
;;
