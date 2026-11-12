(** A request cut off while its bytes were still going out closes its
    connection as [Request_not_delivered]; every other failure stays
    [Request_failed] (RFC-0492 §6 tests 2 and 4, and 1(나) as a count). The
    small-request case of test 1(가) is in test_http_client_cache.ml. *)

open Llm_provider

let fresh_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname s with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "not inet"
  in
  Unix.close s;
  port
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
  let port = fresh_port () in
  let accepted = Atomic.make 0 in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> ()) (fun flow _addr ->
        Atomic.incr accepted;
        try handler flow with
        | End_of_file | Eio.Io _ | Unix.Unix_error _ -> ())
    done);
  Printf.sprintf "http://127.0.0.1:%d/v1" port, accepted
;;

let with_cache f =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    f ~sw ~net:env#net ~cache:(Http_client.create_cache ~sw ~mono_clock:env#mono_clock ());
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
        ] )
    ]
;;
