(* RFC-0107 Phase D.2e — cascade-storm reproducer.

   Live integration test for the connection pool's keep-alive
   contract. An in-process cohttp-eio server takes the role of a
   provider endpoint; 16 concurrent fibers each issue 5 sequential
   requests (80 total) against the same {scheme, host, port}.

   The assertion the pool must satisfy: post-burst pool stats show
   [reuse_count_total] dominating [create_count_total]. With the
   pre-D.2 [make_closing_client] workaround (one fresh TCP+TLS
   session per call), [create_count_total = 80, reuse_count_total = 0],
   which is the cascade-fd-storm anti-pattern RFC-0107 §1.1 names. With
   the D.2 pool, [create_count_total] is bounded by [max_idle_per_host]
   (default 8) and most requests reuse parked connections.

   This test is the Phase F retirement-gate input: it gives a
   deterministic, in-process witness that the D fix actually removes
   the connection-burst pressure that RFC-0101 throttle was patching.

   Limitations:
   - Loopback HTTP only (no TLS) — TLS handshake cost is part of the
     production pressure but is not what the pool reuse contract
     touches. The reuse counter is transport-agnostic.
   - The mock server runs on plain HTTP; piaf still issues HTTP/1.1
     keep-alive. The Host_key normalisation path is exercised
     end-to-end (Uri parse → Host_key.of_uri → per-host queue
     lookup). *)

open Masc_mcp

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.setsockopt socket Unix.SO_REUSEADDR true;
       (match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
        | () -> ()
        | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
          Alcotest.skip ());
       match Unix.getsockname socket with
       | Unix.ADDR_INET (_, port) -> port
       | _ -> failwith "unexpected socket family")
;;

(* The server is given an explicit [stop] promise so the test
   drives shutdown deterministically. [Eio.Fiber.fork_daemon] would
   cancel the accept loop at switch teardown, but cohttp-eio's
   accept loop can hold the switch alive on cancel as it drains
   in-flight connections; an explicit promise sidesteps that race. *)
let start_echo_server ~sw ~net ~port ~stop =
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:1024 body |> take_all) in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok" ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:32 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run ~stop socket server ~on_error:(fun _ -> ()))
;;

(* 16 concurrent fibers × 5 sequential requests each = 80 total. The
   sequential structure inside a fiber matters: it is what lets a
   parked connection be picked up by the same fiber on the next call,
   exercising the keep-alive path the pool exists to enable. *)
let test_keep_alive_dominates_create () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let port = find_free_port () in
  let stop_p, stop_r = Eio.Promise.create () in
  start_echo_server ~sw ~net:(Eio.Stdenv.net env) ~port ~stop:stop_p;
  (* Brief grace to let the listen socket reach LISTEN before clients
     dial — without this, the first few connect() calls race the
     server's [Eio.Net.listen]. 50 ms is well under the test budget. *)
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  let pool = Masc_http_client.Pool.create ~sw ~env () in
  (* Sanity: one request first to surface piaf/eio plumbing bugs
     before scaling up. Failure here points at fixture (server start /
     listen race / piaf init) rather than the reuse contract. *)
  (match
     Masc_http_client.Pool.request pool ~method_:`GET ~url
       ~headers:[ "accept", "text/plain" ] ()
   with
   | Ok { Masc_http_client.Pool.status = 200; _ } -> ()
   | Ok { status; _ } ->
     Alcotest.failf "single-request sanity got HTTP %d (expected 200)" status
   | Error msg -> Alcotest.failf "single-request sanity failed: %s" msg);
  let fiber_count = 16 in
  let per_fiber_requests = 5 in
  (* Sanity request counts toward [total]; the pool's stats counters
     are global to the pool instance. *)
  let total = (fiber_count * per_fiber_requests) + 1 in
  let work () =
    for _ = 1 to per_fiber_requests do
      match
        Masc_http_client.Pool.request pool ~method_:`GET ~url
          ~headers:[ "accept", "text/plain" ] ()
      with
      | Ok { Masc_http_client.Pool.status = 200; _ } -> ()
      | Ok { status; _ } ->
        Alcotest.failf "unexpected status %d from echo server" status
      | Error msg -> Alcotest.failf "request failed: %s" msg
    done
  in
  Eio.Fiber.all (List.init fiber_count (fun _ -> work));
  let stats = Masc_http_client.Pool.stats pool in
  (* Sanity: every request reached the server. *)
  let observed = stats.reuse_count_total + stats.create_count_total in
  Alcotest.(check int)
    "every request accounted for (reuse + create == total)"
    total observed;
  (* The reuse contract. With single-host, single-port traffic the
     pool should rarely create more than [max_idle_per_host = 8]
     connections; the rest reuse. We assert the looser bound
     [create_count_total <= fiber_count] to allow for the worst case
     where the 16 fibers happen to interleave such that every fiber
     misses the parked queue once. *)
  Alcotest.(check bool)
    (Printf.sprintf
       "create_count_total bounded by fiber concurrency (got create=%d, \
        reuse=%d, fibers=%d)"
       stats.create_count_total stats.reuse_count_total fiber_count)
    true
    (stats.create_count_total <= fiber_count);
  Alcotest.(check bool)
    (Printf.sprintf "reuse_count_total dominates (got reuse=%d > %d)"
       stats.reuse_count_total (total - fiber_count - 1))
    true
    (stats.reuse_count_total > total - fiber_count - 1);
  (* Drive the server's accept loop to exit so the switch can
     unwind cleanly. *)
  Eio.Promise.resolve stop_r ()
;;

let () =
  Alcotest.run "rfc-0107 phase d.2e — cascade-storm reproducer"
    [
      ( "keep-alive reuse on single host",
        [
          Alcotest.test_case "16 fibers x 5 requests dominate via reuse"
            `Slow test_keep_alive_dominates_create;
        ] );
    ]
;;
