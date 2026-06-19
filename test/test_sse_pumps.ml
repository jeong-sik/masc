open Alcotest

(* [run_sse_pumps] forks the drain and ping pumps under a per-connection switch
   and cancels BOTH when [stop_promise] resolves — including a drain blocked in
   [Eio.Stream.take], which the previous [info.stop] flag alone could not
   interrupt (#21548). Each pump resolves a "cleaned" promise from its
   cancellation finalizer, so the test waits deterministically: if the switch
   were never released, the awaits below would hang (test timeout) instead of
   passing on a guessed number of scheduler turns. *)
let test_run_sse_pumps_cancels_blocked_pumps () =
  Eio_main.run
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let stop_promise, resolve_stop = Eio.Promise.create () in
  let blocker : int Eio.Stream.t = Eio.Stream.create 0 in
  let drain_cleaned, set_drain_cleaned = Eio.Promise.create () in
  let ping_cleaned, set_ping_cleaned = Eio.Promise.create () in
  Server_mcp_transport_http_conn.run_sse_pumps
    ~sw
    ~stop_promise
    ~drain:(fun () ->
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve set_drain_cleaned ())
        (fun () -> ignore (Eio.Stream.take blocker : int)))
    ~ping:(fun () ->
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve set_ping_cleaned ())
        (fun () -> Eio.Fiber.await_cancel ()));
  (* Both pumps are now blocked. Resolving the stop promise must release the
     per-connection switch and cancel them. *)
  Eio.Promise.resolve resolve_stop ();
  Eio.Promise.await drain_cleaned;
  Eio.Promise.await ping_cleaned;
  check bool "drain pump cancelled and finalized" true
    (Eio.Promise.is_resolved drain_cleaned);
  check bool "ping pump cancelled and finalized" true
    (Eio.Promise.is_resolved ping_cleaned)
;;

let () =
  run
    "sse_pumps"
    [ ( "run_sse_pumps"
      , [ test_case
            "resolving stop_promise cancels blocked drain + ping"
            `Quick
            test_run_sse_pumps_cancels_blocked_pumps
        ] )
    ]
;;
