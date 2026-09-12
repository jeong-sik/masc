(* Regression: requests to a dead server must not leak file descriptors.

   Pre-fix, each Pool.request against a refused port called
   [Piaf.Client.create ~sw:pool_sw] whose connect-failure path never
   released the socket bound to the pool's long-lived switch: one fd
   per request. The TUI's 2-second refresh tick issues ~9 surface GETs,
   so a dead server exhausted the stock macOS nofile=256 within a
   minute and the TUI died with Unix.EMFILE (2026-09-10, vincent mac).

   The fix (probe-first connect + per-host backoff) must hold the
   process fd count flat across 50 refused requests. *)

let closed_port () =
  (* Bind port 0, learn the assigned port, close. The address is now
     refused for the practical life of the test (nothing races to claim
     it on CI). *)
  let listen = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close listen)
    (fun () ->
       Unix.bind listen (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
       match Unix.getsockname listen with
       | Unix.ADDR_INET (_, port) -> port
       | Unix.ADDR_UNIX _ -> failwith "expected inet sockaddr")

let error_message = function
  | Ok _ -> Alcotest.fail "expected Error from a dead server"
  | Error msg -> msg

let test_dead_server_fd_flat () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config =
    { Masc_http_client.Pool.default_config with
      connect_failure_cooldown_seconds = 0.0 }
  in
  let pool = Masc_http_client.Pool.create ~sw ~env ~config () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
  let fd_before = (Fd_accountant.fd_snapshot ()).fd_open in
  for _ = 1 to 50 do
    let msg = error_message
      (Masc_http_client.Pool.request pool ~method_:`GET ~url ()) in
    Alcotest.(check bool) "every request attempts TCP, with no backoff"
      true (Astring.String.is_prefix ~affix:"TCP connect failed:" msg)
  done;
  Alcotest.(check int) "disabled backoff stores no failures" 0
    (Masc_http_client.Pool.For_testing.connect_failure_count pool);
  Alcotest.(check int) "failed probes never create a Piaf client" 0
    (Masc_http_client.Pool.stats pool).create_count_total;
  (* Let the scheduler run pending closes before counting. *)
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.2;
  let fd_after = (Fd_accountant.fd_snapshot ()).fd_open in
  match fd_before, fd_after with
  | Some before_, Some after_ ->
    Alcotest.(check int) "fd growth after 50 refused requests" 0
      (Int.max 0 (after_ - before_))
  | _ ->
    (* No observable fd dir on this platform: nothing to assert. *)
    ()

let test_backoff_fast_fails_without_socket () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* Cooldown long enough that the second request must hit it. *)
  let config =
    { Masc_http_client.Pool.default_config with
      connect_failure_cooldown_seconds = 30.0 }
  in
  let pool = Masc_http_client.Pool.create ~sw ~env ~config () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
  let first = Masc_http_client.Pool.request pool ~method_:`GET ~url () in
  let first_msg = error_message first in
  Alcotest.(check bool) "first failure is a connect failure"
    true
    (Astring.String.is_prefix ~affix:"TCP connect failed:" first_msg);
  let fd_mid = (Fd_accountant.fd_snapshot ()).fd_open in
  let second = Masc_http_client.Pool.request pool ~method_:`GET ~url () in
  Alcotest.(check bool) "second request fast-fails from backoff"
    true
    (Astring.String.is_prefix ~affix:"connect backoff:"
       (error_message second));
  let fd_after = (Fd_accountant.fd_snapshot ()).fd_open in
  (match fd_mid, fd_after with
   | Some mid, Some after_ ->
     Alcotest.(check int) "backoff opened no socket" 0
       (Int.max 0 (after_ - mid))
   | _ -> ())

let test_backoff_expires_and_retries () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config =
    { Masc_http_client.Pool.default_config with
      connect_failure_cooldown_seconds = 0.1 }
  in
  let pool = Masc_http_client.Pool.create ~sw ~env ~config () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
  ignore (Masc_http_client.Pool.request pool ~method_:`GET ~url ());
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.3;
  let retry = Masc_http_client.Pool.request pool ~method_:`GET ~url () in
  Alcotest.(check bool) "after cooldown the probe runs again"
    false
    (Astring.String.is_prefix ~affix:"connect backoff:"
       (error_message retry))

let test_probe_success_still_creates_client () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* A listening socket nobody accepts from. The kernel completes the
     handshake out of the backlog, so the probe connects and
     [Piaf.Client.create] runs (counted); the request then times out with
     no response, never as "connect refused" or "connect backoff".
     Accepting in a forked fiber would block the whole domain on
     [Unix.accept], which is not Eio-aware. *)
  let listen = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Eio.Switch.on_release sw (fun () -> Unix.close listen);
  Unix.setsockopt listen Unix.SO_REUSEADDR true;
  Unix.bind listen (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listen 4;
  let port =
    match Unix.getsockname listen with
    | Unix.ADDR_INET (_, p) -> p
    | Unix.ADDR_UNIX _ -> assert false
  in
  let pool = Masc_http_client.Pool.create ~sw ~env () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  let result =
    Masc_http_client.Pool.request pool ~clock:(Eio.Stdenv.clock env)
      ~timeout_seconds:1.0 ~method_:`GET ~url ()
  in
  ignore (result : (Masc_http_client.Pool.response, string) result);
  let stats = Masc_http_client.Pool.stats pool in
  Alcotest.(check int) "piaf client created after successful probe" 1
    stats.create_count_total;
  Masc_http_client.Pool.shutdown pool

let test_failure_state_cleanup () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let module Pool = Masc_http_client.Pool in
  let module T = Pool.For_testing in
  let config = { Pool.default_config with
    connect_failure_cooldown_seconds = 30.0 } in
  let pool = Pool.create ~sw ~env ~config () in
  let fail () =
    let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
    ignore (error_message (Pool.request pool ~method_:`GET ~url ()))
  in
  fail ();
  let now = Eio.Time.now (Eio.Stdenv.clock env) in
  T.evict_expired_entries pool now;
  Alcotest.(check int) "unexpired failure retained" 1
    (T.connect_failure_count pool);
  T.evict_expired_entries pool (now +. config.connect_failure_cooldown_seconds);
  Alcotest.(check int) "expired failure removed without revisiting host" 0
    (T.connect_failure_count pool);
  fail ();
  Pool.shutdown pool;
  Alcotest.(check int) "shutdown clears failure state" 0
    (T.connect_failure_count pool)

let test_establishment_errors () =
  Eio_main.run @@ fun env ->
  let establish ~resolve ~connect ~create =
    Masc_http_client.Pool.For_testing.establish_connection
      ~clock:(Eio.Stdenv.clock env) ~timeout_seconds:1.0
      ~resolve ~connect ~create in
  let no_connect _ = Alcotest.fail "DNS failure reached TCP" in
  let no_create () = Alcotest.fail "failed probe reached Piaf creation" in
  Alcotest.(check string) "empty DNS result"
    "DNS resolution failed: no stream addresses"
    (error_message (establish ~resolve:(fun () -> [])
      ~connect:no_connect ~create:no_create));
  let dns_error = Unix.Unix_error (Unix.EHOSTUNREACH, "getaddrinfo", "host") in
  Alcotest.(check string) "DNS error preserves cause"
    ("DNS resolution failed: " ^ Printexc.to_string dns_error)
    (error_message (establish ~resolve:(fun () -> raise dns_error)
      ~connect:no_connect ~create:no_create));
  let resource_error = Unix.Unix_error (Unix.EMFILE, "socket", "") in
  Alcotest.(check string) "resource exhaustion is not reported as refusal"
    ("TCP connect failed: " ^ Printexc.to_string resource_error)
    (error_message (establish ~resolve:(fun () -> [()])
      ~connect:(fun () -> raise resource_error) ~create:no_create));
  Alcotest.(check string) "Piaf failure preserves cause" "TLS failure"
    (error_message (establish ~resolve:(fun () -> [()])
      ~connect:(fun () -> ()) ~create:(fun () -> Error "TLS failure")));
  Alcotest.(check (result string string)) "later address can connect"
    (Ok "created")
    (establish ~resolve:(fun () -> [false; true])
      ~connect:(fun succeeds -> if not succeeds then raise resource_error)
      ~create:(fun () -> Ok "created"))

let test_establishment_deadline () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let establish ~resolve ~connect ~create =
    Masc_http_client.Pool.For_testing.establish_connection
      ~clock ~timeout_seconds:0.05 ~resolve ~connect ~create in
  let check_timeout label result =
    Alcotest.(check string) label "connect timeout" (error_message result)
  in
  check_timeout "DNS uses establishment deadline"
    (establish ~resolve:Eio.Fiber.await_cancel
      ~connect:(fun _ -> Alcotest.fail "DNS did not complete")
      ~create:(fun () -> Alcotest.fail "DNS did not complete"));
  let attempts = ref 0 in
  check_timeout "addresses share one deadline"
    (establish ~resolve:(fun () -> List.init 50 Fun.id)
      ~connect:(fun _ ->
        incr attempts;
        Eio.Time.sleep clock 0.01;
        raise (Unix.Unix_error (Unix.ECONNREFUSED, "connect", "")))
      ~create:(fun () -> Alcotest.fail "all addresses fail"));
  Alcotest.(check bool) "deadline stops before all addresses are exhausted"
    true (!attempts < 50);
  check_timeout "Piaf creation uses remaining establishment deadline"
    (establish ~resolve:(fun () -> [()]) ~connect:(fun () -> ())
      ~create:Eio.Fiber.await_cancel);
  let created = ref false in
  check_timeout "DNS and probe time consume the same budget"
    (establish
      ~resolve:(fun () -> Eio.Time.sleep clock 0.03; [()])
      ~connect:(fun () -> Eio.Time.sleep clock 0.03)
      ~create:(fun () -> created := true; Ok ()));
  Alcotest.(check bool) "expired establishment never starts client creation"
    false !created

let test_establishment_cancellation () =
  Eio_main.run @@ fun env ->
  let started, ready = Eio.Promise.create () in
  let cancelled = ref false in
  let result = Eio.Fiber.first
    (fun () ->
      Masc_http_client.Pool.For_testing.establish_connection
        ~clock:(Eio.Stdenv.clock env) ~timeout_seconds:30.0
        ~resolve:(fun () ->
          Eio.Promise.resolve ready ();
          try Eio.Fiber.await_cancel () with
          | Eio.Cancel.Cancelled _ as exn -> cancelled := true; raise exn)
        ~connect:(fun _ -> Alcotest.fail "cancelled DNS reached TCP")
        ~create:(fun () -> Alcotest.fail "cancelled DNS reached Piaf"))
    (fun () -> Eio.Promise.await started; Error "outer cancellation")
  in
  Alcotest.(check bool) "cancellation reaches active establishment stage"
    true !cancelled;
  Alcotest.(check string) "outer cancellation is not a probe failure"
    "outer cancellation" (error_message result)

let () =
  Alcotest.run "Pool_dead_server_fd"
    [ ( "dead-server",
        [ Alcotest.test_case "fd stays flat over 50 refused requests"
            `Quick test_dead_server_fd_flat;
          Alcotest.test_case "backoff fast-fails without a socket"
            `Quick test_backoff_fast_fails_without_socket;
          Alcotest.test_case "backoff expires and retries" `Quick
            test_backoff_expires_and_retries;
          Alcotest.test_case "probe success still creates client" `Quick
            test_probe_success_still_creates_client;
          Alcotest.test_case "failure state cleanup" `Quick
            test_failure_state_cleanup;
          Alcotest.test_case "establishment preserves failure causes" `Quick
            test_establishment_errors;
          Alcotest.test_case "establishment shares one deadline" `Quick
            test_establishment_deadline;
          Alcotest.test_case "establishment propagates cancellation" `Quick
            test_establishment_cancellation ] ) ]
