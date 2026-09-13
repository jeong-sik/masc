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
  (* One request before the baseline. What this case holds is that a refused
     request keeps no descriptor -- growth per request -- and the first
     request through a fresh pool also opens the things a first request opens
     once: the count came out 1 whether the loop ran 5 times or 200, so what
     was being measured was first use, not a leak. Measured on macOS 26,
     2026-09-13.

     The warm-up is asserted like the rest: if the first request stopped
     failing at TCP, the loop below would be measuring a different thing. *)
  let warm_up =
    error_message (Masc_http_client.Pool.request pool ~method_:`GET ~url ())
  in
  Alcotest.(check bool) "the warm-up request is refused like the rest" true
    (Astring.String.is_prefix ~affix:"TCP connect failed:" warm_up);
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
      ~create:(fun selected ->
        Alcotest.(check bool) "client receives reachable address" true selected;
        Ok "created"))

let test_later_address_after_client_failure () =
  Eio_main.run @@ fun env ->
  let establish ~create =
    Masc_http_client.Pool.For_testing.establish_connection
      ~clock:(Eio.Stdenv.clock env) ~timeout_seconds:1.0
      ~resolve:(fun () -> [1; 2; 3]) ~connect:(fun _ -> ()) ~create in
  let attempts = ref [] in
  Alcotest.(check (result int string)) "later address establishes the client"
    (Ok 2)
    (establish ~create:(fun address ->
      attempts := address :: !attempts;
      if address = 1 then Error "first TLS failure" else Ok address));
  Alcotest.(check (list int)) "stop at the first established client"
    [1; 2] (List.rev !attempts);
  Alcotest.(check string) "all client failures preserve the last cause"
    "TLS failure at 3"
    (error_message (establish ~create:(fun address ->
      Error (Printf.sprintf "TLS failure at %d" address))))

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
      ~create:(fun _ -> Alcotest.fail "all addresses fail"));
  Alcotest.(check bool) "deadline stops before all addresses are exhausted"
    true (!attempts < 50);
  check_timeout "Piaf creation uses remaining establishment deadline"
    (establish ~resolve:(fun () -> [()]) ~connect:(fun () -> ())
      ~create:Eio.Fiber.await_cancel);
  let client_attempts = ref 0 in
  check_timeout "client failures do not renew the address scan deadline"
    (establish ~resolve:(fun () -> List.init 50 Fun.id) ~connect:(fun _ -> ())
      ~create:(fun _ ->
        incr client_attempts;
        Eio.Time.sleep clock 0.01;
        Error "TLS failure"));
  Alcotest.(check bool) "deadline interrupts client fallback before exhaustion"
    true (!client_attempts < 50);
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

(* Each accepted socket has its own switch. Completion is published after
   that switch closes, so FD measurements exclude server-side socket races.
   [serve] returns false for the probe's connect-and-close, true for a real
   TLS/HTTP conversation. *)
let start_loopback_server ~sw env serve =
  let listener = Eio.Net.listen (Eio.Stdenv.net env) ~sw
    ~reuse_addr:true ~backlog:8 (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr listener with
    | `Tcp (_, port) -> port
    | `Unix _ -> Alcotest.fail "expected TCP listener" in
  let completed = Eio.Stream.create 1 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      let handled = Eio.Switch.run (fun connection_sw ->
        let flow, _ = Eio.Net.accept listener ~sw:connection_sw in
        serve flow) in
      if handled then Eio.Stream.add completed ();
      loop ()
    in loop ());
  port, completed

let fd_count () =
  match (Fd_accountant.fd_snapshot ()).fd_open with
  | Some count -> count
  | None -> Alcotest.fail "FD counter unavailable for socket lifetime regression"

let tls_started flow =
  try
    let first_byte = Cstruct.create 1 in
    ignore (Eio.Flow.single_read flow first_byte);
    Alcotest.(check int) "client sent a TLS handshake record" 22
      (Cstruct.get_uint8 first_byte 0);
    true
  with End_of_file -> false

let test_failed_tls_fd_flat () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let handshakes = ref 0 in
  let port, completed = start_loopback_server ~sw env (fun flow ->
    if not (tls_started flow) then false else begin
      incr handshakes;
      Eio.Flow.copy_string "HTTP/1.1 400 Bad Request\r\n\r\n" flow;
      true
    end) in
  let config = { Masc_http_client.Pool.default_config with
    connect_failure_cooldown_seconds = 0.0 } in
  let pool = Masc_http_client.Pool.create ~sw ~env ~config () in
  let url = Printf.sprintf "https://127.0.0.1:%d/" port in
  let attempt () =
    (* Bound ordinary network waits. CI's process timeout must cover a
       deadlock in cancellation-protected cleanup. *)
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      ignore (error_message
        (Masc_http_client.Pool.request pool ~method_:`GET ~url ()));
      Eio.Stream.take completed)
  in
  attempt (); (* Initialize TLS before measuring repeated failures. *)
  let before_ = fd_count () in
  for _ = 1 to 50 do attempt () done;
  Alcotest.(check int) "every request reached TLS after its probe" 51 !handshakes;
  Alcotest.(check int) "failed TLS retains no client descriptors"
    before_ (fd_count ());
  Alcotest.(check int) "no failed TLS client was pooled" 0
    (Masc_http_client.Pool.stats pool).total_idle;
  Masc_http_client.Pool.shutdown pool

let drain_until_eof flow =
  let buf = Cstruct.create 4096 in
  let rec loop () = ignore (Eio.Flow.single_read flow buf); loop () in
  try loop () with End_of_file -> ()

let test_cancelled_tls_fd_flat () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let started = Eio.Stream.create 1 in
  let port, completed = start_loopback_server ~sw env (fun flow ->
    if not (tls_started flow) then false else begin
      Eio.Stream.add started ();
      drain_until_eof flow;
      true
    end) in
  let config = { Masc_http_client.Pool.default_config with
    (* Keep cooldown enabled: repeated caller cancellations must not
       populate it or suppress the next real handshake. *)
    connect_timeout_seconds = 30.0 } in
  let pool = Masc_http_client.Pool.create ~sw ~env ~config () in
  let url = Printf.sprintf "https://127.0.0.1:%d/" port in
  let cancelled = ref 0 in
  let attempt () =
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      let result = Eio.Fiber.first
        (fun () ->
          try Masc_http_client.Pool.request pool ~method_:`GET ~url () with
          | Eio.Cancel.Cancelled _ as exn -> incr cancelled; raise exn)
        (fun () ->
          Eio.Stream.take started;
          Error "cancelled after TLS started") in
      Alcotest.(check string) "caller cancels a live TLS handshake"
        "cancelled after TLS started" (error_message result);
      (* The server's EOF proves the client close happened before returning
         to the next attempt, while the pool switch remains alive. *)
      Eio.Stream.take completed)
  in
  attempt ();
  let before_ = fd_count () in
  for _ = 1 to 50 do attempt () done;
  Alcotest.(check int) "every stalled handshake propagated cancellation" 51 !cancelled;
  Alcotest.(check int) "cancelled TLS retains no client descriptors"
    before_ (fd_count ());
  Alcotest.(check int) "cancellation does not create backoff state" 0
    (Masc_http_client.Pool.For_testing.connect_failure_count pool);
  Masc_http_client.Pool.shutdown pool

let env_with_clock (env : Eio_unix.Stdenv.base) clock : Eio_unix.Stdenv.base =
  object
    method clock = clock
    method net = env#net
    method stdin = env#stdin
    method stdout = env#stdout
    method stderr = env#stderr
    method domain_mgr = env#domain_mgr
    method process_mgr = env#process_mgr
    method mono_clock = env#mono_clock
    method fs = env#fs
    method cwd = env#cwd
    method secure_random = env#secure_random
    method debug = env#debug
    method backend_id = env#backend_id
  end

let test_establishment_timeout_during_tls () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let module Pool = Masc_http_client.Pool in
  let started = Eio.Stream.create 1 in
  let handshakes = ref 0 in
  let port, completed = start_loopback_server ~sw env (fun flow ->
    if not (tls_started flow) then false else begin
      (* tls_started consumed the record type. Read the remaining record
         header (version + length) and the handshake message type. *)
      let hello_header = Cstruct.create 5 in
      Eio.Flow.read_exact flow hello_header;
      Alcotest.(check int) "handshake message is ClientHello" 1
        (Cstruct.get_uint8 hello_header 4);
      incr handshakes;
      Eio.Stream.add started ();
      drain_until_eof flow;
      true
    end) in
  let mock_clock = Eio_mock.Clock.make () in
  let pool_env = env_with_clock env
    (mock_clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  let config = Pool.default_config in
  let pool = Pool.create ~sw ~env:pool_env ~config () in
  let url = Printf.sprintf "https://127.0.0.1:%d/" port in
  let attempt () =
    (* The real clock only bounds broken fixture I/O. The pool's own
       establishment timer is fired deterministically after TLS starts. *)
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      let deadline = Eio.Time.now mock_clock +. config.connect_timeout_seconds in
      let result, () = Eio.Fiber.pair
        (fun () -> Pool.request pool ~method_:`GET ~url ())
        (fun () ->
          Eio.Stream.take started;
          Eio_mock.Clock.set_time mock_clock deadline) in
      Alcotest.(check string) "configured establishment timeout during real TLS"
        (Printf.sprintf "connect timeout: https://127.0.0.1:%d" port)
        (error_message result);
      (* Published after the server sees EOF and closes its own socket. *)
      Eio.Stream.take completed;
      Eio.Switch.check sw)
  in
  attempt ();
  Alcotest.(check int) "timeout records a connect failure" 1
    (Pool.For_testing.connect_failure_count pool);
  let before_ = fd_count () in
  let backoff = error_message (Pool.request pool ~method_:`GET ~url ()) in
  Alcotest.(check bool) "timeout activates configured cooldown" true
    (Astring.String.is_prefix ~affix:"connect backoff:" backoff);
  Alcotest.(check int) "backoff started no new TLS handshake" 1 !handshakes;
  Alcotest.(check int) "backoff opened no descriptor" before_ (fd_count ());
  for _ = 1 to 50 do
    Eio_mock.Clock.set_time mock_clock
      (Eio.Time.now mock_clock +. config.connect_failure_cooldown_seconds);
    attempt ()
  done;
  Alcotest.(check int) "every expiry occurred after a real ClientHello" 51 !handshakes;
  Alcotest.(check int) "timed-out TLS retains no descriptors while pool is alive"
    before_ (fd_count ());
  let stats = Pool.stats pool in
  Alcotest.(check int) "timed-out construction never returned a client" 0
    stats.create_count_total;
  Alcotest.(check int) "no timed-out client was parked" 0 stats.total_idle;
  Pool.shutdown pool

let test_healthy_reuse_and_scope_shutdown ~explicit () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let requests = ref 0 in
  let port, completed = start_loopback_server ~sw env (fun flow ->
    let reader = Eio.Buf_read.of_flow flow ~max_size:4096 in
    let handled = ref false in
    let rec headers () =
      if Eio.Buf_read.line reader <> "" then headers () in
    let rec loop () =
      ignore (Eio.Buf_read.line reader);
      handled := true;
      headers ();
      incr requests;
      Eio.Flow.copy_string
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" flow;
      loop () in
    (try loop () with End_of_file -> ());
    !handled) in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  let before_ = fd_count () in
  Eio.Time.with_timeout_exn clock 5.0 (fun () ->
    Eio.Switch.run (fun pool_sw ->
      let pool = Masc_http_client.Pool.create ~sw:pool_sw ~env () in
      for _ = 1 to 2 do
        match Masc_http_client.Pool.request pool ~method_:`GET ~url () with
        | Error msg -> Alcotest.fail msg
        | Ok response -> Alcotest.(check string) "healthy response" "ok" response.body
      done;
      let stats = Masc_http_client.Pool.stats pool in
      Alcotest.(check int) "one client survived both requests" 1 stats.create_count_total;
      Alcotest.(check int) "second request reused the client" 1 stats.reuse_count_total;
      Alcotest.(check int) "client parked before shutdown" 1 stats.total_idle;
      if explicit then Masc_http_client.Pool.shutdown pool);
    Eio.Stream.take completed);
  Alcotest.(check int) "server handled both requests" 2 !requests;
  Alcotest.(check int) "shutdown closes the client scope"
    before_ (fd_count ())

let test_cancelled_pool_before_client_construction () =
  Eio_main.run @@ fun env ->
  let before_ = fd_count () in
  let cancelled = ref false in
  (try Eio.Switch.run (fun sw ->
    let listener = Eio.Net.listen (Eio.Stdenv.net env) ~sw
      ~reuse_addr:true ~backlog:2 (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr listener with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "expected TCP listener" in
    let pool = Masc_http_client.Pool.create ~sw ~env () in
    Eio.Switch.fail sw Exit;
    (* Protect the caller so the TCP probe reaches create's pool-switch
       check. No daemon can be spawned on this cancelled switch. *)
    Eio.Cancel.protect (fun () ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
        try
          ignore (Masc_http_client.Pool.request pool ~method_:`GET
            ~url:(Printf.sprintf "http://127.0.0.1:%d/" port) ());
          Alcotest.fail "cancelled pool accepted client construction"
        with Eio.Cancel.Cancelled _ -> cancelled := true)))
   with Exit -> ());
  Alcotest.(check bool) "construction observes cancelled pool switch"
    true !cancelled;
  Alcotest.(check int) "cancelled construction leaves no scope or socket"
    before_ (fd_count ())

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
          Alcotest.test_case "client failure continues through resolved addresses" `Quick
            test_later_address_after_client_failure;
          Alcotest.test_case "establishment shares one deadline" `Quick
            test_establishment_deadline;
          Alcotest.test_case "establishment propagates cancellation" `Quick
            test_establishment_cancellation;
          Alcotest.test_case "failed TLS releases descriptors" `Quick
            test_failed_tls_fd_flat;
          Alcotest.test_case "cancelled TLS releases descriptors" `Quick
            test_cancelled_tls_fd_flat;
          Alcotest.test_case "establishment timeout closes real TLS and records backoff" `Quick
            test_establishment_timeout_during_tls;
          Alcotest.test_case "healthy client reuses and shuts down" `Quick
            (test_healthy_reuse_and_scope_shutdown ~explicit:true);
          Alcotest.test_case "parent teardown closes parked client" `Quick
            (test_healthy_reuse_and_scope_shutdown ~explicit:false);
          Alcotest.test_case "cancelled pool cannot start a client scope" `Quick
            test_cancelled_pool_before_client_construction ] ) ]
