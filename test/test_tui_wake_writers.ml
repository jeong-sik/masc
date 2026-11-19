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

let () =
  run "tui_wake_writers"
    [ ("writers",
       [ test_case "mail rings the mailbox" `Quick test_mail_rings_the_mailbox;
         test_case "task dispatch rings once it settles" `Quick test_task_dispatch_rings_once_it_settles;
         test_case "console write rings" `Quick test_console_write_rings ]) ]
