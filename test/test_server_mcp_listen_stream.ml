open Alcotest
module Listen = Server_mcp_listen_stream

let stalled_after_s = 100.0
let ping_interval_s = 30.0
let max_queued_events = 4

(* More than the stream's queue holds, plus the one its sender is writing. *)
let notifications_beyond_the_queue = max_queued_events + 2

(* Scheduler turns for the stream's fibers to write what they have. *)
let settle_turns = 32

let filter =
  { Mcp_transport_protocol.tools_list_changed = true
  ; prompts_list_changed = false
  ; resources_list_changed = false
  ; resource_subscriptions = []
  }
;;

let tools_changed =
  Mcp_transport_protocol.jsonrpc_notification "notifications/tools/list_changed"
;;

type client =
  { connection : Httpun.Server_connection.t
  ; received : Buffer.t
  }

(* An in-memory httpun connection answered by [Listen.serve] in a fiber of
   [sw]. A written byte reaches the client only when the test takes it, so a
   client that stops reading is one the test stops taking from. *)
let open_stream ~sw ~clock ~id =
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Eio.Fiber.fork ~sw (fun () ->
        Listen.serve ~clock ~ping_interval_s ~stalled_after_s ~max_queued_events
          ~subscription_id:(`Int id) ~filter
          ~headers:(Httpun.Headers.of_list [ "content-type", "text/event-stream" ])
          reqd))
  in
  let raw = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
  ignore (Httpun.Server_connection.read connection input ~off:0 ~len:(String.length raw) : int);
  { connection; received = Buffer.create 256 }
;;

let rec take_writes client =
  match Httpun.Server_connection.next_write_operation client.connection with
  | `Write iovecs ->
    let length =
      List.fold_left
        (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
           Buffer.add_string client.received
             (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
           total + iov.len)
        0 iovecs
    in
    Httpun.Server_connection.report_write_result client.connection (`Ok length);
    take_writes client
  | `Yield | `Close _ -> ()
;;

(* Lets every stream's fibers run, and [client] reads all they write. *)
let read_all client =
  for _ = 1 to settle_turns do
    Eio.Fiber.yield ();
    take_writes client
  done
;;

let occurrences ~needle text =
  let n = String.length needle in
  let rec count from acc =
    match Str.search_forward (Str.regexp_string needle) text from with
    | at -> count (at + n) (acc + 1)
    | exception Not_found -> acc
  in
  count 0 0
;;

let position ~needle text =
  match Str.search_forward (Str.regexp_string needle) text 0 with
  | at -> at
  | exception Not_found -> failf "%S was not written" needle
;;

(* Ends every stream on [sw] the way a cancelled request does. *)
let with_streams f =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let before = Mcp_subscriptions.count () in
    (match
       Eio.Switch.run (fun sw ->
         f ~sw ~clock ~before;
         Eio.Switch.fail sw Exit)
     with
     | () -> fail "the switch should have failed"
     | exception Exit -> ());
    check int "every subscription is removed with its stream" before (Mcp_subscriptions.count ()))
;;

let test_the_acknowledgement_comes_first_and_notifications_follow () =
  with_streams (fun ~sw ~clock ~before ->
    let client = open_stream ~sw ~clock ~id:1 in
    read_all client;
    check int "subscribed while the stream runs" (before + 1) (Mcp_subscriptions.count ());
    Mcp_subscriptions.notify_tools_list_changed tools_changed;
    read_all client;
    let text = Buffer.contents client.received in
    let retry = position ~needle:"retry:" text in
    let acknowledged = position ~needle:"notifications/subscriptions/acknowledged" text in
    let changed = position ~needle:"notifications/tools/list_changed" text in
    check bool "the retry frame, then the acknowledgement, then the notification" true
      (retry < acknowledged && acknowledged < changed))
;;

(* The second client reads nothing after its acknowledgement. Each delivery
   returns at once and the reading client gets every notification; the idle
   stream ends when its frame has waited [stalled_after_s]. *)
let test_a_client_that_stops_reading_holds_up_no_other_subscription () =
  with_streams (fun ~sw ~clock ~before ->
    let reading = open_stream ~sw ~clock ~id:2 in
    let idle = open_stream ~sw ~clock ~id:3 in
    read_all reading;
    read_all idle;
    for _ = 1 to notifications_beyond_the_queue do
      Mcp_subscriptions.notify_tools_list_changed tools_changed;
      read_all reading
    done;
    check int "the reading client got every notification" notifications_beyond_the_queue
      (occurrences ~needle:"notifications/tools/list_changed" (Buffer.contents reading.received));
    check int "the idle stream is still subscribed before its bound" (before + 2)
      (Mcp_subscriptions.count ());
    Eio_mock.Clock.set_time clock stalled_after_s;
    read_all reading;
    check int "the idle stream ended at its bound" (before + 1) (Mcp_subscriptions.count ()))
;;

(* The notifications arrive before the stream's sender runs again. The
   sender is waiting on the queue, so the first one goes straight to it; the
   rest are one more than the queue holds. The sender writes the one it took,
   then sees the pile-up and ends, without the clock moving: it ended as
   [Fell_behind] and not at the stall bound. Nothing queued is written. *)
let test_a_client_that_falls_behind_is_closed_at_once () =
  with_streams (fun ~sw ~clock ~before ->
    let client = open_stream ~sw ~clock ~id:4 in
    read_all client;
    check int "subscribed while the stream runs" (before + 1) (Mcp_subscriptions.count ());
    for _ = 1 to max_queued_events + 2 do
      Mcp_subscriptions.notify_tools_list_changed tools_changed
    done;
    read_all client;
    check int "the stream ended and left the subscriptions" before (Mcp_subscriptions.count ());
    check int "only the notification the sender took was written" 1
      (occurrences ~needle:"notifications/tools/list_changed" (Buffer.contents client.received)))
;;

let () =
  run
    "server_mcp_listen_stream"
    [ ( "listen"
      , [ test_case "the acknowledgement comes first and notifications follow" `Quick
            test_the_acknowledgement_comes_first_and_notifications_follow
        ; test_case "a client that stops reading holds up no other subscription" `Quick
            test_a_client_that_stops_reading_holds_up_no_other_subscription
        ; test_case "a client that falls behind is closed at once" `Quick
            test_a_client_that_falls_behind_is_closed_at_once
        ] )
    ]
;;
