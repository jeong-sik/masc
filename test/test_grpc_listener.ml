(** Actual listener ownership, bind acknowledgment, cancellation, and h2c handoff.
    Synchronization uses promises and real sockets; no readiness timers/probes. *)
module TM = Masc.Transport_metrics
module Listener = Server_grpc_listener

let check_state expected =
  Alcotest.(check bool) "lifecycle" true (TM.grpc_listener_snapshot () = expected)

let listen net ~sw =
  Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))

let test_bind_ack_barrier () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let entered, publish_entered = Eio.Promise.create () in
  let release, publish_release = Eio.Promise.create () in
  let served, publish_served = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result = Listener.with_listener
      ~listen:(fun ~sw ->
        Eio.Promise.resolve publish_entered ();
        Eio.Promise.await release;
        listen (Eio.Stdenv.net env) ~sw)
      ~serve:(fun ~sw:_ socket ->
        check_state Listening;
        Alcotest.(check bool) "actual socket has an address" true
          (match Eio.Net.listening_addr socket with `Tcp (_, port) -> port > 0 | `Unix _ -> false))
    in
    Alcotest.(check bool) "normal completion" true (result = Ok ());
    Eio.Promise.resolve publish_served ());
  Eio.Promise.await entered;
  check_state Binding;
  Alcotest.(check bool) "pending bind is not ready" false (TM.grpc_listening ());
  Eio.Promise.resolve publish_release ();
  Eio.Promise.await served;
  check_state Stopped

let test_occupied_port_keeps_sibling_alive () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let sibling = listen net ~sw in
  let sibling_addr = Eio.Net.listening_addr sibling in
  let occupied = listen net ~sw in
  let occupied_addr = Eio.Net.listening_addr occupied in
  let called = ref false in
  (match Listener.with_listener
    ~listen:(fun ~sw -> Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128 occupied_addr)
    ~serve:(fun ~sw:_ _ -> called := true) with
   | Error failure ->
       Alcotest.(check bool) "actual address-in-use class" true
         (failure.kind = TM.Address_in_use)
   | Ok () -> Alcotest.fail "occupied port was accepted");
  check_state (Failed Address_in_use);
  Alcotest.(check bool) "failed bind never serves" false !called;
  Eio.Fiber.both
    (fun () ->
      let flow, _peer = Eio.Net.accept ~sw sibling in
      let reader = Eio.Buf_read.of_flow flow ~max_size:1024 in
      Alcotest.(check string) "sibling HTTP request still arrives" "GET /health HTTP/1.1"
        (Eio.Buf_read.line reader);
      Eio.Flow.copy_string "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" flow)
    (fun () ->
      let flow = Eio.Net.connect net ~sw sibling_addr in
      Eio.Flow.copy_string "GET /health HTTP/1.1\r\n\r\n" flow;
      let reader = Eio.Buf_read.of_flow flow ~max_size:1024 in
      Alcotest.(check string) "sibling HTTP response survives gRPC bind failure" "HTTP/1.1 200 OK"
        (Eio.Buf_read.line reader));
  check_state (Failed Address_in_use)

let test_cancellation_during_bind () =
  Eio_main.run @@ fun _env ->
  let entered, publish_entered = Eio.Promise.create () in
  let propagated = ref false in
  Eio.Fiber.first
    (fun () ->
      try
        ignore (Listener.with_listener
          ~listen:(fun ~sw:_ ->
            Eio.Promise.resolve publish_entered ();
            Eio.Fiber.await_cancel ())
          ~serve:(fun ~sw:_ () -> Alcotest.fail "cancelled bind served"))
      with Eio.Cancel.Cancelled _ as exn -> propagated := true; raise exn)
    (fun () -> Eio.Promise.await entered; check_state Binding);
  Alcotest.(check bool) "cancellation propagates" true !propagated;
  check_state Stopped

let test_cancellation_closes_bound_socket () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let bound, publish_bound = Eio.Promise.create () in
  let address = ref None in
  Eio.Fiber.first
    (fun () -> ignore (Listener.with_listener
      ~listen:(listen net)
      ~serve:(fun ~sw:_ socket ->
        let addr = Eio.Net.listening_addr socket in
        address := Some addr;
        Eio.Promise.resolve publish_bound ();
        Eio.Fiber.await_cancel ())))
    (fun () -> Eio.Promise.await bound; check_state Listening);
  check_state Stopped;
  Eio.Switch.run @@ fun sw ->
  match !address with
  | None -> Alcotest.fail "listener did not bind"
  | Some addr -> ignore (Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128 addr)

let test_serve_failure_is_retained () =
  Eio_main.run @@ fun env ->
  let cause = Failure "private listener diagnostic" in
  (match Listener.with_listener
    ~listen:(listen (Eio.Stdenv.net env))
    ~serve:(fun ~sw:_ _ -> raise cause) with
   | Error failure ->
       Alcotest.(check bool) "actual failure retained privately" true (failure.cause == cause);
       Alcotest.(check bool) "serve failure class" true (failure.kind = TM.Serve_failed)
   | Ok () -> Alcotest.fail "serve failure disappeared");
  check_state (Failed Serve_failed);
  let fields = TM.grpc_listener_fields (TM.grpc_listener_snapshot ()) in
  Alcotest.(check bool) "public fields contain only stable labels" true
    (fields = ["listening", `Bool false; "listen_status", `String "failed";
               "listen_failure", `String "serve_failed"])

let test_bind_failure_classification () =
  Eio_main.run @@ fun _env ->
  List.iter (fun (cause, kind) ->
    let served = ref false in
    (match Listener.with_listener
      ~listen:(fun ~sw:_ -> raise cause)
      ~serve:(fun ~sw:_ () -> served := true) with
     | Error failure ->
         Alcotest.(check bool) "typed bind cause" true (failure.kind = kind);
         Alcotest.(check bool) "private cause preserved" true (failure.cause == cause)
     | Ok () -> Alcotest.fail "failed bind became success");
    Alcotest.(check bool) "failed bind never serves" false !served;
    check_state (Failed kind))
    [Unix.Unix_error (Unix.EACCES, "bind", "private socket"), TM.Bind_failed;
     Eio.Exn.create (Eio.Exn.X (Eio_unix.Unix_error (Unix.EADDRINUSE, "bind", "private socket"))),
     TM.Address_in_use]

let run_h2_health_handoff ~before_health () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let bound, publish_bound = Eio.Promise.create () in
  let health = Grpc_eio.Health.create ~default_status:Grpc_eio.Health.Serving () in
  let server = Grpc_eio.Server.create ()
    |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health) in
  Eio.Fiber.first
    (fun () -> ignore (Listener.with_listener
      ~listen:(listen net)
      ~serve:(fun ~sw socket ->
        Eio.Promise.resolve publish_bound (Eio.Net.listening_addr socket);
        Listener.serve_socket ~sw ~clock ~socket server)))
    (fun () ->
      let addr = Eio.Promise.await bound in
      check_state Listening;
      before_health net addr;
      check_state Listening;
      let target = match addr with
        | `Tcp (_, port) -> Printf.sprintf "http://127.0.0.1:%d" port
        | `Unix _ -> Alcotest.fail "expected TCP listener" in
      (* grpc-direct's [Client.close] is currently a no-op. Own and cancel
         its connection scope after the response instead of waiting for an
         open H2 connection to finish on normal switch return. *)
      let checked, publish_checked = Eio.Promise.create () in
      Eio.Fiber.first
        (fun () -> Eio.Switch.run @@ fun sw ->
          let client = Grpc_eio.Client.connect ~sw ~env target in
          (match Grpc_eio.Client.call_unary ~sw ~env client
            ~service:"grpc.health.v1.Health" ~method_:"Check" ~request:"" with
           | Ok response ->
               Alcotest.(check string) "actual health SERVING protobuf" "\x08\x01" response
           | Error status -> Alcotest.failf "health failed: %s" (Grpc_core.Status.to_string status));
          Eio.Promise.resolve publish_checked ();
          Eio.Fiber.await_cancel ())
        (fun () -> Eio.Promise.await checked));
  check_state Stopped

let test_h2_health_handoff () =
  run_h2_health_handoff ~before_health:(fun _net _addr -> ()) ()

let test_malformed_connection_keeps_listener_alive () =
  run_h2_health_handoff
    ~before_health:(fun net addr ->
      Eio.Switch.run @@ fun sw ->
      let flow = Eio.Net.connect net ~sw addr in
      (* An invalid 24-byte HTTP/2 connection preface reaches the actual H2
         parser. Half-close only our send side, then await the server's EOF
         before attempting a healthy RPC on this same bound listener. *)
      Eio.Flow.copy_string (String.make 24 'x') flow;
      Eio.Flow.shutdown flow `Send;
      let bytes = Cstruct.create 64 in
      let rec await_peer_close () =
        match Eio.Flow.single_read flow bytes with
        | _ -> await_peer_close ()
        | exception End_of_file -> ()
      in
      await_peer_close ())
    ()

let () =
  Alcotest.run "gRPC listener ownership"
    ["lifecycle", [
      Alcotest.test_case "bind acknowledgment barrier" `Quick test_bind_ack_barrier;
      Alcotest.test_case "occupied port and healthy sibling" `Quick test_occupied_port_keeps_sibling_alive;
      Alcotest.test_case "cancel pending bind" `Quick test_cancellation_during_bind;
      Alcotest.test_case "cancel closes actual socket" `Quick test_cancellation_closes_bound_socket;
      Alcotest.test_case "serve failure remains typed" `Quick test_serve_failure_is_retained;
      Alcotest.test_case "other and wrapped bind failures" `Quick test_bind_failure_classification;
      Alcotest.test_case "actual h2 gRPC health handoff" `Quick test_h2_health_handoff;
      Alcotest.test_case "malformed connection then same-listener health" `Quick
        test_malformed_connection_keeps_listener_alive;
    ]]
