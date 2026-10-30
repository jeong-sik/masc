(* RFC-0287 P0 — the gateway reader's lifetime must be the connection's, not
   the gateway's.

   [Discord_wss_connection.spawn] forks a fiber on the connection's session
   switch, so [close] cancels it (its blocking [read] raises [Cancelled]).
   Before the fix the gateway forked the reader on the gateway-wide switch,
   where a per-connection close left it blocked in [Stream.take] forever — one
   leaked fiber per reconnect cycle (unbounded on a flaky-network gateway).

   [make_test_conn] gives a connection with the real session switch + spawn +
   close but no socket, so this pins the lifetime contract without a live WS
   handshake. The 2s timeout turns a regression (reader not cancelled) into a
   fast failure instead of a hang. *)

open Alcotest
module D = Discord_wss_connection

let test_close_cancels_spawned_reader () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let conn = D.For_testing.make_test_conn ~sw in
  let outcome, set = Eio.Promise.create () in
  D.spawn conn (fun () ->
    (* Mirrors reader_loop: block on read; cancellation is the terminal arm. *)
    match D.read conn with
    | _ -> Eio.Promise.resolve set `Returned
    | exception Eio.Cancel.Cancelled _ -> Eio.Promise.resolve set `Cancelled
    | exception e -> Eio.Promise.resolve set (`Raised e));
  (* Let the reader reach its blocking [read] before closing, so the test
     exercises the cancel-a-blocked-reader path the leak was about. *)
  Eio.Fiber.yield ();
  D.close conn;
  match Eio.Time.with_timeout clock 2.0 (fun () -> Ok (Eio.Promise.await outcome)) with
  | Ok `Cancelled -> ()
  | Ok `Returned -> fail "reader returned without being cancelled (events stream got an item?)"
  | Ok (`Raised e) ->
    fail (Printf.sprintf "reader raised %s; expected Cancelled" (Printexc.to_string e))
  | Error `Timeout ->
    fail
      "spawned reader was not cancelled within 2s of close — it is on the \
       gateway switch, not the connection's (RFC-0287 P0 fiber leak)"
;;

let test_double_close_is_idempotent () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let conn = D.For_testing.make_test_conn ~sw in
  D.close conn;
  D.close conn;
  check pass "double close does not raise" () ()
;;

let () =
  run "discord_wss_lifecycle"
    [ ( "reader lifetime"
      , [ test_case "close cancels the spawned reader" `Quick test_close_cancels_spawned_reader
        ; test_case "double close is idempotent" `Quick test_double_close_is_idempotent
        ] )
    ]
;;
