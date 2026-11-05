open Alcotest

module Conn = Server_mcp_transport_http_conn

let long_stall_s = 600.0
let short_stall_s = 0.05

(* An SSE connection over an in-memory httpun connection. Nothing reads its
   writes, so a frame sent on it never reaches a socket. *)
let make_info ~clock ~stalled_after_s session_id =
  let reqd_ref = ref None in
  let connection = Httpun.Server_connection.create (fun reqd -> reqd_ref := Some reqd) in
  let request = "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n" in
  let len = String.length request in
  ignore
    (Httpun.Server_connection.read connection (Bigstringaf.of_string request ~off:0 ~len) ~off:0 ~len
     : int);
  match !reqd_ref with
  | None -> fail "the in-memory connection parsed no request"
  | Some reqd ->
    let response =
      Server_sse_response.respond ~clock ~stalled_after_s reqd (Httpun.Response.create `OK)
    in
    Conn.make_sse_conn ~session_id ~client_id:0 ~response ()
;;

let fresh_session prefix = prefix ^ "-" ^ string_of_int (Random.bits ())

(* [run_sse_pumps] forks the drain and ping pumps under a per-connection switch
   and cancels BOTH when the stop promise resolves — including a drain blocked
   in [Eio.Stream.take], which the [info.stop] flag alone could not interrupt
   (#21548). Each pump resolves a "cleaned" promise from its cancellation
   finalizer, so the test waits deterministically. The switch around
   [run_sse_pumps] returns only after the supervisor's release hook ran. *)
let test_stop_cancels_pumps_and_closes_the_response () =
  Eio_main.run
  @@ fun env ->
  let info = make_info ~clock:(Eio.Stdenv.clock env) ~stalled_after_s:long_stall_s (fresh_session "stop") in
  let blocker : int Eio.Stream.t = Eio.Stream.create 0 in
  let drain_cleaned, set_drain_cleaned = Eio.Promise.create () in
  let ping_cleaned, set_ping_cleaned = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Conn.run_sse_pumps
      ~sw
      info
      ~drain:(fun () ->
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve set_drain_cleaned ())
          (fun () -> ignore (Eio.Stream.take blocker : int)))
      ~ping:(fun () ->
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve set_ping_cleaned ())
          (fun () -> Eio.Fiber.await_cancel ()));
    Conn.close_sse_conn info;
    Eio.Promise.await drain_cleaned;
    Eio.Promise.await ping_cleaned);
  check bool "the supervisor closed the response" true (Server_sse_response.is_closed info.response)
;;

(* A close from any domain only signals: the response belongs to the
   connection's domain and is left to the supervisor (RFC-0493 §3.2). *)
let test_close_leaves_the_response_to_the_supervisor () =
  Eio_main.run
  @@ fun env ->
  let info = make_info ~clock:(Eio.Stdenv.clock env) ~stalled_after_s:long_stall_s (fresh_session "signal") in
  Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () -> Conn.close_sse_conn info);
  check bool "the stop promise resolved" true (Eio.Promise.is_resolved info.stop_promise);
  check bool "the response is still open" false (Server_sse_response.is_closed info.response)
;;

exception Server_stopped

(* The server switch can end before anyone closed the connection. The release
   hook still closes the response and removes the connection. *)
let test_cancelled_supervisor_closes_the_response () =
  Eio_main.run
  @@ fun env ->
  let session_id = fresh_session "cancel" in
  let info = make_info ~clock:(Eio.Stdenv.clock env) ~stalled_after_s:long_stall_s session_id in
  Conn.register_sse_conn ~session_id ~info;
  (match
     Eio.Switch.run (fun sw ->
       Conn.run_sse_pumps ~sw info ~drain:Eio.Fiber.await_cancel ~ping:Eio.Fiber.await_cancel;
       Eio.Fiber.yield ();
       Eio.Switch.fail sw Server_stopped)
   with
   | () -> fail "the failed switch returned normally"
   | exception Server_stopped -> ());
  check bool "the response is closed" true (Server_sse_response.is_closed info.response);
  check bool "the connection is stopped" true (Atomic.get info.closed);
  check bool "the connection left the registry" false (Conn.is_active_sse_session session_id)
;;

(* [Eio.Fiber.fork] runs nothing on a switch that is already off, so no
   supervisor starts there. [run_sse_pumps] still closes the response and
   removes the connection. *)
let test_switch_off_closes_the_response () =
  Eio_main.run
  @@ fun env ->
  let session_id = fresh_session "off" in
  let info = make_info ~clock:(Eio.Stdenv.clock env) ~stalled_after_s:long_stall_s session_id in
  Conn.register_sse_conn ~session_id ~info;
  (match
     Eio.Switch.run (fun sw ->
       Eio.Switch.fail sw Server_stopped;
       Conn.run_sse_pumps ~sw info ~drain:Eio.Fiber.await_cancel ~ping:Eio.Fiber.await_cancel)
   with
   | () -> fail "the failed switch returned normally"
   | exception Server_stopped -> ());
  check bool "the response is closed" true (Server_sse_response.is_closed info.response);
  check bool "the connection is stopped" true (Atomic.get info.closed);
  check bool "the connection left the registry" false (Conn.is_active_sse_session session_id)
;;

let stop_bound_s = 5.0

(* A drain that waits for the socket is cancelled by the stop, like one
   blocked on its queue. *)
let test_stop_cancels_a_waiting_send () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let info = make_info ~clock ~stalled_after_s:long_stall_s (fresh_session "waiting") in
  let sending, set_sending = Eio.Promise.create () in
  match
    Eio.Time.with_timeout clock stop_bound_s (fun () ->
      Eio.Switch.run (fun sw ->
        Conn.run_sse_pumps
          ~sw
          info
          ~drain:(fun () ->
            Eio.Promise.resolve set_sending ();
            ignore (Conn.send_raw info "data: {}\n\n" : bool))
          ~ping:Eio.Fiber.await_cancel;
        Eio.Promise.await sending;
        Conn.close_sse_conn info);
      Ok ())
  with
  | Ok () ->
    check bool "the supervisor closed the response" true (Server_sse_response.is_closed info.response)
  | Error `Timeout -> failf "a waiting send outlived the stop by %.0f s" stop_bound_s
;;

(* A frame that never reaches a socket ends the send at the stall bound.
   Before RFC-0493 [send_raw] returned [true] here and the frame stayed in
   httpun's buffer. *)
let test_send_raw_waits_for_the_socket () =
  Eio_main.run
  @@ fun env ->
  let info = make_info ~clock:(Eio.Stdenv.clock env) ~stalled_after_s:short_stall_s (fresh_session "stall") in
  check bool "an unread frame is not sent" false (Conn.send_raw info "data: {}\n\n");
  check bool "the connection is stopped" true (Atomic.get info.closed);
  check bool "the response is closed" true (Server_sse_response.is_closed info.response);
  check bool "a later frame is not sent" false (Conn.send_raw info "data: {}\n\n")
;;

let () =
  run
    "sse_pumps"
    [ ( "run_sse_pumps"
      , [ test_case "the stop promise cancels both pumps and closes the response" `Quick
            test_stop_cancels_pumps_and_closes_the_response
        ; test_case "a close from another domain leaves the response open" `Quick
            test_close_leaves_the_response_to_the_supervisor
        ; test_case "a cancelled supervisor closes the response" `Quick
            test_cancelled_supervisor_closes_the_response
        ; test_case "a switch that is off closes the response at once" `Quick
            test_switch_off_closes_the_response
        ; test_case "the stop cancels a send that waits for the socket" `Quick
            test_stop_cancels_a_waiting_send
        ] )
    ; ( "send_raw"
      , [ test_case "an unread frame ends at the stall bound" `Quick
            test_send_raw_waits_for_the_socket
        ] )
    ]
;;
