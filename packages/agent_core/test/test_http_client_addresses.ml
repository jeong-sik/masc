open Llm_provider

(* DNS is controlled, while healthy candidates and HTTP use real loopback TCP.
   Failed/pending candidates allocate real descriptors on the supplied switch,
   matching backends that allocate before connect completes. *)
module Routed_net = struct
  type tag = [ `Generic | `Unix ]
  type t =
    { net : tag Eio.Net.ty Eio.Resource.t
    ; addresses : Eio.Net.Sockaddr.stream list
    ; connect : sw:Eio.Switch.t -> Eio.Net.Sockaddr.stream -> tag Eio.Net.stream_socket_ty Eio.Resource.t
    }

  let connect t = t.connect
  let getaddrinfo t ~service:_ _ = (t.addresses :> Eio.Net.Sockaddr.t list)
  let getnameinfo t = Eio.Net.getnameinfo t.net
  let listen t ~reuse_addr ~reuse_port ~backlog ~sw address =
    Eio.Net.listen t.net ~reuse_addr ~reuse_port ~backlog ~sw address
  let datagram_socket t ~reuse_addr ~reuse_port ~sw address =
    Eio.Net.datagram_socket t.net ~reuse_addr ~reuse_port ~sw address
end

let routed_net ~net ~addresses ~connect =
  Eio.Resource.T ({ Routed_net.net; addresses; connect }, Eio.Net.Pi.network (module Routed_net))

let allocate_attempt_fds ~sw fds =
  let source, sink = Eio_unix.Net.socketpair_stream ~sw () in
  fds := Eio_unix.Resource.fd source :: Eio_unix.Resource.fd sink :: !fds

let all_closed fds = List.for_all (fun fd -> not (Eio_unix.Fd.is_open fd)) !fds

let with_runtime f () =
  Eio_main.run (fun env ->
    (* Test watchdog only: production racing adds no deadline. *)
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
      Eio.Switch.run (fun sw -> f env sw)))

let start_server ~sw ~net ?(status = `OK) () =
  let requests = ref 0 in
  let socket = Eio.Net.listen ~sw ~backlog:8 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let callback _ _ body =
    incr requests;
    ignore (Eio.Buf_read.(of_flow ~max_size:4096 body |> take_all) : string);
    Cohttp_eio.Server.respond_string ~status ~body:"one response" ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Eio.Net.listening_addr socket, requests

let post ?cache net =
  Http_client.post_sync_once ?cache ~net ~url:"http://provider.test/request"
    ~headers:[] ~body:"one request" ()

let check_success = function
  | Ok response -> Alcotest.(check string) "response body" "one response" response.Http_client.body
  | Error _ -> Alcotest.fail "expected a successful HTTP request"

let test_refused_then_healthy = with_runtime (fun env sw ->
  let healthy, requests = start_server ~sw ~net:env#net () in
  let dead = Eio.Net.listen ~sw ~backlog:1 env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let refused = Eio.Net.listening_addr dead in
  Eio.Resource.close dead;
  let attempted = ref [] in
  let net = routed_net ~net:env#net ~addresses:[refused; healthy]
      ~connect:(fun ~sw address ->
        attempted := address :: !attempted;
        Eio.Net.connect ~sw env#net address) in
  check_success (post net);
  Alcotest.(check int) "both TCP candidates attempted" 2 (List.length !attempted);
  Alcotest.(check int) "one HTTP dispatch" 1 !requests)

let test_blackhole_and_cache = with_runtime (fun env sw ->
  let healthy, requests = start_server ~sw ~net:env#net () in
  let blackhole = `Tcp (Eio.Net.Ipaddr.V6.loopback, 1) in
  let started, start = Eio.Promise.create () in
  let fds = ref [] in
  let net = routed_net ~net:env#net ~addresses:[blackhole; healthy]
      ~connect:(fun ~sw address ->
        if address = blackhole then (
          allocate_attempt_fds ~sw fds;
          Eio.Promise.resolve start ();
          Eio.Fiber.await_cancel ())
        else (
          Eio.Promise.await started;
          Eio.Net.connect ~sw env#net address)) in
  let cache = Http_client.create_cache ~sw () in
  check_success (post ~cache net);
  Alcotest.(check bool) "pending descriptors closed while cache lives" true (all_closed fds);
  check_success (post ~cache net);
  Alcotest.(check int) "one request per call" 2 !requests;
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "winner survives for reuse" 1 stats.reuse_count_total;
  Alcotest.(check int) "one cached winner" 1 stats.total_idle)

let test_failed_attempts_do_not_accumulate = with_runtime (fun env sw ->
  let first = `Tcp (Eio.Net.Ipaddr.V6.loopback, 1) in
  let last = `Tcp (Eio.Net.Ipaddr.V4.loopback, 2) in
  let fds = ref [] in
  let cache = Http_client.create_cache ~sw () in
  for _ = 1 to 16 do
    let last_failed, fail_last = Eio.Promise.create () in
    let net = routed_net ~net:env#net ~addresses:[first; last]
        ~connect:(fun ~sw address ->
          allocate_attempt_fds ~sw fds;
          if address = first then (
            Eio.Promise.await last_failed;
            raise (Unix.Unix_error (Unix.ECONNREFUSED, "connect", "first")))
          else (
            Eio.Promise.resolve fail_last ();
            raise (Unix.Unix_error (Unix.ENETUNREACH, "connect", "last")))) in
    (match post ~cache net with
     | Error (Http_client.Before_dispatch_error (Http_client.NetworkError {kind = Dns_failure; _})) -> ()
     | _ -> Alcotest.fail "expected last DNS-order error even when it fails first");
    Alcotest.(check bool) "all real attempt descriptors closed before next request" true (all_closed fds)
  done;
  Alcotest.(check int) "cache still empty and alive" 0 (Http_client.cache_stats cache).total_idle)

exception Caller_cancelled

let test_caller_cancellation = with_runtime (fun env sw ->
  let started, start = Eio.Promise.create () in
  let attempts = ref 0 in
  let fds = ref [] in
  let net = routed_net ~net:env#net
      ~addresses:[`Tcp (Eio.Net.Ipaddr.V6.loopback, 1); `Tcp (Eio.Net.Ipaddr.V4.loopback, 2)]
      ~connect:(fun ~sw _ ->
        allocate_attempt_fds ~sw fds;
        incr attempts;
        if !attempts = 2 then Eio.Promise.resolve start ();
        Eio.Fiber.await_cancel ()) in
  let cache = Http_client.create_cache ~sw () in
  (try
     Eio.Cancel.sub (fun cancel ->
       Eio.Fiber.both
         (fun () -> ignore (post ~cache net))
         (fun () -> Eio.Promise.await started; Eio.Cancel.cancel cancel Caller_cancelled))
   with Eio.Cancel.Cancelled Caller_cancelled -> ());
  Alcotest.(check int) "both attempts were pending" 2 !attempts;
  Alcotest.(check bool) "cancelled attempts closed before caller resumes" true (all_closed fds);
  Alcotest.(check int) "owner cache remains usable" 0 (Http_client.cache_stats cache).total_idle)

let test_simultaneous_connections = with_runtime (fun env sw ->
  let healthy, requests = start_server ~sw ~net:env#net ~status:`Service_unavailable () in
  let both_connected, connected = Eio.Promise.create () in
  let sockets = ref [] in
  let net = routed_net ~net:env#net ~addresses:[healthy; healthy]
      ~connect:(fun ~sw address ->
        let socket = Eio.Net.connect ~sw env#net address in
        sockets := Eio_unix.Net.fd socket :: !sockets;
        if List.length !sockets = 2 then Eio.Promise.resolve connected ();
        Eio.Promise.await both_connected;
        socket) in
  let cache = Http_client.create_cache ~sw () in
  (match post ~cache net with
   | Ok response -> Alcotest.(check int) "original HTTP failure response" 503 response.status
   | Error _ -> Alcotest.fail "expected HTTP response");
  Alcotest.(check int) "both candidates connected" 2 (List.length !sockets);
  Alcotest.(check int) "only winning TCP socket remains open" 1
    (List.length (List.filter Eio_unix.Fd.is_open !sockets));
  Alcotest.(check int) "HTTP failure is not replayed on other connection" 1 !requests)

let test_tls_failure_is_not_replayed = with_runtime (fun env sw ->
  (* A plain HTTP peer rejects a TLS ClientHello. Both TCP connections can
     complete, but only the selected connection may start TLS. *)
  let listener = Eio.Net.listen ~sw ~backlog:8 env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let address = Eio.Net.listening_addr listener in
  let handshakes = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Net.run_server listener ~on_error:(fun _ -> ()) (fun socket _ ->
      let buf = Cstruct.create 4096 in
      match Eio.Flow.single_read socket buf with
      | _ -> incr handshakes; Eio.Flow.copy_string "HTTP/1.1 400 Bad Request\r\n\r\n" socket
      | exception End_of_file -> ()));
  let sockets = ref [] in
  let net = routed_net ~net:env#net ~addresses:[address; address]
      ~connect:(fun ~sw address ->
        let socket = Eio.Net.connect ~sw env#net address in
        sockets := Eio_unix.Net.fd socket :: !sockets;
        socket) in
  let cache = Http_client.create_cache ~sw () in
  (match Http_client.post_sync_once ~cache ~net ~url:"https://provider.test/request"
      ~headers:[] ~body:"one request" () with
   | Error (Http_client.Before_dispatch_error _) -> ()
   | _ -> Alcotest.fail "expected TLS failure before dispatch");
  Alcotest.(check int) "TLS only starts on the winner" 1 !handshakes;
  Alcotest.(check bool) "failed TLS winner and other sockets closed" true (all_closed sockets))

exception Owner_stopped

type owner_stop_phase = Pending | Connected | Parked

let test_cache_owner_cancellation phase =
  with_runtime (fun env server_sw ->
    let address, _ = start_server ~sw:server_sw ~net:env#net () in
    let fds = ref [] in
    (try
       Eio.Switch.run (fun owner_sw ->
         let reached, reach = Eio.Promise.create () in
         let net = routed_net ~net:env#net ~addresses:[address]
             ~connect:(fun ~sw address ->
               match phase with
               | Pending ->
                 allocate_attempt_fds ~sw fds;
                 Eio.Promise.resolve reach ();
                 Eio.Fiber.await_cancel ()
               | Connected | Parked ->
                 let socket = Eio.Net.connect ~sw env#net address in
                 fds := Eio_unix.Net.fd socket :: !fds;
                 (match phase with
                  | Connected ->
                    Eio.Promise.resolve reach ();
                    Eio.Fiber.yield ()
                  | Pending | Parked -> ());
                 socket) in
         let cache = Http_client.create_cache ~sw:owner_sw () in
         Eio.Fiber.fork ~sw:owner_sw (fun () ->
           Eio.Promise.await reached;
           Eio.Switch.fail owner_sw Owner_stopped);
         check_success (post ~cache net);
         match phase with
         | Parked -> Eio.Promise.resolve reach ()
         | Pending | Connected -> Alcotest.fail "request completed before owner cancellation")
     with Owner_stopped -> ());
    Alcotest.(check bool) "owner cancellation closes every socket" true (all_closed fds))

let test_last_eio_failure_kind =
  with_runtime (fun env sw ->
    let first = `Tcp (Eio.Net.Ipaddr.V6.loopback, 1) in
    let last = `Tcp (Eio.Net.Ipaddr.V4.loopback, 2) in
    let net = routed_net ~net:env#net ~addresses:[first; last]
        ~connect:(fun ~sw:_ address ->
          let failure = if address = last then Eio.Net.Timeout else Eio.Net.No_matching_addresses in
          raise (Eio.Net.err (Eio.Net.Connection_failure failure))) in
    (match post net with
     | Error (Http_client.Before_dispatch_error (Http_client.NetworkError {kind = Timeout; _})) -> ()
     | _ -> Alcotest.fail "last typed Eio connection error must survive classification");
    Eio.Switch.check sw)

let () = Alcotest.run "HTTP resolved addresses"
    ["connection ownership",
     [Alcotest.test_case "owner cancelled during connect" `Quick (test_cache_owner_cancellation Pending);
      Alcotest.test_case "owner cancelled after TCP acquisition" `Quick (test_cache_owner_cancellation Connected);
      Alcotest.test_case "owner cancelled with parked connection" `Quick (test_cache_owner_cancellation Parked);
      Alcotest.test_case "last Eio failure preserves typed kind" `Quick test_last_eio_failure_kind;
      Alcotest.test_case "refused then healthy single dispatch" `Quick test_refused_then_healthy;
      Alcotest.test_case "blackhole cannot block reachable peer or cache reuse" `Quick test_blackhole_and_cache;
      Alcotest.test_case "all failures preserve last error without FD accumulation" `Quick test_failed_attempts_do_not_accumulate;
      Alcotest.test_case "caller cancellation closes pending sockets" `Quick test_caller_cancellation;
      Alcotest.test_case "simultaneous TCP winners do not replay HTTP" `Quick test_simultaneous_connections;
      Alcotest.test_case "TLS failure closes winner without another handshake" `Quick test_tls_failure_is_not_replayed]]
