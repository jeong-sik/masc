(* RFC-0518 D4, D6: the bounds of an accepted connection's socket.

   The socket under test is one end of a socket pair, the peer the other. The
   bounds are counted on a mock clock, so a test says when time passes, and
   the kernel does the rest: a peer that reads nothing is one that reads
   nothing. *)

open Alcotest
module Socket = Server_connection_socket

let kib = 1024
let bound = Socket.write_bound_s

(* What a test may take in real time, on a loaded machine. *)
let patience_s = 30.0

(* The pair's sending buffer is made smaller than a piece, whatever the
   platform's default is: a piece then waits for the peer to read. *)
let small_send_buffer flow =
  Eio_unix.Fd.use_exn "setsockopt" (Eio_unix.Net.fd flow) (fun fd ->
    Unix.setsockopt_int fd Unix.SO_SNDBUF (16 * kib))
;;

(* [run ~clock connection socket peer]: [socket] is the bounded socket of
   [connection], [peer] the other end. The connection's switch ends when
   [run] returns, as the accept loop's does when the handler returns. *)
let with_connection run =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) patience_s @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio_mock.Clock.make () in
  let accepted, peer = Eio_unix.Net.socketpair_stream ~sw () in
  small_send_buffer accepted;
  Eio.Switch.run @@ fun connection_sw ->
  let connection =
    Socket.wrap ~sw:connection_sw ~clock ~listener_tag:"test" (`Unix "peer") accepted
  in
  run ~clock connection (Socket.socket connection) peer
;;

(* A TCP loopback connection, whose close can reset the peer.
   [serve handler] is what the accept loop does with an accepted flow: it
   runs [handler] on the bounded socket in a switch of its own and closes the
   flow when [handler] has returned. *)
let with_tcp_connection run =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) patience_s @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio_mock.Clock.make () in
  let net = Eio.Stdenv.net env in
  let listening =
    Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:1 (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let peer = Eio.Net.connect ~sw net (Eio.Net.listening_addr listening) in
  let accepted, client_addr = Eio.Net.accept ~sw listening in
  small_send_buffer accepted;
  let serve handler =
    Eio.Switch.run (fun connection_sw ->
      let connection =
        Socket.wrap ~sw:connection_sw ~clock ~listener_tag:"test" client_addr accepted
      in
      handler (Socket.socket connection));
    Eio.Flow.close accepted
  in
  run ~clock ~serve peer
;;

(* [length] bytes that differ from place to place, so bytes that arrive out
   of order or twice do not compare equal. *)
let patterned length = String.init length (fun i -> Char.chr ((i * 7 + (i / 251)) land 0xff))

(* Reads [peer] until [length] more bytes are in [into]. *)
let read_more peer into length =
  let chunk = Cstruct.create (64 * kib) in
  let rec read left =
    if left > 0
    then (
      let got = Eio.Flow.single_read peer (Cstruct.sub chunk 0 (min left (Cstruct.length chunk))) in
      Buffer.add_string into (Cstruct.to_string ~len:got chunk);
      read (left - got))
  in
  read length
;;

type ending =
  | Whole
  | Ended  (** [End_of_file] *)
  | Failed of exn

(* [work ()] in a fiber of [sw]; the promise is how it ended. *)
let ending_of ~sw work =
  Eio.Fiber.fork_promise ~sw (fun () ->
    match work () with
    | () -> Whole
    | exception End_of_file -> Ended
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Failed exn)
;;

let ending =
  testable
    (fun f -> function
       | Whole -> Fmt.string f "whole"
       | Ended -> Fmt.string f "End_of_file"
       | Failed exn -> Fmt.pf f "exception %s" (Printexc.to_string exn))
    (fun a b ->
       match a, b with
       | Whole, Whole | Ended, Ended -> true
       | Failed a, Failed b -> a == b
       | (Whole | Ended | Failed _), _ -> false)
;;

(* Still waiting after the scheduler went round several times: each round
   runs what was made ready and asks the kernel once, so a fiber that a
   wrong cut woke would have ended by now. *)
let pending promise =
  for _ = 1 to 10 do
    Eio.Fiber.yield ()
  done;
  not (Eio.Promise.is_resolved promise)
;;

(* A write longer than a piece, given as buffers a piece's end falls inside
   of, and a copy after it that is longer than a piece too and ends inside
   one: the peer gets every byte once and in order. *)
let test_bytes_arrive_whole_and_in_order () =
  with_connection @@ fun ~clock:_ _connection socket peer ->
  let written = patterned (600 * kib) in
  let copied = patterned (600 * kib + 3) in
  let third = String.length written / 3 in
  let buffers =
    List.init 3 (fun i -> Cstruct.of_string (String.sub written (i * third) third))
  in
  Eio.Switch.run @@ fun sw ->
  let sent =
    ending_of ~sw (fun () ->
      Eio.Flow.write socket buffers;
      Eio.Flow.copy_string copied socket)
  in
  let received = Buffer.create (String.length written + String.length copied) in
  read_more peer received (String.length written + String.length copied);
  check ending "the writes ended whole" Whole (Eio.Promise.await_exn sent);
  check bool "the peer got every byte in order" true
    (String.equal (Buffer.contents received) (written ^ copied))
;;

(* A peer that reads nothing. The piece in flight has the bound: one second
   short of it the write still waits, at it the write ends, and so does every
   later write and the connection's read. *)
let test_piece_not_taken_is_cut_at_the_bound () =
  with_connection @@ fun ~clock _connection socket _peer ->
  Eio.Switch.run @@ fun sw ->
  let sent =
    ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.create (1024 * kib) ])
  in
  Eio_mock.Clock.set_time clock (bound -. 1.0);
  check bool "one second short of the bound the write waits" true (pending sent);
  Eio_mock.Clock.set_time clock bound;
  check ending "at the bound the write ended" Ended (Eio.Promise.await_exn sent);
  check ending "a later write ends at once" Ended
    (Eio.Promise.await_exn (ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.create 1 ])));
  check ending "a read sees the end of the stream" Ended
    (Eio.Promise.await_exn
       (ending_of ~sw (fun () -> ignore (Eio.Flow.single_read socket (Cstruct.create 1) : int))))
;;

(* A peer that sent its FIN and reads nothing: half of the connection is
   already closed when the bound runs out. The write ends all the same. *)
let test_piece_not_taken_by_a_half_closed_peer_is_cut () =
  with_connection @@ fun ~clock _connection socket peer ->
  Eio.Flow.shutdown peer `Send;
  Eio.Switch.run @@ fun sw ->
  let sent =
    ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.create (1024 * kib) ])
  in
  Eio_mock.Clock.set_time clock (bound -. 1.0);
  check bool "one second short of the bound the write waits" true (pending sent);
  Eio_mock.Clock.set_time clock bound;
  check ending "at the bound the write ended" Ended (Eio.Promise.await_exn sent)
;;

type peer_end =
  | Peer_reset
  | Peer_closed  (** The stream ended whole: what the server queued was delivered. *)

let peer_end =
  testable
    (fun f -> function
       | Peer_reset -> Fmt.string f "reset"
       | Peer_closed -> Fmt.string f "end of stream")
    ( = )
;;

(* Reads [peer] to its end. *)
let rec end_of peer chunk =
  match Eio.Flow.single_read peer chunk with
  | (_ : int) -> end_of peer chunk
  | exception End_of_file -> Peer_closed
  | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> Peer_reset
;;

(* Over TCP. The server queued more than the peer took before the cut. When
   the accepted socket is closed the peer is reset and the rest is dropped;
   a close that kept the queue would deliver it and end the stream whole,
   however long the peer took. *)
let test_cut_connection_is_reset_when_closed () =
  with_tcp_connection @@ fun ~clock ~serve peer ->
  serve (fun socket ->
    Eio.Switch.run @@ fun sw ->
    let sent =
      ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.create (16 * 1024 * kib) ])
    in
    Eio_mock.Clock.set_time clock bound;
    check ending "at the bound the write ended" Ended (Eio.Promise.await_exn sent));
  check peer_end "the peer is reset" Peer_reset (end_of peer (Cstruct.create (64 * kib)))
;;

(* A write of three pieces to a peer that takes one piece a minute. The
   whole write lasts twice the bound and is not cut: each piece is taken
   within its own bound. *)
let test_slow_reader_of_every_piece_is_not_cut () =
  with_connection @@ fun ~clock _connection socket peer ->
  let pieces = 3 in
  let written = patterned (pieces * Socket.write_piece_bytes) in
  Eio.Switch.run @@ fun sw ->
  let sent = ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.of_string written ]) in
  let received = Buffer.create (String.length written) in
  for piece = 1 to pieces do
    Eio_mock.Clock.set_time clock (float_of_int piece *. 60.0);
    read_more peer received Socket.write_piece_bytes
  done;
  check ending "the write ended whole" Whole (Eio.Promise.await_exn sent);
  check bool "the write outlasted the bound" true (Eio.Time.now clock > bound);
  check bool "the peer got every byte in order" true
    (String.equal (Buffer.contents received) written)
;;

(* A peer that closed. The write fails in the kernel with EPIPE, and ends
   with [End_of_file], which is what gluten takes for a closed connection. *)
let test_write_to_a_closed_peer_ends () =
  with_connection @@ fun ~clock:_ _connection socket peer ->
  Eio.Flow.close peer;
  Eio.Switch.run @@ fun sw ->
  check ending "the write ended" Ended
    (Eio.Promise.await_exn
       (ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.create (64 * kib) ])))
;;

(* Two writers at once, each with a copy that waits for the peer more than
   once. The second waits for its turn: its bytes come after all of the
   first's. *)
let test_two_copies_do_not_interleave () =
  with_connection @@ fun ~clock:_ _connection socket peer ->
  let length = 200 * kib in
  let first = String.make length 'a' and second = String.make length 'b' in
  Eio.Switch.run @@ fun sw ->
  let first_sent = ending_of ~sw (fun () -> Eio.Flow.copy_string first socket) in
  let second_sent = ending_of ~sw (fun () -> Eio.Flow.copy_string second socket) in
  let received = Buffer.create (2 * length) in
  read_more peer received (2 * length);
  check ending "the first copy ended whole" Whole (Eio.Promise.await_exn first_sent);
  check ending "the second copy ended whole" Whole (Eio.Promise.await_exn second_sent);
  check bool "the second copy's bytes follow all of the first's" true
    (String.equal (Buffer.contents received) (first ^ second))
;;

(* Two writers at once, each with a write of more than two pieces. The
   second waits until the first's last piece is out: a turn given up between
   pieces would put the second's bytes inside the first's. tls-eio hands a
   run of records to one write, from two fibers. *)
let test_two_writes_do_not_interleave () =
  with_connection @@ fun ~clock:_ _connection socket peer ->
  let length = (2 * Socket.write_piece_bytes) + (88 * kib) in
  let first = String.make length 'a' and second = String.make length 'b' in
  Eio.Switch.run @@ fun sw ->
  let first_sent = ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.of_string first ]) in
  let second_sent = ending_of ~sw (fun () -> Eio.Flow.write socket [ Cstruct.of_string second ]) in
  let received = Buffer.create (2 * length) in
  read_more peer received (2 * length);
  check ending "the first write ended whole" Whole (Eio.Promise.await_exn first_sent);
  check ending "the second write ended whole" Whole (Eio.Promise.await_exn second_sent);
  check bool "the second write's bytes follow all of the first's" true
    (String.equal (Buffer.contents received) (first ^ second))
;;

(* The server's sending side is over and the peer keeps its own open. The
   read that waits for the peer's end waits one bound. *)
let test_peer_that_keeps_its_side_open_is_cut () =
  with_connection @@ fun ~clock _connection socket _peer ->
  Eio.Flow.shutdown socket `Send;
  Eio.Switch.run @@ fun sw ->
  let read =
    ending_of ~sw (fun () -> ignore (Eio.Flow.single_read socket (Cstruct.create 1) : int))
  in
  Eio_mock.Clock.set_time clock (bound -. 1.0);
  check bool "one second short of the bound the read waits" true (pending read);
  Eio_mock.Clock.set_time clock bound;
  check ending "at the bound the read sees the end of the stream" Ended
    (Eio.Promise.await_exn read)
;;

(* The first bytes come within the preparation bound: the step returns,
   nothing was consumed, and the bound is over with the step. *)
let test_prepared_in_time () =
  with_connection @@ fun ~clock connection socket peer ->
  Eio.Flow.copy_string "x" peer;
  check (option unit) "the first bytes came" (Some ())
    (Socket.prepare connection (fun () -> Socket.await_first_bytes connection));
  Eio_mock.Clock.set_time clock (2.0 *. Socket.preparation_bound_s);
  Eio.Flow.copy_string "y" peer;
  let got = Buffer.create 2 in
  read_more socket got 2;
  check string "the connection reads what the peer sent" "xy" (Buffer.contents got)
;;

(* A peer that sends nothing. One second short of the preparation bound the
   step still waits; at the bound it is given up and the peer sees the
   connection end. *)
let test_not_prepared_is_cut_at_the_bound () =
  with_connection @@ fun ~clock connection _socket peer ->
  Eio.Switch.run @@ fun sw ->
  let prepared =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Socket.prepare connection (fun () -> Socket.await_first_bytes connection))
  in
  Eio_mock.Clock.set_time clock (Socket.preparation_bound_s -. 1.0);
  check bool "one second short of the bound the step waits" true (pending prepared);
  Eio_mock.Clock.set_time clock Socket.preparation_bound_s;
  check (option unit) "at the bound the step is given up" None (Eio.Promise.await_exn prepared);
  check ending "the peer sees the connection end" Ended
    (match Eio.Flow.single_read peer (Cstruct.create 1) with
     | (_ : int) -> Whole
     | exception End_of_file -> Ended)
;;

(* The peer closed, and the step waits for something else. Giving the step
   up cuts a connection that is already over, which is not an error: macOS
   refuses the socket option of a socket the peer has shut down. *)
let test_not_prepared_after_the_peer_left_is_given_up () =
  with_connection @@ fun ~clock connection _socket peer ->
  Eio.Flow.close peer;
  Eio.Switch.run @@ fun sw ->
  let prepared =
    Eio.Fiber.fork_promise ~sw (fun () -> Socket.prepare connection Eio.Fiber.await_cancel)
  in
  Eio_mock.Clock.set_time clock Socket.preparation_bound_s;
  check (option unit) "the step is given up" None (Eio.Promise.await_exn prepared)
;;

(* {1 The accept loops} *)

type listener =
  | H1
  | H2c
  | Auto

let no_request _addr _reqd = fail "a request reached the handler"
let no_h2_request ~stream_end:_ _addr _reqd = fail "a request reached the h2 handler"
let no_h2_error _addr ?request:_ _error _respond = fail "an h2 error reached the handler"

(* Moves the mock clock to its next sleeper, once there is one. *)
let rec to_next_timer clock =
  if not (Eio_mock.Clock.try_advance clock)
  then (
    Eio.Fiber.yield ();
    to_next_timer clock)
;;

(* A client that connects to a cleartext listener and does not go on to a
   request: it sends [opening] and nothing more. The first timer the
   listener starts is the preparation bound, and when it runs out the client
   sees the connection end. *)
let test_listener_closes_a_connection_that_does_not_start listener ~opening () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) patience_s @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio_mock.Clock.make () in
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:8 (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> fail "a TCP socket has a port"
  in
  let addr_label = Printf.sprintf "127.0.0.1:%d" port in
  let serve ~sw =
    match listener with
    | H1 ->
      Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label ~request_handler:no_request
    | H2c ->
      Server_bootstrap_http.serve_h2 ~sw ~clock ~socket ~addr_label
        ~h2_request_handler:no_h2_request ~h2_error_handler:no_h2_error
    | Auto ->
      Server_bootstrap_http.serve_auto ~sw ~clock ~socket ~addr_label
        ~request_handler:no_request ~h2_request_handler:no_h2_request
        ~h2_error_handler:no_h2_error
  in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run (fun server_sw ->
        serve ~sw:server_sw;
        fail "the accept loop returned"))
    (fun () ->
      let client = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
      Eio.Flow.copy_string opening client;
      to_next_timer clock;
      check (float 0.0) "the first timer is the preparation bound" Socket.preparation_bound_s
        (Eio.Time.now clock);
      match Eio.Flow.single_read client (Cstruct.create 16) with
      | (_ : int) -> fail "the listener answered a connection that sent no request"
      | exception End_of_file -> ()
      | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> ())
;;

(* The whole of what a client reads until the listener ends the connection. *)
let read_to_end client =
  match Eio.Buf_read.(parse_exn take_all) client ~max_size:(64 * kib) with
  | answer -> answer
  | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> ""
;;

let get target =
  Printf.sprintf "GET %s HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n" target
;;

(* A request to [/fail] makes a fiber of its connection's switch raise
   [failure]: not the fiber that serves the connection, one beside it, as a
   stream's fiber or a watching daemon is. The listener's switch is the
   server's lifetime, so the next connection is still accepted and answered
   (#51173). *)
let test_listener_outlives_a_failed_connection_fiber failure () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) patience_s @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio_mock.Clock.make () in
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:8 (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> fail "a TCP socket has a port"
  in
  let request_handler _addr (reqd : Httpun.Reqd.t Gluten.Reqd.t) =
    match (Httpun.Reqd.request reqd.reqd).target with
    | "/fail" ->
      (match Masc.Http_reqd.relay_scope (Masc.Http_reqd.of_gluten reqd) with
       | None -> fail "an HTTP/1.1 request has its connection's switch"
       | Some connection_sw -> Eio.Fiber.fork ~sw:connection_sw (fun () -> raise failure))
    | _ ->
      Httpun.Reqd.respond_with_string
        reqd.reqd
        (Httpun.Response.create
           ~headers:(Httpun.Headers.of_list [ "content-length", "2"; "connection", "close" ])
           `OK)
        "ok"
  in
  let request target =
    Eio.Switch.run (fun client_sw ->
      let client = Eio.Net.connect ~sw:client_sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
      Eio.Flow.copy_string (get target) client;
      read_to_end client)
  in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run (fun server_sw ->
        Server_bootstrap_http.serve
          ~sw:server_sw
          ~clock
          ~socket
          ~addr_label:(Printf.sprintf "127.0.0.1:%d" port)
          ~request_handler;
        fail "the accept loop returned"))
    (fun () ->
      check string "the failed connection is not answered" "" (request "/fail");
      let answer = request "/next" in
      check bool
        (Printf.sprintf "the next connection is answered: %S" answer)
        true
        (String.starts_with ~prefix:"HTTP/1.1 200" answer))
;;

let () =
  run
    "connection socket"
    [ ( "writes"
      , [ test_case "bytes arrive whole and in order" `Quick test_bytes_arrive_whole_and_in_order
        ; test_case "a piece the peer does not take is cut at the bound" `Quick
            test_piece_not_taken_is_cut_at_the_bound
        ; test_case "a piece a half-closed peer does not take is cut at the bound" `Quick
            test_piece_not_taken_by_a_half_closed_peer_is_cut
        ; test_case "a cut connection is reset when it is closed" `Quick
            test_cut_connection_is_reset_when_closed
        ; test_case "a slow reader of every piece is not cut" `Quick
            test_slow_reader_of_every_piece_is_not_cut
        ; test_case "a write to a closed peer ends" `Quick test_write_to_a_closed_peer_ends
        ; test_case "two copies do not interleave" `Quick test_two_copies_do_not_interleave
        ; test_case "two writes do not interleave" `Quick test_two_writes_do_not_interleave
        ] )
    ; ( "sending side closed"
      , [ test_case "a peer that keeps its side open is cut at the bound" `Quick
            test_peer_that_keeps_its_side_open_is_cut
        ] )
    ; ( "preparation"
      , [ test_case "first bytes in time" `Quick test_prepared_in_time
        ; test_case "no first bytes: cut at the bound" `Quick test_not_prepared_is_cut_at_the_bound
        ; test_case "a step given up after the peer left" `Quick
            test_not_prepared_after_the_peer_left_is_given_up
        ] )
    ; ( "accept loops"
      , [ test_case "HTTP/1.1: a connection that sends nothing" `Quick
            (test_listener_closes_a_connection_that_does_not_start H1 ~opening:"")
        ; test_case "h2c: a connection that sends nothing" `Quick
            (test_listener_closes_a_connection_that_does_not_start H2c ~opening:"")
        ; test_case "auto: a connection that sends nothing" `Quick
            (test_listener_closes_a_connection_that_does_not_start Auto ~opening:"")
        ; test_case "auto: a connection that stops inside the HTTP/2 preface" `Quick
            (test_listener_closes_a_connection_that_does_not_start Auto ~opening:"PRI * HT")
        ; test_case "a connection fiber that raises does not end the listener" `Quick
            (test_listener_outlives_a_failed_connection_fiber (Failure "a connection fiber"))
        ; test_case "a connection fiber's Cancelled does not end the listener" `Quick
            (test_listener_outlives_a_failed_connection_fiber
               (Eio.Cancel.Cancelled (Failure "another scope")))
        ] )
    ]
;;
