(** The queue is wired into the two places that make it work.

    The pure ordering and cap live in [Masc_tui_keeper_chat_queue] and are
    tested there. What cannot be tested there is that the executable actually
    uses it: a queue nothing pushes to is a refusal with extra steps, and a
    queue nothing drains is a message that never arrives. Both were the bug —
    Enter during a turn answered "Keeper message already in progress" and threw
    the text away. *)

open Alcotest

let calls ~module_path ~callee = Ast_grep.count_calls ~module_path ~callee

let test_enter_during_a_turn_queues () =
  let n = calls ~module_path:"bin/masc_tui.ml" ~callee:"queue_keeper_message" in
  if n < 1 then
    failf
      "bin/masc_tui.ml must queue a message typed while a turn is running; \
       queue_keeper_message is called %d time(s)"
      n
;;

let test_a_settled_turn_drains_the_queue () =
  let n = calls ~module_path:"bin/masc_tui.ml" ~callee:"drain_queued_message" in
  if n < 1 then
    failf
      "bin/masc_tui.ml must drain the queue when a turn settles; \
       drain_queued_message is called %d time(s)"
      n
;;

(* Cancel (Ctrl-K) and edit (Ctrl-P) both act on the newest waiting line, so
   the take-newest operation has to return exactly the last-pushed pair and
   leave the drain order of everything older untouched. *)
let test_take_newest_returns_last_and_keeps_order () =
  check bool "empty queue has no newest" true
    (Masc_tui_keeper_chat_queue.take_newest
       Masc_tui_keeper_chat_queue.empty
     = None);
  (* [fun q -> match …] in a [|>] chain swallows the rest of the chain into
     the match, so the stages are a plain application instead. *)
  let push_ok queue keeper text =
    match Masc_tui_keeper_chat_queue.push queue ~keeper_name:keeper text with
    | Ok (next, _) -> next
    | Error detail -> failf "push failed: %s" detail
  in
  let queue =
    push_ok
      (push_ok
         (push_ok Masc_tui_keeper_chat_queue.empty "a" "first")
         "b" "second")
      "c" "third"
  in
  match Masc_tui_keeper_chat_queue.take_newest queue with
  | None -> failf "take_newest returned None with three waiting"
  | Some ((keeper, text), rest) ->
      check string "newest pair is the last pushed" "c" keeper;
      check string "newest text is the last pushed" "third" text;
      check int "drain order of the rest is untouched" 2
        (Masc_tui_keeper_chat_queue.length rest);
      (match
         Masc_tui_keeper_chat_queue.take_first_sendable rest
           ~sendable:(fun _ -> true)
       with
       | Some (("a", "first"), remaining) ->
           check bool "oldest still drains first" true
             (Masc_tui_keeper_chat_queue.waiting remaining
              = [ ("b", "second") ])
       | _ -> failf "oldest no longer drains first after take_newest")
;;

(* The pane draws one row per waiting line. The row budget that sizes the
   history has to count those rows: the frame presenter drops whatever runs
   past the last terminal row, so a pane that came out taller by the number of
   waiting lines loses its bottom and the prompt slides out from under the
   caret. That was the bug -- the queue rows were drawn and never counted. *)
let test_the_row_budget_counts_the_queue () =
  let n =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui_types.ml"
      ~binding_name:"keeper_message_status_rows"
      ~callee:"Masc_tui_keeper_chat_queue.waiting"
  in
  if n < 1 then
    failf
      "keeper_message_status_rows must count the rows the pane draws for \
       waiting lines; Masc_tui_keeper_chat_queue.waiting is called %d time(s)"
      n
;;

(* The footer says what Enter does, and it has to say what Enter actually
   does. It used to work that out from [msg_inflight_kind] while the send path
   read the durable fences first, so a request being reconciled or cleaned up
   drew "queued 1" and [Enter:blocked] on the same screen. Both now read
   [send_disposition], which is where the order lives. *)
let test_both_readers_share_one_disposition () =
  List.iter
    (fun (module_path, what) ->
      let n = calls ~module_path ~callee:"send_disposition" in
      if n < 1 then
        failf
          "%s must decide %s from send_disposition, not from its own reading            of the state; it is called %d time(s)"
          module_path what n)
    [ ("bin/masc_tui.ml", "what Enter does")
    ; ("bin/masc_tui_render.ml", "what the footer says Enter does")
    ]
;;

(* The rows that say a request is being sent have to say how long for. A turn
   running minutes is ordinary, and without an age those rows read the same at
   three seconds and at thirteen minutes -- which is the difference between
   slow and stuck. The age is computed where it can be tested; this pins that
   the pane actually asks for it. *)
let test_the_sending_rows_show_an_age () =
  let n =
    calls ~module_path:"bin/masc_tui_render.ml"
      ~callee:"Message_layout.age_text"
  in
  if n < 1 then
    failf
      "bin/masc_tui_render.ml must age the rows it draws for a request in \
       flight; Message_layout.age_text is called %d time(s)"
      n
;;

let () =
  run
    "tui_chat_queue_wiring"
    [ ( "wiring"
      , [ test_case "Enter during a turn queues" `Quick
            test_enter_during_a_turn_queues
        ; test_case "a settled turn drains the queue" `Quick
            test_a_settled_turn_drains_the_queue
        ; test_case "the row budget counts the queue" `Quick
            test_the_row_budget_counts_the_queue
        ; test_case "both readers share one disposition" `Quick
            test_both_readers_share_one_disposition
        ; test_case "the sending rows show an age" `Quick
            test_the_sending_rows_show_an_age
        ] )
    ; ( "queue"
      , [ test_case "take_newest returns the last and keeps order" `Quick
            test_take_newest_returns_last_and_keeps_order ] )
    ]
;;
