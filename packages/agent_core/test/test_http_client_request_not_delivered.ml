(** A request cut off while its bytes were still going out closes its
    connection as [Request_not_delivered]; every other failure stays
    [Request_failed] (RFC-0492 §6 tests 2 and 4, and 1(나) as a count). The
    small-request case of test 1(가) is in test_http_client_cache.ml.

    https providers are the ones that matter. A cache made with [~tls_config]
    trusts a test certificate, so the https tests run the same cut-offs over
    TLS. [Http_client]'s [net] argument takes only a [`Unix] network, so a mock
    network cannot stand in. Two tests check the facts the count stands on:
    which exceptions [transport_named_peer_close] names, and that tls-eio passes
    the errno of a failed write through. An unnamed close such as tls-eio's
    [Tls_socket_closed] is checked there and not over TLS. tls-eio raises it
    from a write only after this side shut the session's write direction down,
    and it raises a stored [Tls_failure] or [Tls_alert] only after a read on the
    session failed. [Http_client] does neither before it writes a request. *)

open Llm_provider

(* Listens on port 0 and reads back the address the kernel assigned, so no
   other process can take the port between choosing it and listening. *)
let listen_on_a_free_port ~sw ~net =
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> socket, port
  | `Unix _ -> Alcotest.fail "the loopback listener has no TCP port"
;;

(* Closing with SO_LINGER 0 sends RST instead of FIN, which the peer's next
   read or write reports as ECONNRESET or EPIPE. The handler's return closes
   the flow. *)
let reset_on_close flow =
  match Eio_unix.Resource.fd_opt flow with
  | Some fd ->
    Eio_unix.Fd.use_exn "reset_on_close" fd (fun unix_fd ->
      Unix.setsockopt_optint unix_fd Unix.SO_LINGER (Some 0))
  | None -> Alcotest.fail "the server's flow has no file descriptor"
;;

let read_request reader =
  ignore (Eio.Buf_read.line reader : string);
  let rec read_headers content_length =
    let line = Eio.Buf_read.line reader |> String.trim in
    if String.equal line ""
    then content_length
    else (
      match String.split_on_char ':' line with
      | [ name; value ] when String.equal (String.lowercase_ascii name) "content-length" ->
        read_headers (int_of_string (String.trim value))
      | _ -> read_headers content_length)
  in
  ignore (Eio.Buf_read.take (read_headers 0) reader : string)
;;

let ok_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"

(* Runs [handler] for every accepted connection and counts them. *)
let start_server ~sw ~net handler =
  let socket, port = listen_on_a_free_port ~sw ~net in
  let accepted = Atomic.make 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> ()) (fun flow _addr ->
        Atomic.incr accepted;
        try handler flow with
        | End_of_file | Eio.Io _ | Unix.Unix_error _ -> ())
    done);
  Printf.sprintf "http://127.0.0.1:%d/v1" port, accepted
;;

let with_cache ?tls_config f =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    f
      ~sw
      ~net:env#net
      ~cache:(Http_client.create_cache ~sw ~mono_clock:env#mono_clock ?tls_config ());
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let post ~cache ~net ~url body =
  Http_client.post_sync_once
    ~cache
    ~net
    ~url
    ~headers:
      [ "Content-Type", "application/json"
      ; "Content-Length", string_of_int (String.length body)
      ]
    ~body
    ()
;;

(* Larger than the loopback socket buffers, so the write is split across
   several calls. *)
let large_body = String.make (16 * 1024 * 1024) 'x'

let describe_http_error : Http_client.http_error -> string = function
  | HttpError { code; _ } -> Printf.sprintf "HttpError %d" code
  | NetworkError { message; _ } -> "NetworkError: " ^ message
  | TimeoutError { message; _ } -> "TimeoutError: " ^ message
  | AcceptRejected { reason } -> "AcceptRejected: " ^ reason
  | ProviderTerminal { message; _ } -> "ProviderTerminal: " ^ message
  | ProviderFailure { message; _ } -> "ProviderFailure: " ^ message
;;

let describe_post_error : Http_client.post_sync_once_error -> string = function
  | Before_dispatch_error error -> "Before_dispatch_error " ^ describe_http_error error
  | Dispatch_started_error error -> "Dispatch_started_error " ^ describe_http_error error
  | Response_received_error { status; error } ->
    Printf.sprintf "Response_received_error %d %s" status (describe_http_error error)
;;

let expect_dispatch_network_error label = function
  | Error (Http_client.Dispatch_started_error (Http_client.NetworkError _)) -> ()
  | Ok _ -> Alcotest.failf "%s: the request was answered" label
  | Error error ->
    Alcotest.failf "%s: expected a network error after dispatch started, got %s" label
      (describe_post_error error)
;;

(* Test 2. The server reads the whole request, then resets before it answers.
   The request reached the server, so it stays [Request_failed]. *)
let test_reset_after_the_request_was_read () =
  with_cache
  @@ fun ~sw ~net ~cache ->
  let requests = Atomic.make 0 in
  let url, _ =
    start_server ~sw ~net (fun flow ->
      read_request (Eio.Buf_read.of_flow ~max_size:max_int flow);
      Atomic.incr requests;
      reset_on_close flow)
  in
  expect_dispatch_network_error "reset after the read" (post ~cache ~net ~url "{}");
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "the server received the request once" 1 (Atomic.get requests);
  Alcotest.(check int) "closed as a failed request" 1 stats.closed_total.request_failed;
  Alcotest.(check int)
    "not counted as not delivered"
    0
    stats.closed_total.request_not_delivered
;;

(* Test 4. The server reads the request line of a new connection and resets,
   and the body is larger than the socket buffers. A write call fails with the
   peer's reset and no response byte came back, so the request is not
   delivered. It is not sent again. The reset waits for the request line so
   that it cannot reach the client's connect call, whose failure would be a
   [Before_dispatch_error]. *)
let test_reset_during_a_large_request () =
  with_cache
  @@ fun ~sw ~net ~cache ->
  let url, accepted =
    start_server ~sw ~net (fun flow ->
      ignore (Eio.Buf_read.line (Eio.Buf_read.of_flow ~max_size:max_int flow) : string);
      reset_on_close flow)
  in
  expect_dispatch_network_error "reset during the write" (post ~cache ~net ~url large_body);
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "one connection reached the server" 1 (Atomic.get accepted);
  Alcotest.(check int) "one connection was opened" 1 stats.create_count_total;
  Alcotest.(check int)
    "closed as not delivered"
    1
    stats.closed_total.request_not_delivered;
  Alcotest.(check int) "not as a failed request" 0 stats.closed_total.request_failed;
  Alcotest.(check int)
    "a new connection's close is not counted as reused"
    0
    stats.closed_after_reuse.request_not_delivered
;;

(* Test 1(나) as a count. The server answered the first request and closed the
   connection while the cache held it. The second request, whose body is larger
   than the socket buffers, reuses that connection and is cut off while it is
   written. It is not sent again. *)
let test_a_reused_connection_cut_off_during_a_large_write () =
  with_cache
  @@ fun ~sw ~net ~cache ->
  let url, accepted =
    start_server ~sw ~net (fun flow ->
      read_request (Eio.Buf_read.of_flow ~max_size:max_int flow);
      Eio.Flow.copy_string ok_response flow)
  in
  (match post ~cache ~net ~url "{}" with
   | Ok { status = 200; _ } -> ()
   | Ok _ | Error _ -> Alcotest.fail "the first request should be answered");
  expect_dispatch_network_error "the reused connection" (post ~cache ~net ~url large_body);
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "the second request reused the connection" 1 stats.reuse_count_total;
  Alcotest.(check int) "no second connection was opened" 1 stats.create_count_total;
  Alcotest.(check int) "the server accepted one connection" 1 (Atomic.get accepted);
  Alcotest.(check int)
    "closed as not delivered"
    1
    stats.closed_total.request_not_delivered;
  Alcotest.(check int)
    "and counted as a reused connection's close"
    1
    stats.closed_after_reuse.request_not_delivered
;;

(* The same cut-off through the streaming entry point, which closes its
   connection on its own path. *)
let test_a_streamed_request_cut_off_while_written () =
  with_cache
  @@ fun ~sw ~net ~cache ->
  let url, accepted =
    start_server ~sw ~net (fun flow ->
      ignore (Eio.Buf_read.line (Eio.Buf_read.of_flow ~max_size:max_int flow) : string);
      reset_on_close flow)
  in
  (match
     Http_client.with_post_stream
       ~cache
       ~net
       ~url
       ~headers:[ "Content-Type", "application/json" ]
       ~body:large_body
       ~f:(fun ~pre_header_elapsed_s:_ reader -> Eio.Buf_read.take_all reader)
       ()
   with
   | Error (Http_client.NetworkError _) -> ()
   | Ok _ -> Alcotest.fail "the streamed request was answered"
   | Error error ->
     Alcotest.failf "expected a network error, got %s" (describe_http_error error));
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "one connection reached the server" 1 (Atomic.get accepted);
  Alcotest.(check int)
    "closed as not delivered"
    1
    stats.closed_total.request_not_delivered;
  Alcotest.(check int) "not as a failed request" 0 stats.closed_total.request_failed
;;

(* A backend error like tls-eio's [Tls_socket_closed]: an Eio backend error
   that is not an errno, and that this test cannot name any better than
   [Http_client] can. *)
type Eio.Exn.Backend.t += Unnamed_tls_close

let test_only_a_named_peer_close_is_not_delivered () =
  let unix_error code = Eio_unix.Unix_error (code, "writev", "") in
  let reset backend = Eio.Net.err (Eio.Net.Connection_reset backend) in
  let backend_error backend = Eio.Exn.create (Eio.Exn.X backend) in
  let named =
    [ "EPIPE raised directly", Unix.Unix_error (Unix.EPIPE, "writev", "")
    ; "ECONNRESET raised directly", Unix.Unix_error (Unix.ECONNRESET, "writev", "")
    ; "Connection_reset carrying EPIPE", reset (unix_error Unix.EPIPE)
    ; "Connection_reset carrying ECONNRESET", reset (unix_error Unix.ECONNRESET)
    ; "backend error carrying EPIPE", backend_error (unix_error Unix.EPIPE)
    ; "backend error carrying ECONNRESET", backend_error (unix_error Unix.ECONNRESET)
    ]
  in
  let unnamed =
    [ "Connection_reset with a backend that is not an errno", reset Unnamed_tls_close
    ; "backend error that is not an errno", backend_error Unnamed_tls_close
    ; "Connection_reset carrying another errno", reset (unix_error Unix.EPERM)
    ; "ETIMEDOUT", Unix.Unix_error (Unix.ETIMEDOUT, "writev", "")
    ; "ECONNREFUSED", Unix.Unix_error (Unix.ECONNREFUSED, "connect", "")
    ; "connection failure", Eio.Net.err (Eio.Net.Connection_failure Eio.Net.Timeout)
    ; "End_of_file", End_of_file
    ; "Failure", Failure "write"
    ]
  in
  List.iter
    (fun (label, exn) ->
       Alcotest.(check bool) label true (Http_client.transport_named_peer_close exn))
    named;
  List.iter
    (fun (label, exn) ->
       Alcotest.(check bool) label false (Http_client.transport_named_peer_close exn))
    unnamed
;;

(* ── tls-eio passes a failed write's errno through ───────────────── *)

let make_self_signed () : X509.Certificate.t * X509.Private_key.t =
  let key = X509.Private_key.generate ~bits:2048 `RSA in
  let dn =
    X509.Distinguished_name.
      [ Relative_distinguished_name.singleton (CN (Common_name.v "localhost")) ]
  in
  let csr =
    match X509.Signing_request.create dn key with
    | Ok csr -> csr
    | Error (`Msg msg) -> Alcotest.failf "csr: %s" msg
  in
  let valid_until =
    match Ptime.of_float_s 4102444800. (* 2100-01-01 *) with
    | Some time -> time
    | None -> Alcotest.fail "the certificate end date is not a time"
  in
  match X509.Signing_request.sign csr ~valid_from:Ptime.epoch ~valid_until key dn with
  | Ok certificate -> certificate, key
  | Error _ -> Alcotest.fail "the self-signed certificate could not be signed"
;;

let tls_server_config (certificate, key) =
  match Tls.Config.server ~certificates:(`Single ([ certificate ], key)) () with
  | Ok config -> config
  | Error (`Msg msg) -> Alcotest.failf "tls server config: %s" msg
;;

(* Only the write is under test, not trust, so the peer is accepted as it is. *)
let tls_client_config () =
  match Tls.Config.client ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None) () with
  | Ok config -> config
  | Error (`Msg msg) -> Alcotest.failf "tls client config: %s" msg
;;

let ensure_rng_default () =
  match Mirage_crypto_rng.default_generator () with
  | _ -> ()
  | exception Mirage_crypto_rng.No_default_generator -> Mirage_crypto_rng_unix.use_default ()
;;

(* ── The same cut-offs over https ────────────────────────────────── *)

let https_server_config () =
  ensure_rng_default ();
  tls_server_config (make_self_signed ())
;;

(* Like [start_server], but each connection finishes the TLS handshake first.
   [handler] gets the TLS flow to read and write the request, and the socket
   beneath it to reset. *)
let start_tls_server ~sw ~net ~server_config handler =
  let socket, port = listen_on_a_free_port ~sw ~net in
  let accepted = Atomic.make 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> ()) (fun flow _addr ->
        Atomic.incr accepted;
        try handler (Tls_eio.server_of_flow server_config flow) flow with
        | End_of_file | Eio.Io _ | Unix.Unix_error _ -> ())
    done);
  Printf.sprintf "https://127.0.0.1:%d/v1" port, accepted
;;

let with_https_cache f =
  let server_config = https_server_config () in
  with_cache ~tls_config:(tls_client_config ()) (f ~server_config)
;;

let test_https_reset_during_a_large_request () =
  with_https_cache
  @@ fun ~server_config ~sw ~net ~cache ->
  let url, accepted =
    start_tls_server ~sw ~net ~server_config (fun tls flow ->
      ignore (Eio.Buf_read.line (Eio.Buf_read.of_flow tls ~max_size:max_int) : string);
      reset_on_close flow)
  in
  expect_dispatch_network_error "reset during the write" (post ~cache ~net ~url large_body);
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "one connection reached the server" 1 (Atomic.get accepted);
  Alcotest.(check int)
    "closed as not delivered"
    1
    stats.closed_total.request_not_delivered;
  Alcotest.(check int) "not as a failed request" 0 stats.closed_total.request_failed;
  Alcotest.(check int)
    "a new connection's close is not counted as reused"
    0
    stats.closed_after_reuse.request_not_delivered
;;

let test_https_reset_after_the_request_was_read () =
  with_https_cache
  @@ fun ~server_config ~sw ~net ~cache ->
  let url, _ =
    start_tls_server ~sw ~net ~server_config (fun tls flow ->
      read_request (Eio.Buf_read.of_flow tls ~max_size:max_int);
      reset_on_close flow)
  in
  expect_dispatch_network_error "reset after the read" (post ~cache ~net ~url "{}");
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "closed as a failed request" 1 stats.closed_total.request_failed;
  Alcotest.(check int)
    "not counted as not delivered"
    0
    stats.closed_total.request_not_delivered
;;

let test_https_reused_connection_cut_off_during_a_large_write () =
  with_https_cache
  @@ fun ~server_config ~sw ~net ~cache ->
  let url, accepted =
    start_tls_server ~sw ~net ~server_config (fun tls _flow ->
      read_request (Eio.Buf_read.of_flow tls ~max_size:max_int);
      Eio.Flow.copy_string ok_response tls)
  in
  (match post ~cache ~net ~url "{}" with
   | Ok { status = 200; _ } -> ()
   | Ok _ | Error _ -> Alcotest.fail "the first request should be answered");
  expect_dispatch_network_error "the reused connection" (post ~cache ~net ~url large_body);
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "the second request reused the connection" 1 stats.reuse_count_total;
  Alcotest.(check int) "the server accepted one connection" 1 (Atomic.get accepted);
  Alcotest.(check int)
    "closed as not delivered"
    1
    stats.closed_total.request_not_delivered;
  Alcotest.(check int)
    "and counted as a reused connection's close"
    1
    stats.closed_after_reuse.request_not_delivered
;;

let test_https_streamed_request_cut_off_while_written () =
  with_https_cache
  @@ fun ~server_config ~sw ~net ~cache ->
  let url, accepted =
    start_tls_server ~sw ~net ~server_config (fun tls flow ->
      ignore (Eio.Buf_read.line (Eio.Buf_read.of_flow tls ~max_size:max_int) : string);
      reset_on_close flow)
  in
  (match
     Http_client.with_post_stream
       ~cache
       ~net
       ~url
       ~headers:[ "Content-Type", "application/json" ]
       ~body:large_body
       ~f:(fun ~pre_header_elapsed_s:_ reader -> Eio.Buf_read.take_all reader)
       ()
   with
   | Error (Http_client.NetworkError _) -> ()
   | Ok _ -> Alcotest.fail "the streamed request was answered"
   | Error error ->
     Alcotest.failf "expected a network error, got %s" (describe_http_error error));
  let stats = Http_client.cache_stats cache in
  Alcotest.(check int) "one connection reached the server" 1 (Atomic.get accepted);
  Alcotest.(check int)
    "closed as not delivered"
    1
    stats.closed_total.request_not_delivered;
  Alcotest.(check int) "not as a failed request" 0 stats.closed_total.request_failed
;;

(* The tests above would also pass if the cache ignored [tls_config] and a
   system trust store happened to accept the test certificate. This one runs the
   same server under both: a cache without [tls_config] cannot trust the
   self-signed certificate, and one with it gets its answer. *)
let test_tls_config_decides_which_certificate_is_trusted () =
  let server_config = https_server_config () in
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let net = env#net in
    let requests = Atomic.make 0 in
    let url, _ =
      start_tls_server ~sw ~net ~server_config (fun tls _flow ->
        read_request (Eio.Buf_read.of_flow tls ~max_size:max_int);
        Atomic.incr requests;
        Eio.Flow.copy_string ok_response tls)
    in
    let cache_with ?tls_config () =
      Http_client.create_cache ~sw ~mono_clock:env#mono_clock ?tls_config ()
    in
    (match post ~cache:(cache_with ()) ~net ~url "{}" with
     | Ok _ -> Alcotest.fail "the system trust store accepted a self-signed certificate"
     | Error (Http_client.Before_dispatch_error (Http_client.NetworkError _)) -> ()
     | Error error ->
       Alcotest.failf
         "expected the handshake to fail before dispatch, got %s"
         (describe_post_error error));
    Alcotest.(check int) "no request got past the handshake" 0 (Atomic.get requests);
    (match post ~cache:(cache_with ~tls_config:(tls_client_config ()) ()) ~net ~url "{}" with
     | Ok { status = 200; _ } -> ()
     | Ok _ -> Alcotest.fail "the answer was not 200"
     | Error error ->
       Alcotest.failf "the configured cache failed: %s" (describe_post_error error));
    Alcotest.(check int) "the configured cache's request arrived" 1 (Atomic.get requests);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* [Http_client.make_connection] gives cohttp this flow's writes unchanged, so
   the errno that [Request_wire] looks for is the one tls-eio raises. If a
   tls-eio update wraps it, the count reads zero for every https provider. *)
let test_tls_passes_a_failed_writes_errno_through () =
  ensure_rng_default ();
  let server_config = tls_server_config (make_self_signed ()) in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = env#net in
  let socket, port = listen_on_a_free_port ~sw ~net in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> ()) (fun flow _addr ->
      try
        let tls = Tls_eio.server_of_flow server_config flow in
        ignore (Eio.Buf_read.line (Eio.Buf_read.of_flow tls ~max_size:max_int) : string);
        reset_on_close flow
      with
      | End_of_file | Eio.Io _ | Unix.Unix_error _ -> ());
    `Stop_daemon);
  let connection = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  let tls =
    Tls_eio.client_of_flow (tls_client_config ()) ~ip:(Ipaddr.of_string_exn "127.0.0.1") connection
  in
  match
    Eio.Flow.copy_string
      (Printf.sprintf "POST /v1 HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s"
         (String.length large_body) large_body)
      tls
  with
  | () -> Alcotest.fail "a write into a reset connection did not fail"
  | exception
      Eio.Io
        ( Eio.Net.E
            (Eio.Net.Connection_reset (Eio_unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _)))
        , _ ) -> ()
  | exception exn -> Alcotest.failf "the write failed as %s" (Printexc.to_string exn)
;;

let () =
  Alcotest.run
    "HTTP Client request not delivered"
    [ ( "close reason"
      , [ Alcotest.test_case
            "reset after the request was read is a failed request"
            `Quick
            test_reset_after_the_request_was_read
        ; Alcotest.test_case
            "reset during a large request is not delivered"
            `Quick
            test_reset_during_a_large_request
        ; Alcotest.test_case
            "a reused connection cut off during a large write is not delivered"
            `Quick
            test_a_reused_connection_cut_off_during_a_large_write
        ; Alcotest.test_case
            "a streamed request cut off while written is not delivered"
            `Quick
            test_a_streamed_request_cut_off_while_written
        ; Alcotest.test_case
            "only a named peer close is not delivered"
            `Quick
            test_only_a_named_peer_close_is_not_delivered
        ; Alcotest.test_case
            "tls passes a failed write's errno through"
            `Quick
            test_tls_passes_a_failed_writes_errno_through
        ] )
    ; ( "close reason over https"
      , [ Alcotest.test_case
            "reset after the request was read is a failed request"
            `Quick
            test_https_reset_after_the_request_was_read
        ; Alcotest.test_case
            "reset during a large request is not delivered"
            `Quick
            test_https_reset_during_a_large_request
        ; Alcotest.test_case
            "a reused connection cut off during a large write is not delivered"
            `Quick
            test_https_reused_connection_cut_off_during_a_large_write
        ; Alcotest.test_case
            "a streamed request cut off while written is not delivered"
            `Quick
            test_https_streamed_request_cut_off_while_written
        ; Alcotest.test_case
            "tls_config decides which certificate is trusted"
            `Quick
            test_tls_config_decides_which_certificate_is_trusted
        ] )
    ]
;;
