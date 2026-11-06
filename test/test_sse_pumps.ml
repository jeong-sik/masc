open Alcotest

module Conn = Server_mcp_transport_http_conn

let long_stall_s = 600.0
let short_stall_s = 0.05

(* An SSE connection over an in-memory httpun connection. A write reaches the
   "socket" only when the test answers it on the connection, so a frame sent
   on a connection nobody answers never does. *)
let open_info ?(client_id = 0) ~clock ~stalled_after_s session_id =
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
    connection, Conn.make_sse_conn ~session_id ~client_id ~response ()
;;

let make_info ~clock ~stalled_after_s session_id = snd (open_info ~clock ~stalled_after_s session_id)

let outcome_t =
  testable
    (fun ppf (outcome : Server_sse_response.outcome) ->
       Format.pp_print_string
         ppf
         (match outcome with
          | Written -> "Written"
          | Closed -> "Closed"
          | Stalled -> "Stalled"))
    ( = )
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
            ignore (Conn.send_raw info "data: {}\n\n" : Server_sse_response.outcome))
          ~ping:Eio.Fiber.await_cancel;
        Eio.Promise.await sending;
        Conn.close_sse_conn info);
      Ok ())
  with
  | Ok () ->
    check bool "the supervisor closed the response" true (Server_sse_response.is_closed info.response)
  | Error `Timeout -> failf "a waiting send outlived the stop by %.0f s" stop_bound_s
;;

exception Prime_failed

type pump =
  | Drain
  | Ping

let pump_name = function
  | Drain -> "drain"
  | Ping -> "ping"
;;

(* Runs [run_sse_pumps] with [returning] as one pump and a pump that waits
   for its cancellation as the other, then checks that the connection
   ended. *)
let check_one_returning_pump_ends_the_connection pump returning =
  Eio_main.run
  @@ fun env ->
  let which = pump_name pump in
  let clock = Eio.Stdenv.clock env in
  let session_id = fresh_session ("pump-ended-" ^ which) in
  let info = make_info ~clock ~stalled_after_s:long_stall_s session_id in
  Conn.register_sse_conn ~session_id ~info;
  let other_cancelled, set_other_cancelled = Eio.Promise.create () in
  let waiting () =
    Fun.protect
      ~finally:(fun () -> Eio.Promise.resolve set_other_cancelled ())
      Eio.Fiber.await_cancel
  in
  let drain, ping =
    match pump with
    | Drain -> returning, waiting
    | Ping -> waiting, returning
  in
  match
    Eio.Time.with_timeout clock stop_bound_s (fun () ->
      Eio.Switch.run (fun sw -> Conn.run_sse_pumps ~sw info ~drain ~ping);
      Ok ())
  with
  | Ok () ->
    check bool (which ^ ": the other pump was cancelled") true (Eio.Promise.is_resolved other_cancelled);
    check bool (which ^ ": the connection is stopped") true (Atomic.get info.closed);
    check bool (which ^ ": the response is closed") true (Server_sse_response.is_closed info.response);
    check bool (which ^ ": the connection left the registry") false
      (Conn.is_active_sse_session session_id)
  | Error `Timeout -> failf "the connection outlived its %s by %.0f s" which stop_bound_s
;;

(* Each route's drain sends the prime and the replay inside a handler that
   logs an exception and returns. A drain that returned that way carries no
   more events, and a ping that returned that way sends no more keepalives,
   so the connection ends. *)
let test_a_pump_that_returns_ends_the_connection () =
  let raising_prime () = raise Prime_failed in
  check_one_returning_pump_ends_the_connection Drain (fun () ->
    try raising_prime () with
    | Prime_failed -> ());
  check_one_returning_pump_ends_the_connection Ping (fun () -> ())
;;

(* A frame that never reaches a socket ends the send at the stall bound.
   Before RFC-0493 [send_raw] reported success here and the frame stayed in
   httpun's buffer. *)
let test_send_raw_waits_for_the_socket () =
  Eio_main.run
  @@ fun env ->
  let info = make_info ~clock:(Eio.Stdenv.clock env) ~stalled_after_s:short_stall_s (fresh_session "stall") in
  check outcome_t "an unread frame stalls" Stalled (Conn.send_raw info "data: {}\n\n");
  check bool "the connection is stopped" true (Atomic.get info.closed);
  check bool "the response is closed" true (Server_sse_response.is_closed info.response);
  check outcome_t "a later frame is not sent" Closed (Conn.send_raw info "data: {}\n\n")
;;

module Sse = Masc.Sse

(* RFC-0493 §6 5d: the drain of an MCP GET, AG-UI or presence connection
   writes the frames already waiting in one send. *)

(* 128 of these fill one batch: 128 x 512 B = 64 KiB. *)
let delivery_frame_bytes = 512
let frames_per_batch = 128

(* Fewer than the Sse queue holds, so the test sees batches, not the queue
   bound. *)
let queued_deliveries = 200
let replayed_deliveries = 300

(* The replayed deliveries that also arrived live after the session
   registered. *)
let replayed_and_live = 2

let prime = ": prime\n\n"
let drain_patience_s = 10.0

(* Each frame names its event id and is [delivery_frame_bytes] long. The
   drain makes it from the delivery, as the AG-UI drain makes its own. *)
let sized_frame_of_id id =
  let head = Printf.sprintf "id: %d\ndata: " id in
  head ^ String.make (delivery_frame_bytes - String.length head - 2) 'x' ^ "\n\n"
;;

let sized_frame (delivery : Sse.delivery) = sized_frame_of_id delivery.event_id

(* Puts one delivery in the session's Sse queue, as a broadcast does, and
   returns its event id. *)
let push_live session_id =
  Sse.send_to session_id (`Assoc [ "jsonrpc", `String "2.0"; "method", `String "notifications/message" ]);
  Sse.current_id ()
;;

let with_registered_session prefix f =
  let workspace = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace workspace)
    (fun () ->
       let auth = Masc_test_deps.make_sse_auth workspace "sse-drain-test-agent" in
       let session_id = fresh_session prefix in
       let (_ : Masc.Session.McpSessionStore.mcp_session) =
         Masc.Session.McpSessionStore.get_or_create ~id:session_id ()
       in
       match Sse.register ~auth session_id ~last_event_id:0 with
       | Error error -> fail (Sse.registration_error_to_string error)
       | Ok (client_id, event_stream, (_ : string option)) ->
         f ~session_id ~client_id ~event_stream)
;;

let offered_bytes iovecs =
  List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len) 0 iovecs
;;

type drained =
  { sends : string list  (** What each [send] of the drain carried, in order. *)
  ; still_registered : bool
  ; drain_ended : bool
  }

(* Runs the drain under [run_sse_pumps], as the MCP GET handler does. The
   first send's write stays unanswered while [while_first_waits] runs; then
   every write is answered until the drain wrote [total_bytes]. *)
let drain_with_first_write_held ~prefix ~replay ~total_bytes ~while_first_waits =
  Eio_main.run
  @@ fun env ->
  with_registered_session prefix (fun ~session_id ~client_id ~event_stream ->
    let clock = Eio.Stdenv.clock env in
    let connection, info =
      open_info ~client_id ~clock ~stalled_after_s:long_stall_s session_id
    in
    Conn.register_sse_conn ~session_id ~info;
    let sends = ref [] and written = ref 0 and drain_ended = ref false in
    let send data : Server_sse_response.outcome =
      sends := data :: !sends;
      let outcome = Conn.send_raw info data in
      (match outcome with
       | Written -> written := !written + String.length data
       | Closed | Stalled -> ());
      outcome
    in
    Eio.Switch.run (fun sw ->
      Conn.run_sse_pumps ~sw info
        ~drain:(fun () ->
          ignore
            (Conn.drain_sse info ~clock ~prime ~replay ~frame_of:sized_frame ~send event_stream
             : Server_sse_pump.ending);
          drain_ended := true)
        ~ping:Eio.Fiber.await_cancel;
      let rec first_write () =
        match !sends, Httpun.Server_connection.next_write_operation connection with
        | [ _ ], `Write iovecs -> offered_bytes iovecs
        | _, (`Write _ | `Yield) ->
          Eio.Fiber.yield ();
          first_write ()
        | _, `Close _ -> fail "the connection closed before the first send"
      in
      let rec answer_until_written () =
        if !written < total_bytes
        then (
          (match Httpun.Server_connection.next_write_operation connection with
           | `Write iovecs ->
             Httpun.Server_connection.report_write_result connection (`Ok (offered_bytes iovecs))
           | `Yield -> Eio.Fiber.yield ()
           | `Close _ -> fail "the connection closed before every frame was written");
          answer_until_written ())
      in
      match
        Eio.Time.with_timeout clock drain_patience_s (fun () ->
          let first = first_write () in
          while_first_waits ~session_id;
          Httpun.Server_connection.report_write_result connection (`Ok first);
          answer_until_written ();
          Ok ())
      with
      | Ok () ->
        let drained =
          { sends = List.rev !sends
          ; still_registered = Sse.exists session_id && Conn.is_active_sse_session session_id
          ; drain_ended = !drain_ended
          }
        in
        Conn.close_sse_conn info;
        drained
      | Error `Timeout ->
        failf "the drain wrote %d of %d bytes in %.0f s" !written total_bytes drain_patience_s))
;;

(* Live deliveries pile up while the prime waits for the socket. Once it is
   answered, they go out in two sends instead of one per frame, and the
   session keeps its registration: its Sse queue never filled. *)
let test_the_drain_writes_waiting_deliveries_in_one_send () =
  check int "a batch holds this many frames" frames_per_batch
    (Server_sse_pump.max_batch_bytes / delivery_frame_bytes);
  check bool "the deliveries fit the Sse queue" true (queued_deliveries < Sse.stream_capacity);
  let ids = ref [] in
  let drained =
    drain_with_first_write_held ~prefix:"batch" ~replay:[]
      ~total_bytes:(String.length prime + (queued_deliveries * delivery_frame_bytes))
      ~while_first_waits:(fun ~session_id ->
        for _ = 1 to queued_deliveries do
          ids := push_live session_id :: !ids
        done)
  in
  check (list int) "the prime, then two batches"
    [ String.length prime
    ; frames_per_batch * delivery_frame_bytes
    ; (queued_deliveries - frames_per_batch) * delivery_frame_bytes
    ]
    (List.map String.length drained.sends);
  check string "every frame in order"
    (prime ^ String.concat "" (List.rev_map sized_frame_of_id !ids))
    (String.concat "" drained.sends);
  check bool "the session is still registered" true drained.still_registered;
  check bool "the drain still runs" false drained.drain_ended
;;

(* The replay comes from the replay buffer, not the Sse queue, and goes out in
   batches too, the prime in the first. The last replayed deliveries also
   arrived live; they are not written twice. *)
let test_the_drain_writes_the_replay_in_batches () =
  let last_id = Sse.current_id () + replayed_and_live in
  let replay =
    List.init replayed_deliveries (fun index ->
      let event_id = last_id - replayed_deliveries + 1 + index in
      { Sse.event_id
      ; frame = ""
      ; payload = `Null
      ; emitted_at = 0.0
      ; audience = Sse.Session_audience "replay"
      })
  in
  let drained =
    drain_with_first_write_held ~prefix:"replay" ~replay
      ~total_bytes:(String.length prime + (replayed_deliveries * delivery_frame_bytes))
      ~while_first_waits:(fun ~session_id ->
        for _ = 1 to replayed_and_live do
          ignore (push_live session_id : int)
        done;
        check int "the live deliveries carry the last replayed ids" last_id (Sse.current_id ()))
  in
  check (list int) "three batches, the prime in the first"
    [ String.length prime + (frames_per_batch * delivery_frame_bytes)
    ; frames_per_batch * delivery_frame_bytes
    ; (replayed_deliveries - (2 * frames_per_batch)) * delivery_frame_bytes
    ]
    (List.map String.length drained.sends);
  check string "the prime and each replayed frame once, in order"
    (prime ^ String.concat "" (List.map sized_frame replay))
    (String.concat "" drained.sends);
  check bool "the session is still registered" true drained.still_registered;
  check bool "the drain still runs" false drained.drain_ended
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
        ; test_case "a pump that returns ends the connection" `Quick
            test_a_pump_that_returns_ends_the_connection
        ] )
    ; ( "send_raw"
      , [ test_case "an unread frame ends at the stall bound" `Quick
            test_send_raw_waits_for_the_socket
        ] )
    ; ( "drain_sse"
      , [ test_case "waiting deliveries go out in one send" `Quick
            test_the_drain_writes_waiting_deliveries_in_one_send
        ; test_case "the replay goes out in batches" `Quick
            test_the_drain_writes_the_replay_in_batches
        ] )
    ]
;;
