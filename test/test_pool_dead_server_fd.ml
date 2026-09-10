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

let () =
  Alcotest.run "Pool_dead_server_fd"
    [ ( "dead-server",
        [ Alcotest.test_case "fd stays flat over 50 refused requests"
            `Quick test_dead_server_fd_flat ] ) ]
