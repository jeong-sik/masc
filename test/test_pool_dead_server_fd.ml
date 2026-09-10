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

let test_dead_server_fd_flat () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Masc_http_client.Pool.create ~sw ~env () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
  let fd_before = (Fd_accountant.fd_snapshot ()).fd_open in
  for _ = 1 to 50 do
    ignore
      (Masc_http_client.Pool.request pool ~method_:`GET ~url ()
        : (Masc_http_client.Pool.response, string) result)
  done;
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

let error_message = function
  | Ok _ -> Alcotest.fail "expected Error from a dead server"
  | Error msg -> msg

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
    (Astring.String.is_prefix ~affix:"connect refused:" first_msg
     || Astring.String.is_infix ~affix:"connect" first_msg);
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
  Unix.close listen

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
            test_probe_success_still_creates_client ] ) ]
