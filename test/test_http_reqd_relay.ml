(* A request handled on another domain than its connection (RFC
   http-transport-runs-on-its-own-domain §3.3).

   Each case runs a real httpun connection over a socket pair on a second
   domain. Its handler runs on the domain that owns the root switch and
   reaches the request only through [Http_reqd.relay]. The client is a bare
   socket, so what is checked is the bytes a peer would read.

   A handler runs in a fiber of the owner's queue, which drops what it
   raises. So a handler records what it saw and the case checks the record
   after the exchange. *)

let response ?(headers = []) status =
  Httpun.Response.create ~headers:(Httpun.Headers.of_list headers) status
;;

let text_response body =
  response ~headers:[ "content-length", string_of_int (String.length body) ] `OK
;;

let error_handler _client_addr ?request:_ _error respond =
  let body = respond (Httpun.Headers.of_list [ "connection", "close" ]) in
  Httpun.Body.Writer.write_string body "reported";
  Httpun.Body.Writer.close body
;;

type 'a exchange =
  { result : 'a
  ; connection_domain : Domain.id
  ; owner_domain : Domain.id
  }

(* [handler] gets the relayed request on the owner domain. [client flow]
   runs on the connection's domain and its result comes back. *)
let exchange ~handler client =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 60.0
  @@ fun () ->
  Eio.Switch.run
  @@ fun owner_sw ->
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw:owner_sw
  @@ fun () ->
  let owner_domain = Domain.self () in
  let result, connection_domain =
    Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
      let post =
        match Eio_context.owner_post () with
        | Some post -> post
        | None -> Alcotest.fail "the connection's domain has no owner to post to"
      in
      Eio.Switch.run
      @@ fun sw ->
      let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          Http_reqd.with_connection_switch conn_sw (fun () ->
            Httpun_eio.Server.create_connection_handler
              ~sw:conn_sw
              ~request_handler:(fun _client_addr gluten_reqd ->
                let reqd = Http_reqd.of_gluten gluten_reqd in
                match Http_reqd.relay_scope reqd with
                | Some scope -> Http_reqd.relay reqd ~sw:scope ~post handler
                | None -> Alcotest.fail "an HTTP/1.1 request has no scope to relay under")
              ~error_handler
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
              server_flow));
        `Stop_daemon);
      client client_flow, Domain.self ())
  in
  { result; connection_domain; owner_domain }
;;

let send flow text = Eio.Flow.copy_string text flow

(* One response with a content-length, read off a connection that stays
   open: its status line and its body. *)
let read_sized_response reader =
  let status = Eio.Buf_read.line reader in
  let rec content_length found =
    match Eio.Buf_read.line reader with
    | "" -> found
    | line ->
      (match String.index_opt line ':' with
       | Some colon
         when String.lowercase_ascii (String.sub line 0 colon) = "content-length" ->
         let value = String.sub line (colon + 1) (String.length line - colon - 1) in
         content_length (int_of_string_opt (String.trim value))
       | Some _ | None -> content_length found)
  in
  match content_length None with
  | Some length -> status, Eio.Buf_read.take length reader
  | None -> Alcotest.failf "no content-length after %S" status
;;

let read_to_end flow = Eio.Buf_read.parse_exn Eio.Buf_read.take_all flow ~max_size:(1 lsl 20)

let contains haystack needle =
  let n = String.length needle in
  let rec at i = i + n <= String.length haystack && (String.sub haystack i n = needle || at (i + 1)) in
  at 0
;;

let check_ran_on_owner name (exchange : _ exchange) domains =
  Alcotest.(check bool)
    (name ^ ": the connection ran on another domain than the owner")
    true
    (exchange.connection_domain <> exchange.owner_domain);
  Alcotest.(check bool) (name ^ ": something ran") true (domains <> []);
  List.iter
    (fun domain ->
       Alcotest.(check bool) (name ^ ": ran on the owner domain") true (domain = exchange.owner_domain))
    domains
;;

let record cell value = Atomic.set cell (value :: Atomic.get cell)

(* Two requests on one connection: the second is answered only if the first
   one's relay let go of the connection. *)
let test_respond_with_string () =
  let ran_on = Atomic.make [] in
  let states = Atomic.make [] in
  let handler reqd =
    record ran_on (Domain.self ());
    let target = (Http_reqd.request reqd).Httpun.Request.target in
    Http_reqd.respond_with_string reqd (text_response target) target;
    record states (Http_reqd.response_state reqd)
  in
  let exchange =
    exchange ~handler (fun flow ->
      let reader = Eio.Buf_read.of_flow flow ~max_size:(1 lsl 20) in
      send flow "GET /one HTTP/1.1\r\nhost: t\r\n\r\n";
      let first = read_sized_response reader in
      send flow "GET /two HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n";
      let second = read_sized_response reader in
      first, second)
  in
  let (first_status, first_body), (second_status, second_body) = exchange.result in
  Alcotest.(check string) "first status" "HTTP/1.1 200 OK" first_status;
  Alcotest.(check string) "first body" "/one" first_body;
  Alcotest.(check string) "second status" "HTTP/1.1 200 OK" second_status;
  Alcotest.(check string) "second body" "/two" second_body;
  check_ran_on_owner "handler" exchange (Atomic.get ran_on);
  Alcotest.(check int) "both handlers ran" 2 (List.length (Atomic.get ran_on));
  Alcotest.(check bool)
    "each response is whole once the handler answered"
    true
    (Atomic.get states = [ Http_reqd.Answered; Http_reqd.Answered ])
;;

let test_streaming_and_flush () =
  let flushed_on = Atomic.make [] in
  let outcomes = Atomic.make [] in
  let states = Atomic.make [] in
  let handler reqd =
    let body =
      Http_reqd.respond_with_streaming
        ~flush_headers_immediately:true
        reqd
        (response ~headers:[ "transfer-encoding", "chunked"; "connection", "close" ] `OK)
    in
    record states (Http_reqd.response_state reqd);
    Http_reqd.Body_writer.write_string body "first";
    let flushed, resolve = Eio.Promise.create () in
    Http_reqd.Body_writer.flush body (fun outcome ->
      record flushed_on (Domain.self ());
      Eio.Promise.resolve resolve outcome);
    record outcomes (Eio.Promise.await flushed);
    Http_reqd.Body_writer.write_string body "second";
    Http_reqd.Body_writer.close body;
    record states (Http_reqd.response_state reqd)
  in
  let exchange =
    exchange ~handler (fun flow ->
      send flow "GET /stream HTTP/1.1\r\nhost: t\r\n\r\n";
      read_to_end flow)
  in
  Alcotest.(check bool)
    "the chunks arrive in order and the body ends"
    true
    (contains exchange.result "5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n");
  check_ran_on_owner "flush callback" exchange (Atomic.get flushed_on);
  Alcotest.(check bool) "the flush was written" true (Atomic.get outcomes = [ `Written ]);
  Alcotest.(check bool)
    "open while streaming, whole after the close"
    true
    (Atomic.get states = [ Http_reqd.Answered; Http_reqd.Streaming_open ])
;;

let test_read_body () =
  let read_on = Atomic.make [] in
  let handler reqd =
    Http_reqd.read_body
      reqd
      ~max_bytes:8
      ~on_body:(fun body ->
        record read_on (Domain.self ());
        let answer = "got " ^ body in
        Http_reqd.respond_with_string reqd (text_response answer) answer)
      ~on_error:(fun error ->
        record read_on (Domain.self ());
        let answer =
          match error with
          | Http_reqd.Too_large limit -> Printf.sprintf "over %d" limit
          | Http_reqd.Internal _ -> "internal"
        in
        Http_reqd.respond_with_string reqd (text_response answer) answer)
  in
  let post body =
    Printf.sprintf
      "POST /body HTTP/1.1\r\nhost: t\r\ncontent-length: %d\r\nconnection: close\r\n\r\n%s"
      (String.length body)
      body
  in
  let within =
    exchange ~handler (fun flow ->
      send flow (post "hello");
      read_sized_response (Eio.Buf_read.of_flow flow ~max_size:(1 lsl 20)))
  in
  Alcotest.(check string) "a body within the limit is delivered" "got hello" (snd within.result);
  check_ran_on_owner "body callback" within (Atomic.get read_on);
  Atomic.set read_on [];
  let over =
    exchange ~handler (fun flow ->
      send flow (post "far too long");
      read_sized_response (Eio.Buf_read.of_flow flow ~max_size:(1 lsl 20)))
  in
  Alcotest.(check string) "a body over the limit is refused" "over 8" (snd over.result);
  check_ran_on_owner "error callback" over (Atomic.get read_on)
;;

(* The client reads the first chunk and leaves. The handler keeps writing
   until a flush tells it the body is closed, then finds the request over. *)
let test_client_leaves_mid_stream () =
  let finished, finish = Eio.Promise.create () in
  let handler reqd =
    let body =
      Http_reqd.respond_with_streaming
        ~flush_headers_immediately:true
        reqd
        (response ~headers:[ "transfer-encoding", "chunked" ] `OK)
    in
    let rec write_until_closed written =
      Http_reqd.Body_writer.write_string body "tick";
      let flushed, resolve = Eio.Promise.create () in
      Http_reqd.Body_writer.flush body (Eio.Promise.resolve resolve);
      match Eio.Promise.await flushed with
      | `Written -> write_until_closed (written + 1)
      | `Closed -> written
    in
    let written = write_until_closed 0 in
    let closed = Http_reqd.Body_writer.is_closed body in
    let late = Http_reqd.try_respond_with_string reqd (text_response "late") "late" in
    Eio.Promise.resolve finish (written, closed, late)
  in
  let exchange =
    exchange ~handler (fun flow ->
      send flow "GET /stream HTTP/1.1\r\nhost: t\r\n\r\n";
      let reader = Eio.Buf_read.of_flow flow ~max_size:(1 lsl 20) in
      let rec first_chunk () =
        match Eio.Buf_read.line reader with
        | "tick" -> ()
        | _ -> first_chunk ()
      in
      first_chunk ();
      Eio.Flow.close flow;
      Eio.Promise.await finished)
  in
  let written, closed, late = exchange.result in
  Alcotest.(check bool) "a flush was written before the client left" true (written >= 1);
  Alcotest.(check bool) "the writer is closed once a flush said so" true closed;
  Alcotest.(check bool)
    "a response after the end is rejected"
    true
    (late = Http_reqd.Rejected_by_writer)
;;

let test_report_exn () =
  let handler reqd = Http_reqd.report_exn reqd (Failure "the handler gave up") in
  let exchange =
    exchange ~handler (fun flow ->
      send flow "GET /fails HTTP/1.1\r\nhost: t\r\n\r\n";
      read_to_end flow)
  in
  Alcotest.(check bool)
    "the transport's error response reaches the client"
    true
    (contains exchange.result "HTTP/1.1 500" && contains exchange.result "reported")
;;

let () =
  Alcotest.run
    "http_reqd_relay"
    [ ( "a handler on the owner domain"
      , [ Alcotest.test_case "answers with a string, twice on one connection" `Quick
            test_respond_with_string
        ; Alcotest.test_case "streams and learns of each flush" `Quick test_streaming_and_flush
        ; Alcotest.test_case "reads the request body" `Quick test_read_body
        ; Alcotest.test_case "learns that the client left" `Quick test_client_leaves_mid_stream
        ; Alcotest.test_case "reports a failure" `Quick test_report_exn
        ] )
    ]
;;
