open Alcotest
module Sse = Server_sse_response

let patience_s = 10.0
let poll_s = 0.002

(* Long enough that a loaded machine does not make a slow frame look stalled. *)
let kept_stalled_after_s = 600.0

(* Short enough for a test to wait through. *)
let short_stalled_after_s = 0.3

(* How long a send has to stay unanswered before the test calls it pending. *)
let pending_for_s = 0.2

(* A bound on the mock clock, which moves only when the test moves it. *)
let mock_stalled_after_s = 100.0

(* Frames that have to reach a reading client after the late one. *)
let frames_after_the_late_one = 8

let frame_bytes = 64 * 1024
let frame = "data: " ^ String.make (frame_bytes - 8) 'x' ^ "\n\n"

(* 64 MiB: more than the client's receive buffer and the server's send buffer
   hold together on Linux and macOS loopback. A send that is still [Written]
   after this many frames is not waiting for the socket. *)
let frames_beyond_socket_buffers = 1024

let outcome_name = function
  | Sse.Written -> "Written"
  | Closed -> "Closed"
  | Stalled -> "Stalled"
;;

let outcome_t = testable (fun ppf outcome -> Format.pp_print_string ppf (outcome_name outcome)) ( = )

exception Server_stopped

type server =
  { port : int
  ; stop : unit -> unit  (** Returns once the listening socket is closed. *)
  }

(* The real accept loop and httpun connection, on a loopback port. Each request
   gets one SSE response, handed to [on_response] in a fiber of its own. The
   response's stall bound runs on [response_clock], the system clock unless a
   test moves time by hand. *)
let start_server ?response_clock ~sw env ~stalled_after_s ~on_response =
  let clock = Eio.Stdenv.clock env in
  let response_clock =
    match response_clock with
    | Some (mock : Eio_mock.Clock.t) -> (mock :> float Eio.Time.clock_ty Eio.Resource.t)
    | None -> (clock :> float Eio.Time.clock_ty Eio.Resource.t)
  in
  let listening, resolve_listening = Eio.Promise.create () in
  let finished, resolve_finished = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    (match
       Eio.Switch.run (fun server_sw ->
         let socket =
           Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw:server_sw (Eio.Stdenv.net env)
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
         in
         let port =
           match Eio.Net.listening_addr socket with
           | `Tcp (_, port) -> port
           | `Unix _ -> fail "the test listens on TCP"
         in
         Eio.Promise.resolve resolve_listening
           { port
           ; stop =
               (fun () ->
                  Eio.Switch.fail server_sw Server_stopped;
                  Eio.Promise.await finished)
           };
         Server_bootstrap_http.serve ~sw:server_sw ~clock ~socket ~addr_label:"sse response test"
           ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
             let headers =
               Httpun.Headers.of_list
                 [ "content-type", "text/event-stream"; "connection", "close" ]
             in
             let response =
               Sse.respond ~clock:response_clock ~stalled_after_s (Masc.Http_reqd.of_gluten gluten_reqd)
                 (Httpun.Response.create ~headers `OK)
             in
             Eio.Fiber.fork ~sw:server_sw (fun () -> on_response response)))
     with
     | () -> ()
     | exception Server_stopped -> ());
    Eio.Promise.resolve resolve_finished ());
  Eio.Promise.await listening
;;

let connect ~sw env ~port =
  let flow = Eio.Net.connect ~sw (Eio.Stdenv.net env) (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  Eio.Flow.copy_string "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" flow;
  flow
;;

let contains ~needle text =
  let n = String.length needle and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = needle || at (i + 1)) in
  at 0
;;

(* Reads until [needle] has arrived, then reads no more. *)
let read_until flow needle =
  let buf = Cstruct.create 4096 and seen = Buffer.create 4096 in
  while not (contains ~needle (Buffer.contents seen)) do
    let n = Eio.Flow.single_read flow buf in
    Buffer.add_string seen (Cstruct.to_string ~len:n buf)
  done
;;

let within env what f =
  match Eio.Time.with_timeout (Eio.Stdenv.clock env) patience_s (fun () -> Ok (f ())) with
  | Ok value -> value
  | Error `Timeout -> failf "gave up waiting for %s" what
;;

type refusal =
  | Kept_written
  | Refused of Sse.outcome

(* Sends whole frames until one is not [Written]. *)
let send_until_refused response =
  let rec go written =
    if written >= frames_beyond_socket_buffers
    then Kept_written
    else
      match Sse.send response frame with
      | Sse.Written -> go (written + 1)
      | (Closed | Stalled) as refused -> Refused refused
  in
  go 0
;;

let refusal_name = function
  | Kept_written -> Printf.sprintf "still Written after %d frames" frames_beyond_socket_buffers
  | Refused outcome -> outcome_name outcome
;;

let refusal_t = testable (fun ppf refusal -> Format.pp_print_string ppf (refusal_name refusal)) ( = )

let with_env f = Eio_main.run (fun env -> Eio.Switch.run (fun sw -> f env sw))

let test_a_frame_the_socket_takes_is_written () =
  with_env (fun env sw ->
    let sent, resolve = Eio.Promise.create () in
    let server =
      start_server ~sw env ~stalled_after_s:kept_stalled_after_s ~on_response:(fun response ->
        Eio.Promise.resolve resolve (Sse.send response "data: one\n\n"))
    in
    let flow = connect ~sw env ~port:server.port in
    within env "the frame" (fun () -> read_until flow "data: one");
    check outcome_t "the frame reached the socket" Sse.Written
      (within env "the send" (fun () -> Eio.Promise.await sent));
    server.stop ())
;;

let test_a_client_that_stops_reading_ends_the_response_as_stalled () =
  with_env (fun env sw ->
    let ended, resolve = Eio.Promise.create () in
    let server =
      start_server ~sw env ~stalled_after_s:short_stalled_after_s ~on_response:(fun response ->
        let refusal = send_until_refused response in
        Eio.Promise.resolve resolve (refusal, Sse.send response frame, Sse.is_closed response))
    in
    let flow = connect ~sw env ~port:server.port in
    within env "the response head" (fun () -> read_until flow "200 OK");
    let refusal, next, closed = within env "the sender to stop" (fun () -> Eio.Promise.await ended) in
    check refusal_t "the frame the socket did not take stalled" (Refused Sse.Stalled) refusal;
    check outcome_t "a send after the stall writes nothing" Sse.Closed next;
    check bool "the stall closed the response" true closed;
    server.stop ())
;;

type sender =
  { started : int Atomic.t
  ; returned : int Atomic.t
  ; last : Sse.outcome Eio.Promise.t
  }

(* Sends whole frames until one is not [Written], in a fiber of its own. *)
let start_sender ~sw response =
  let started = Atomic.make 0 and returned = Atomic.make 0 in
  let last, resolve = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let rec go () =
      Atomic.incr started;
      let outcome = Sse.send response frame in
      Atomic.incr returned;
      match outcome with
      | Sse.Written -> go ()
      | (Closed | Stalled) as last -> Eio.Promise.resolve resolve last
    in
    go ());
  { started; returned; last }
;;

(* Returns once every sender has had one send unanswered for [pending_for_s]. *)
let await_all_pending env senders =
  let clock = Eio.Stdenv.clock env in
  within env "every send to stay pending" (fun () ->
    let rec settled () =
      let before = List.map (fun sender -> Atomic.get sender.returned) senders in
      Eio.Time.sleep clock pending_for_s;
      let pending sender returned =
        Atomic.get sender.started = returned + 1 && Atomic.get sender.returned = returned
      in
      if not (List.for_all2 pending senders before) then settled ()
    in
    settled ())
;;

(* The write a client's reset fails ends as a closed connection
   ({!Server_connection_socket}), so httpun answers the flush that waits and
   the frame is [Closed] without waiting for the stall bound, which is too far
   off here to end it. The client stops reading first, so a frame is waiting
   when it leaves. *)
let test_a_frame_waiting_when_the_client_goes_away_is_closed () =
  with_env (fun env sw ->
    let opened, resolve = Eio.Promise.create () in
    let server =
      start_server ~sw env ~stalled_after_s:kept_stalled_after_s
        ~on_response:(fun response -> Eio.Promise.resolve resolve response)
    in
    let sender =
      Eio.Switch.run (fun client_sw ->
        let flow = connect ~sw:client_sw env ~port:server.port in
        let response = within env "the response" (fun () -> Eio.Promise.await opened) in
        let sender = start_sender ~sw response in
        within env "the response head" (fun () -> read_until flow "200 OK");
        await_all_pending env [ sender ];
        sender)
    in
    check outcome_t "the waiting frame is closed" Sse.Closed
      (within env "the waiting send" (fun () -> Eio.Promise.await sender.last));
    server.stop ())
;;

(* The flush answer and the end of the time arrive in one scheduler pass. The
   frame reached the socket, so it is [Written]. An in-memory httpun
   connection lets the test answer the write by hand right after the bound
   came due, before any fiber runs. *)
let test_a_frame_answered_as_the_time_runs_out_is_written () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let outcome, resolve = Eio.Promise.create () in
    Eio.Switch.run (fun sw ->
      let connection =
        Httpun.Server_connection.create (fun reqd ->
          let headers = Httpun.Headers.of_list [ "content-type", "text/event-stream" ] in
          let response =
            Sse.respond ~clock ~stalled_after_s:mock_stalled_after_s (Masc.Http_reqd.of_httpun reqd)
              (Httpun.Response.create ~headers `OK)
          in
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve resolve (Sse.send response "data: one\n\n")))
      in
      let raw = "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" in
      let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
      ignore (Httpun.Server_connection.read connection input ~off:0 ~len:(String.length raw) : int);
      match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
        let length =
          List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len) 0 iovecs
        in
        Eio_mock.Clock.set_time clock mock_stalled_after_s;
        Httpun.Server_connection.report_write_result connection (`Ok length);
        check outcome_t "the frame that reached the socket is Written" Sse.Written
          (Eio.Promise.await outcome)
      | `Yield | `Close _ -> fail "the frame was not offered to the socket"))
;;

let test_close_ends_every_waiting_send () =
  with_env (fun env sw ->
    let opened, resolve = Eio.Promise.create () in
    let server =
      start_server ~sw env ~stalled_after_s:kept_stalled_after_s ~on_response:(fun response ->
        Eio.Promise.resolve resolve response)
    in
    let flow = connect ~sw env ~port:server.port in
    let response = within env "the response" (fun () -> Eio.Promise.await opened) in
    let senders = [ start_sender ~sw response; start_sender ~sw response ] in
    within env "the response head" (fun () -> read_until flow "200 OK");
    (* The client reads no more. *)
    await_all_pending env senders;
    Sse.close response;
    List.iter
      (fun sender ->
         check outcome_t "the waiting send ends as Closed" Sse.Closed
           (within env "the waiting send" (fun () -> Eio.Promise.await sender.last)))
      senders;
    check outcome_t "a send after close writes nothing" Sse.Closed
      (Sse.send response "data: late\n\n");
    server.stop ())
;;

(* The bound belongs to one frame. A frame the client takes late, but in time,
   is [Written], and the next frame is timed from its own [send]. *)
let test_the_stall_bound_counts_from_each_send () =
  with_env (fun env sw ->
    let mock = Eio_mock.Clock.make () in
    let opened, resolve = Eio.Promise.create () in
    let server =
      start_server ~response_clock:mock ~sw env ~stalled_after_s:mock_stalled_after_s
        ~on_response:(fun response -> Eio.Promise.resolve resolve response)
    in
    let flow = connect ~sw env ~port:server.port in
    let response = within env "the response" (fun () -> Eio.Promise.await opened) in
    let sender = start_sender ~sw response in
    within env "the response head" (fun () -> read_until flow "200 OK");
    await_all_pending env [ sender ];
    Eio_mock.Clock.set_time mock (mock_stalled_after_s -. 1.0);
    Eio.Fiber.yield ();
    check bool "a second before the bound the frame still waits" false
      (Eio.Promise.is_resolved sender.last);
    let waiting = Atomic.get sender.returned in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let buf = Cstruct.create 65536 in
      let rec read_on () = ignore (Eio.Flow.single_read flow buf : int); read_on () in
      (try read_on () with End_of_file | Eio.Io _ -> ());
      `Stop_daemon);
    let frames_after s = Atomic.get sender.returned >= waiting + s in
    let clock = Eio.Stdenv.clock env in
    within env "the client to take the waiting frame" (fun () ->
      while not (frames_after 1) do Eio.Time.sleep clock poll_s done);
    (* Past the bound the first waiting frame had. *)
    Eio_mock.Clock.set_time mock (mock_stalled_after_s +. 1.0);
    within env "more frames to reach the client" (fun () ->
      while not (frames_after frames_after_the_late_one) do Eio.Time.sleep clock poll_s done);
    check bool "no frame stalled" false (Eio.Promise.is_resolved sender.last);
    Sse.close response;
    check outcome_t "the sender ends when the response closes" Sse.Closed
      (within env "the sender" (fun () -> Eio.Promise.await sender.last));
    server.stop ())
;;

let test_a_waiting_send_can_be_cancelled () =
  with_env (fun env sw ->
    let opened, resolve = Eio.Promise.create () in
    let server =
      start_server ~sw env ~stalled_after_s:kept_stalled_after_s ~on_response:(fun response ->
        Eio.Promise.resolve resolve response)
    in
    let flow = connect ~sw env ~port:server.port in
    let response = within env "the response" (fun () -> Eio.Promise.await opened) in
    let sender_ended, sender_end = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      (match
         Eio.Switch.run (fun sender_sw ->
           let sender = start_sender ~sw:sender_sw response in
           within env "the response head" (fun () -> read_until flow "200 OK");
           await_all_pending env [ sender ];
           Eio.Switch.fail sender_sw Exit)
       with
       | () -> ()
       | exception Exit -> ());
      Eio.Promise.resolve sender_end ());
    within env "the waiting send to be cancelled" (fun () -> Eio.Promise.await sender_ended);
    check bool "cancelling a send does not close the response" false (Sse.is_closed response);
    server.stop ())
;;

(* Reads until the server ends the response, and gives what arrived. *)
let read_to_end flow =
  let buf = Cstruct.create 4096 and seen = Buffer.create 4096 in
  (try
     while true do
       let n = Eio.Flow.single_read flow buf in
       Buffer.add_string seen (Cstruct.to_string ~len:n buf)
     done
   with
   | End_of_file -> ());
  Buffer.contents seen
;;

let served_frame = "data: served\n\n"

let send_served response =
  match Sse.send response served_frame with
  | Sse.Written -> ()
  | Closed | Stalled -> fail "the served frame was not written"
;;

(* RFC-0518 D7 on HTTP/1.1. Each request's producer is served in [sw], the
   switch of the whole test, as a route serves it in the server's. A
   response that ends closes its connection, and [after_frame] runs once the
   frame went out. The client of one request reads to that end, twice over:
   the second request shows the server still serves. *)
let serve_twice ~after_frame =
  with_env (fun env sw ->
    let releases = ref 0 in
    let server =
      start_server ~sw env ~stalled_after_s:kept_stalled_after_s ~on_response:(fun response ->
        Sse.serve ~sw response
          ~release:(fun () -> incr releases)
          (fun () ->
            send_served response;
            after_frame ()))
    in
    let served () =
      let flow = connect ~sw env ~port:server.port in
      contains ~needle:served_frame (within env "the response to end" (fun () -> read_to_end flow))
    in
    check bool "the frame arrived and the response ended" true (served ());
    check bool "the next request is served the same" true (served ());
    check int "each producer's cleanup ran once" 2 !releases;
    server.stop ())
;;

let test_a_producer_that_returns_ends_the_response () = serve_twice ~after_frame:ignore

(* The failure reaches neither the server's switch nor the next request. An
   HTTP/1.1 body that ends with its connection looks the same to the client
   either way. *)
let test_a_producer_that_raises_ends_the_response_only () =
  serve_twice ~after_frame:(fun () -> failwith "fixture producer failure")
;;

let () =
  run "Server SSE response"
    [ ( "loopback"
      , [ test_case "a frame the socket takes is Written" `Quick
            test_a_frame_the_socket_takes_is_written
        ; test_case "a client that stops reading ends the response as Stalled" `Quick
            test_a_client_that_stops_reading_ends_the_response_as_stalled
        ; test_case "a frame waiting when the client goes away is Closed" `Quick
            test_a_frame_waiting_when_the_client_goes_away_is_closed
        ; test_case "a frame answered as the time runs out is Written" `Quick
            test_a_frame_answered_as_the_time_runs_out_is_written
        ; test_case "close ends every waiting send" `Quick test_close_ends_every_waiting_send
        ; test_case "the stall bound counts from each send" `Quick
            test_the_stall_bound_counts_from_each_send
        ; test_case "a waiting send can be cancelled" `Quick test_a_waiting_send_can_be_cancelled
        ] )
    ; ( "producer scope"
      , [ test_case "a producer that returns ends the response" `Quick
            test_a_producer_that_returns_ends_the_response
        ; test_case "a producer that raises ends the response only" `Quick
            test_a_producer_that_raises_ends_the_response_only
        ] )
    ]
;;
