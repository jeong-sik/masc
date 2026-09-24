(* One CDP connection driven over a fake transport: frames the connection
   writes are collected, frames the browser would send are fed to [receive].
   The mock clock stands for the command deadline. *)
open Alcotest
module Cdp = Masc.Browser_cdp

let deadline_s = 5.0

let with_connection f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  let sent = ref [] and events = ref [] and closes = ref 0 in
  let t =
    Cdp.create ~send:(fun frame -> sent := Yojson.Safe.from_string frame :: !sent)
      ~close:(fun () -> incr closes) ~clock ~command_deadline_s:deadline_s
      ~on_event:(fun event -> events := event :: !events)
  in
  Eio.Switch.run @@ fun sw -> f ~sw ~clock ~t ~sent ~events ~closes
;;

let member key json = Yojson.Safe.Util.member key json
let sent_id json = Yojson.Safe.Util.to_int (member "id" json)

let failure = testable (fun fmt -> function
  | Cdp.Command_rejected { code; message } -> Format.fprintf fmt "rejected %d %s" code message
  | Cdp.Connection_lost reason -> Format.fprintf fmt "lost: %s" reason) ( = )

let reply = result (testable Yojson.Safe.pp Yojson.Safe.equal) failure

let test_decode () =
  let ok = function Ok envelope -> envelope | Error detail -> failf "decode: %s" detail in
  (match ok (Cdp.decode {|{"id":3,"result":{"a":1}}|}) with
   | Cdp.Reply { id = 3; result = Ok (`Assoc [ "a", `Int 1 ]) } -> ()
   | _ -> fail "a result reply");
  (match ok (Cdp.decode {|{"id":4,"error":{"code":-32601,"message":"no"}}|}) with
   | Cdp.Reply { id = 4; result = Error (-32601, "no") } -> ()
   | _ -> fail "an error reply");
  (match ok (Cdp.decode {|{"method":"Target.targetDestroyed","sessionId":"S"}|}) with
   | Cdp.Event { method_ = "Target.targetDestroyed"; session = Some "S"; params = `Assoc [] } -> ()
   | _ -> fail "an event without params has empty params");
  List.iter (fun frame -> check bool frame true (Result.is_error (Cdp.decode frame)))
    [ "not json"; {|{"id":1}|}; {|{"id":1,"result":{},"error":{"code":1,"message":"x"}}|};
      {|{"id":1,"error":{"message":"no code"}}|}; {|{"params":{}}|} ]
;;

let test_events () =
  let event method_ params = Cdp.event_of ~method_ ~session:(Some "W") (Yojson.Safe.from_string params) in
  (match event "Runtime.bindingCalled" {|{"name":"__stagehandSendToHost","payload":"{}","executionContextId":1}|} with
   | Cdp.Binding_called { session = Some "W"; name = "__stagehandSendToHost"; payload = "{}" } -> ()
   | _ -> fail "binding call");
  (match event "Target.targetCreated" {|{"targetInfo":{"targetId":"T","type":"service_worker","url":"chrome-extension://x/sw.js"}}|} with
   | Cdp.Target_created { target_id = "T"; kind = Cdp.Service_worker; _ } -> ()
   | _ -> fail "service worker target");
  (match event "Target.targetCreated" {|{"targetInfo":{"targetId":"T","type":"iframe","url":""}}|} with
   | Cdp.Target_created { kind = Cdp.Other_kind "iframe"; _ } -> ()
   | _ -> fail "other targets keep their type");
  (match event "Target.detachedFromTarget" {|{"sessionId":"D"}|} with
   | Cdp.Target_detached { session = "D" } -> ()
   | _ -> fail "the detached session is the one in params");
  (match event "Runtime.bindingCalled" {|{"name":"x"}|} with
   | Cdp.Malformed_event { method_ = "Runtime.bindingCalled"; _ } -> ()
   | _ -> fail "a binding call without payload is malformed");
  match event "Page.loadEventFired" {|{}|} with
  | Cdp.Unobserved { method_ = "Page.loadEventFired" } -> ()
  | _ -> fail "an event without a reader is unobserved"
;;

let test_replies_reach_their_commands () =
  with_connection @@ fun ~sw ~clock:_ ~t ~sent ~events:_ ~closes:_ ->
  let first = Eio.Fiber.fork_promise ~sw (fun () -> Cdp.command t "Browser.getVersion" (`Assoc [])) in
  let second =
    Eio.Fiber.fork_promise ~sw (fun () -> Cdp.command t ~session:"W" "Runtime.enable" (`Assoc []))
  in
  (match List.rev !sent with
   | [ a; b ] ->
     check string "method" "Browser.getVersion" (Yojson.Safe.Util.to_string (member "method" a));
     check bool "no session on a browser command" true (member "sessionId" a = `Null);
     check string "session" "W" (Yojson.Safe.Util.to_string (member "sessionId" b));
     (* Replies arrive in the other order. *)
     Cdp.receive t (Printf.sprintf {|{"id":%d,"error":{"code":-32000,"message":"busy"}}|} (sent_id b));
     Cdp.receive t (Printf.sprintf {|{"id":%d,"result":{"product":"Chrome"}}|} (sent_id a))
   | frames -> failf "expected two frames, got %d" (List.length frames));
  check reply "first" (Ok (`Assoc [ "product", `String "Chrome" ])) (Eio.Promise.await_exn first);
  check reply "second" (Error (Cdp.Command_rejected { code = -32000; message = "busy" }))
    (Eio.Promise.await_exn second)
;;

let test_lost_ends_every_command () =
  with_connection @@ fun ~sw ~clock:_ ~t ~sent ~events ~closes ->
  let waiting = Eio.Fiber.fork_promise ~sw (fun () -> Cdp.command t "Extensions.loadUnpacked" (`Assoc [])) in
  Cdp.lost t "CDP websocket EOF";
  Cdp.lost t "a second reason is ignored";
  check reply "waiting command" (Error (Cdp.Connection_lost "CDP websocket EOF")) (Eio.Promise.await_exn waiting);
  let written = List.length !sent in
  check reply "later command" (Error (Cdp.Connection_lost "CDP websocket EOF"))
    (Cdp.command t "Target.getTargets" (`Assoc []));
  check int "a later command writes nothing" written (List.length !sent);
  check int "the transport is let go once" 1 !closes;
  Cdp.receive t {|{"method":"Target.targetDestroyed","params":{"targetId":"T"}}|};
  match !events with
  | [ Cdp.Connection_ended { reason = "CDP websocket EOF" } ] -> ()
  | _ -> fail "the end is announced once and nothing follows it"
;;

let test_deadline_ends_the_connection () =
  with_connection @@ fun ~sw ~clock ~t ~sent:_ ~events:_ ~closes:_ ->
  let waiting = Eio.Fiber.fork_promise ~sw (fun () -> Cdp.command t "Runtime.evaluate" (`Assoc [])) in
  Eio_mock.Clock.set_time clock deadline_s;
  check reply "no reply by the deadline" (Error (Cdp.Connection_lost "CDP command deadline exceeded"))
    (Eio.Promise.await_exn waiting);
  check (option string) "the connection is over" (Some "CDP command deadline exceeded") (Cdp.lost_reason t)
;;

(* The deadline's wake-up and the reply land in the same pass: the reply
   stands and the connection stays for the next command. *)
let test_a_reply_at_the_deadline_keeps_the_connection () =
  with_connection @@ fun ~sw ~clock ~t ~sent ~events:_ ~closes:_ ->
  let first = Eio.Fiber.fork_promise ~sw (fun () -> Cdp.command t "Browser.getVersion" (`Assoc [])) in
  Eio_mock.Clock.set_time clock 1.0;
  let second = Eio.Fiber.fork_promise ~sw (fun () -> Cdp.command t "Target.getTargets" (`Assoc [])) in
  let first_id = sent_id (List.nth (List.rev !sent) 0) in
  Eio_mock.Clock.set_time clock deadline_s;
  Cdp.receive t (Printf.sprintf {|{"id":%d,"result":{}}|} first_id);
  check reply "the reply stands" (Ok (`Assoc [])) (Eio.Promise.await_exn first);
  check (option string) "the connection stays" None (Cdp.lost_reason t);
  Eio_mock.Clock.set_time clock (1.0 +. deadline_s);
  check reply "the unanswered command still meets its own deadline"
    (Error (Cdp.Connection_lost "CDP command deadline exceeded")) (Eio.Promise.await_exn second)
;;

let test_a_cancelled_caller_ends_the_connection () =
  with_connection @@ fun ~sw:_ ~clock:_ ~t ~sent:_ ~events:_ ~closes ->
  (try
     Eio.Switch.run (fun caller ->
       Eio.Fiber.fork ~sw:caller (fun () -> ignore (Cdp.command t "Runtime.evaluate" (`Assoc [])));
       Eio.Switch.fail caller Exit)
   with
   | Exit -> ());
  check (option string) "its outcome is unknown" (Some "a command's caller was cancelled") (Cdp.lost_reason t);
  check int "the transport is let go" 1 !closes
;;

let test_protocol_violations_end_the_connection () =
  with_connection @@ fun ~sw:_ ~clock:_ ~t ~sent:_ ~events ~closes:_ ->
  Cdp.receive t {|{"method":"Target.targetDestroyed","params":{"targetId":"T"}}|};
  (match !events with
   | [ Cdp.Target_destroyed { target_id = "T" } ] -> ()
   | _ -> fail "an event reaches on_event");
  Cdp.receive t {|{"id":99,"result":{}}|};
  check (option string) "a reply nobody asked for" (Some "CDP reply for unknown command 99") (Cdp.lost_reason t)
;;

let () =
  run "browser_cdp" [
    "wire", [
      test_case "frames decode" `Quick test_decode;
      test_case "events decode" `Quick test_events;
    ];
    "connection", [
      test_case "replies reach their commands" `Quick test_replies_reach_their_commands;
      test_case "an ended connection ends every command" `Quick test_lost_ends_every_command;
      test_case "a missed deadline ends the connection" `Quick test_deadline_ends_the_connection;
      test_case "a reply at the deadline keeps it" `Quick test_a_reply_at_the_deadline_keeps_the_connection;
      test_case "a cancelled caller ends it" `Quick test_a_cancelled_caller_ends_the_connection;
      test_case "a reply nobody asked for ends it" `Quick test_protocol_violations_end_the_connection;
    ];
  ]
