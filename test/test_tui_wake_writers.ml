(* Writers outside the main loop's fiber ring its bell when they change what
   the loop reads (RFC tui-idle-wait §2.1). Checked is the ring each writer
   leaves, read back from the process's one bell. *)

open Alcotest
module Wake = Masc_tui_wake

let rung source = List.mem source (Wake.take Wake.loop)

let test_mail_rings_the_mailbox () =
  Eio_mock.Backend.run (fun () ->
      let notifications = Eio.Stream.create 4 in
      ignore (Wake.take Wake.loop);
      Masc_tui_async_protocol.mail notifications "message";
      check bool "mailing a message rings Mailbox" true (rung Wake.Mailbox);
      check int "and queues it" 1 (Eio.Stream.length notifications))

let test_task_dispatch_rings_once_it_settles () =
  let module Dispatch = Masc_tui_task_dispatch in
  let dispatch = Dispatch.create
      { request_id = "r"; keeper = "k"; title = "t"; body = "b"; original = "o"; workspace = None } in
  ignore (Wake.take Wake.loop);
  Dispatch.reject dispatch "refused";
  check bool "a settled dispatch rings Task_dispatched" true (rung Wake.Task_dispatched);
  Dispatch.reject dispatch "again";
  check bool "a dispatch already settled does not ring again" false (rung Wake.Task_dispatched)

let test_console_write_rings () =
  ignore (Wake.take Wake.loop);
  Masc_tui_terminal_write_repair.note ();
  check bool "a console write rings Console_write" true (rung Wake.Console_write);
  check bool "and still marks the frame damaged" true (Masc_tui_terminal_write_repair.consume_damage ())

(* The writers below are the ones a fiber, a worker or a systhread reaches
   with no test of its own: removing the ring from any of them left every
   test above passing. *)

let test_preference_writer_rings_for_each_completion () =
  let module Writer = Masc_tui_preference_writer in
  let writer = Writer.create ~send:(fun _ -> Ok Writer.Unchanged) in
  let pick () = { Writer.token = ref (); change = Masc.Tui_preference.Help_hint_retired } in
  ignore (Wake.take Wake.loop);
  Queue.add (pick ()) writer.pending;
  Writer.run writer;
  check bool "a sent pick rings Preference_written" true (rung Wake.Preference_written);
  check int "and leaves its completion" 1 (Queue.length writer.completed);
  Queue.add (pick ()) writer.pending;
  Writer.refuse_pending writer "closing";
  check bool "a refused pick rings Preference_written" true (rung Wake.Preference_written)

let test_keeper_preference_writer_rings_without_a_switch () =
  let writer = Masc_tui_config.create_keeper_preference_writer () in
  ignore (Wake.take Wake.loop);
  ignore (Masc_tui_config.submit_keeper_preference writer ~on_request_id:ignore ~sw:None
            ~base_path:"/nonexistent" (Masc_tui_config.Keeper_order "name"));
  check bool "a choice that cannot start rings Keeper_preference_written" true
    (rung Wake.Keeper_preference_written);
  let drained = ref 0 in
  Masc_tui_config.drain_keeper_preferences writer ~can_take:(fun () -> true)
    ~apply:(fun _ -> incr drained);
  check int "and the loop finds its completion" 1 !drained

let test_ask_cells_ring_once_they_return () =
  let open Masc_tui_types in
  let receipt = Ask_answer_receipt.create () in
  ignore (Wake.take Wake.loop);
  ignore (Ask_answer_receipt.publish receipt ~observed_ns:1L (Error (Request_failed "lost")));
  check bool "a receipt rings Ask_answer_receipt" true (rung Wake.Ask_answer_receipt);
  ignore (Ask_answer_receipt.publish receipt ~observed_ns:2L (Error (Request_failed "again")));
  check bool "a cell already returned does not ring again" false (rung Wake.Ask_answer_receipt);
  let completion = Ask_answer_completion.create () in
  ignore (Ask_answer_completion.publish completion ~observed_ns:3L
            ~receipt:(Error (Request_failed "lost")) ~asks:(Error "unread"));
  check bool "a completion rings Ask_answer_completion" true (rung Wake.Ask_answer_completion);
  let closed = Ask_answer_receipt.create () in
  Ask_answer_receipt.close closed;
  check bool "closing without a result rings nothing" false (rung Wake.Ask_answer_receipt)

let test_history_read_rings_for_rows_and_page () =
  let open Masc_tui_types in
  let read = Keeper_history_read.create ~generation:1 ~keeper:"k"
      ~authority:(Workspace_authority 1) ~reading:(ref ()) ~first_page:true in
  ignore (Wake.take Wake.loop);
  Keeper_history_read.publish read Keeper_history_read.History ~ready_at_ns:1L
    (Error (Request_failed "lost"));
  check bool "history rows ring History_read" true (rung Wake.History_read);
  Keeper_history_read.publish_page read ~ready_at_ns:2L (Error (Request_failed "lost"));
  check bool "the first page rings History_read" true (rung Wake.History_read)

(* A drain whose budget is spent notes that the next pass is owed at once
   (RFC tui-idle-wait §2.2). The delivery round asks that budget only with an
   item in hand, so a [false] always leaves work and an idle round never
   buys a pass with nothing in it. *)
let test_delivery_round_asks_the_budget_only_with_an_item () =
  let module Round = Masc_tui_async_protocol.Delivery_round in
  let shared = Queue.create () and owned = ref [] and asked = ref 0 in
  let take ~budget round =
    Round.take round
      ~can_take:(fun () -> incr asked; budget)
      ~queued:(fun () -> Queue.length shared)
      ~take_shared:(fun () -> Queue.take_opt shared)
      ~collect_owned:(fun () -> let ready = !owned in owned := []; ready) in
  let ready, round = take ~budget:false Round.empty in
  check (option string) "nothing queued or owned gives nothing" None ready;
  check int "and never asks the budget" 0 !asked;
  Queue.add "queued" shared;
  let ready, round = take ~budget:false round in
  check (option string) "a spent budget leaves a queued item" None ready;
  check int "asked once, with the item in hand" 1 !asked;
  let ready, round = take ~budget:true round in
  check (option string) "the next pass takes it" (Some "queued") ready;
  owned := [ "owned" ];
  asked := 0;
  let ready, round = take ~budget:false round in
  check (option string) "a spent budget leaves a collected result" None ready;
  check int "asked once, with the result in hand" 1 !asked;
  let ready, round = take ~budget:true round in
  check (option string) "the next pass hands it on" (Some "owned") ready;
  asked := 0;
  let ready, _ = take ~budget:false round in
  check (option string) "the round ends" None ready;
  check int "without asking" 0 !asked

let () =
  run "tui_wake_writers"
    [ ("writers",
       [ test_case "mail rings the mailbox" `Quick test_mail_rings_the_mailbox;
         test_case "task dispatch rings once it settles" `Quick test_task_dispatch_rings_once_it_settles;
         test_case "console write rings" `Quick test_console_write_rings;
         test_case "preference writer rings" `Quick test_preference_writer_rings_for_each_completion;
         test_case "keeper preference writer rings" `Quick
           test_keeper_preference_writer_rings_without_a_switch;
         test_case "ask cells ring" `Quick test_ask_cells_ring_once_they_return;
         test_case "history read rings" `Quick test_history_read_rings_for_rows_and_page ]);
      ("drain budget",
       [ test_case "the delivery round asks the budget only with an item" `Quick
           test_delivery_round_asks_the_budget_only_with_an_item ]) ]
