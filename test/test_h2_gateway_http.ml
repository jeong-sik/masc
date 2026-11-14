(** HTTP/2 requests run the HTTP/1.1 route table through the shared ingress.
    These tests drive the real adapter over an h2c connection against the
    production route table and against small tables, and check that a request
    gets the answer the table's registration kind gives it. *)

open Alcotest

(* Public reads answer 503 until the server state is marked ready. *)
let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_gateway ?https_port ?(on_routes = fun _ -> ()) ?(with_runtime = fun ~env:_ ~sw:_ run -> run ()) ~make_routes run =
  let base_path = Filename.temp_dir "h2-gateway-" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
    Masc.Board_dispatch.reset_for_test ();
    Masc.Board.reset_global_for_test ();
    Server_auth.For_testing.restore_server_state previous_state;
    remove_tree base_path) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
      (fun () ->
        let state = Masc.Mcp_server.For_testing.create_state ~base_path in
        ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config state) ~agent_name:None);
        Auth.save_auth_config base_path
          { Masc_domain.default_auth_config with enabled = true; require_token = true };
        let player =
          match Auth.create_token base_path ~agent_name:"guest" ~role:Masc_domain.Player with
          | Ok (token, _) -> token
          | Error error -> fail (Masc_domain.masc_error_to_string error)
        in
        (* A Player holds only CanPlayMachine (#39707): strict Public_read
           paths demand CanReadState, so positive read assertions use this
           Worker token while Player assertions lock the designed refusal. *)
        let reader =
          match Auth.create_token base_path ~agent_name:"reader" ~role:Masc_domain.Worker with
          | Ok (token, _) -> token
          | Error error -> fail (Masc_domain.masc_error_to_string error)
        in
        Server_auth.For_testing.restore_server_state (Some state);
        let trust_policy =
          match
            Server_request_authority.make_trust_policy
              ~bind_host:"localhost" ~bind_port:8935 ~https_port ~explicit_base_url:None
          with
          | Ok policy -> policy
          | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
        in
        let clock = Eio.Stdenv.clock env in
        let routes = make_routes ~sw ~clock in
        on_routes routes;
        let handler =
          Server_h2_gateway.make_request_handler ~trust_policy ~routes
        in
        let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
        let server = Eio.Fiber.fork_promise ~sw (fun () ->
          Eio.Switch.run @@ fun conn_sw ->
          Server_bootstrap_http.serve_h2_connection ~clock ~sw:conn_sw
            ~h2_request_handler:handler
            ~h2_error_handler:(Server_h2_gateway.make_error_handler ())
            (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow) in
        let closing = ref false in
        let client = H2_eio.Client.create_connection ~sw
          ~error_handler:(fun _ -> if not !closing then fail "H2 connection error") client_flow in
        Fun.protect ~finally:(fun () ->
          closing := true;
          Eio.Flow.shutdown client_flow `All) (fun () -> with_runtime ~env ~sw (fun () -> run ~player ~reader client));
        Eio.Promise.await_exn server))

let request_with_headers ?token ?(extra_headers = []) ?(scheme = "http")
    ?(authority = "localhost:8935") ~meth client path =
  let result, resolve = Eio.Promise.create () in
  let headers = [":authority", authority]
    @ (match token with None -> [] | Some token -> ["authorization", "Bearer " ^ token])
    @ extra_headers in
  let req = H2.Request.create ~scheme meth path ~headers:(H2.Headers.of_list headers) in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true req
    ~error_handler:(fun _ -> if not (Eio.Promise.is_resolved result) then
      Eio.Promise.resolve resolve (Error "stream failed"))
    ~response_handler:(fun response reader ->
      let bytes = Buffer.create 256 in
      (* h2 ends the body of a reset stream before it calls [error_handler];
         only [Complete] is a whole response. *)
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () ->
          if not (Eio.Promise.is_resolved result) then
            Eio.Promise.resolve resolve
              (match H2.Body.Reader.completion reader with
               | H2.Body.Reader.Complete ->
                 Ok (H2.Status.to_code response.status, H2.Headers.to_list response.headers,
                     Buffer.contents bytes)
               | H2.Body.Reader.Aborted -> Error "stream reset"
               | H2.Body.Reader.Pending -> Error "response body ended while still pending"))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len); read ()) in
      read ()) in
  H2.Body.Writer.close writer;
  match Eio.Promise.await result with Ok response -> response | Error detail -> fail detail

let request ?token ~meth client path =
  let status, _, body = request_with_headers ?token ~meth client path in
  status, body

let status ?token ~meth client path = fst (request ?token ~meth client path)

let production ~sw ~clock = Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock

let strict value run =
  Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" value run

(* A browser fetches discovery over its HTTPS/h2 connection before opening
   the separate HTTP/1.1 WebSocket. This does not request RFC 8441 CONNECT. *)
let test_https_websocket_discovery () =
  Masc_test_deps.with_process_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    let previous_ready = Masc.Transport_metrics.ws_same_origin_ready () in
    Fun.protect
      ~finally:(fun () -> Masc.Transport_metrics.set_ws_same_origin_runtime_ready previous_ready)
      (fun () ->
        Masc.Transport_metrics.set_ws_same_origin_runtime_ready true;
        with_gateway ~https_port:8938 ~make_routes:production
          (fun ~player:_ ~reader:_ client ->
            let code, _, body =
              request_with_headers ~scheme:"https" ~authority:"localhost:8938"
                ~meth:`GET client "/ws"
            in
            check int "ordinary h2 discovery succeeds" 200 code;
            let json = Yojson.Safe.from_string body in
            check string "discovery advertises the TLS WebSocket URL"
              "wss://127.0.0.1:8938/ws"
              Yojson.Safe.Util.(json |> member "ws_url" |> to_string);
            check bool "the same-origin upgrade is ready" true
              Yojson.Safe.Util.(json |> member "same_origin_upgrade_enabled" |> to_bool);
            check int "the upgrade-only LSP route remains unavailable on h2" 426
              (status ~meth:`GET client "/api/v1/ide/lsp"))))

(* A route registered as [Public_read] asks for a credential under strict auth
   on HTTP/2 as on HTTP/1.1. *)
let test_public_read_follows_the_router () =
  with_gateway ~make_routes:production (fun ~player:_ ~reader:_ client ->
    strict None (fun () ->
      check int "agent card, default config" 200
        (status ~meth:`GET client "/.well-known/agent.json"));
    strict (Some "1") (fun () ->
      check int "agent card, strict config" 401
        (status ~meth:`GET client "/.well-known/agent.json");
      check int "agent-card.json, strict config" 401
        (status ~meth:`GET client "/.well-known/agent-card.json");
      check int "a route that is Always_public stays open" 200
        (status ~meth:`GET client "/health")))

let test_token_permission_follows_the_router () =
  with_gateway ~make_routes:production (fun ~player ~reader:_ client ->
    check int "no credential" 401 (status ~meth:`GET client "/api/v1/lanes");
    check int "a Player token lacks the CanAdmin the router records" 403
      (status ~token:player ~meth:`GET client "/api/v1/lanes"))

(* The keepers prefix is [Subpath_dispatch]: the table holds no kind for its
   sub-routes, so the handler checks the token itself. *)
let test_subpath_routes_check_the_token_themselves () =
  with_gateway ~make_routes:production (fun ~player:_ ~reader:_ client ->
    check int "github identity needs a credential" 401
      (status ~meth:`GET client "/api/v1/keepers/someone/github-identity"))

(* [namespace-truth] was an alias only HTTP/2 served. *)
let test_a_path_the_router_lacks_is_not_found () =
  with_gateway ~make_routes:production (fun ~player:_ ~reader:_ client ->
    check int "namespace-truth" 404
      (status ~meth:`GET client "/api/v1/dashboard/namespace-truth"));
  with_gateway
    ~make_routes:(fun ~sw:_ ~clock:_ -> Masc.Http_server_eio.Router.create ())
    (fun ~player:_ ~reader:_ client ->
      check int "an empty table" 404 (status ~meth:`GET client "/health"));
  with_gateway
    ~make_routes:(fun ~sw:_ ~clock:_ ->
      Masc.Http_server_eio.Router.create ()
      |> Server_route.post Server_route.Always_public "/health" (fun _request _reqd -> ()))
    (fun ~player:_ ~reader:_ client ->
      check int "a method the table lacks" 405 (status ~meth:`GET client "/health"))

(* A route that fails before its response gets a 500. One that fails after
   its response started cannot: its headers already went out. HTTP/2 resets
   the stream. HTTP/1.1 stops the body and closes the connection, which a
   chunked body shows as a missing last chunk. One that fails after a whole
   response, or after closing its own body, keeps that response. Each
   failure is logged once. *)
let early_failure = "fixture route failed before its response"
let half_failure = "fixture route failed mid-stream"
let answered_failure = "fixture route failed after its response"
let closed_failure = "fixture route failed after closing its body"
let sse_failure = "fixture SSE route failed before its stream ended"

(* An unreadable auth configuration keeps its own answer, a 503. *)
let auth_config_failure =
  Auth.Auth_config_error { file = "fixture/auth/config.json"; reason = "fixture" }

let chunked_ok =
  Httpun.Response.create ~headers:(Httpun.Headers.of_list [ "transfer-encoding", "chunked" ]) `OK

let failing_routes ~sw:_ ~clock =
  Masc.Http_server_eio.Router.create ()
  |> Server_route.get Server_route.Always_public "/early" (fun _request _reqd ->
    failwith early_failure)
  |> Server_route.get Server_route.Always_public "/half" (fun _request reqd ->
    let writer =
      Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true reqd
        (Httpun.Response.create
           ~headers:(Httpun.Headers.of_list [ "transfer-encoding", "chunked" ]) `OK)
    in
    Masc.Http_reqd.Body_writer.write_string writer "partial";
    failwith half_failure)
  |> Server_route.get Server_route.Always_public "/answered" (fun _request reqd ->
    Masc.Http_server_eio.Response.text "done" reqd;
    failwith answered_failure)
  |> Server_route.get Server_route.Always_public "/closed" (fun _request reqd ->
    let writer =
      Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true reqd
        (Httpun.Response.create
           ~headers:(Httpun.Headers.of_list [ "transfer-encoding", "chunked" ]) `OK)
    in
    Masc.Http_reqd.Body_writer.write_string writer "done";
    Masc.Http_reqd.Body_writer.close writer;
    failwith closed_failure)
  |> Server_route.get Server_route.Always_public "/auth-config" (fun _request _reqd ->
    raise auth_config_failure)
  |> Server_route.get Server_route.Always_public "/auth-config-late" (fun _request reqd ->
    let writer =
      Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true reqd chunked_ok in
    Masc.Http_reqd.Body_writer.write_string writer "partial";
    raise auth_config_failure)
  (* A route that fails leaves its SSE response open, so the failure cuts it
     instead of ending it as complete. *)
  |> Server_route.get Server_route.Always_public "/sse-failed" (fun _request reqd ->
    let response =
      Server_sse_response.respond ~clock
        ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
        ~flush_headers_immediately:true reqd chunked_ok
    in
    Server_sse_response.close_after response (fun () -> failwith sse_failure))

let h2_outcome client path =
  let result, resolve = Eio.Promise.create () in
  let settle outcome =
    if not (Eio.Promise.is_resolved result) then Eio.Promise.resolve resolve outcome in
  let request = H2.Request.create ~scheme:"http" `GET path
    ~headers:(H2.Headers.of_list [ ":authority", "localhost:8935" ]) in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true request
    ~error_handler:(fun _ -> settle `Reset)
    ~response_handler:(fun response reader ->
      let bytes = Buffer.create 64 in
      (* h2 ends the body of a reset stream before it calls [error_handler]. *)
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () ->
          match H2.Body.Reader.completion reader with
          | H2.Body.Reader.Complete ->
            settle (`Ended (H2.Status.to_code response.status, Buffer.contents bytes))
          | H2.Body.Reader.Aborted -> settle `Reset
          | H2.Body.Reader.Pending -> fail "response body ended while still pending")
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len); read ()) in
      read ()) in
  H2.Body.Writer.close writer;
  Eio.Promise.await result

(* Feeds [request] to an HTTP/1.1 connection in memory and collects what it
   writes; {!h1_exchange} says what the steps stand for. *)
let h1_feed ~eof conn request =
  let output = Buffer.create 256 in
  let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  let feed =
    if eof then Httpun.Server_connection.read_eof else Httpun.Server_connection.read
  in
  ignore (feed conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
  ignore (Httpun.Server_connection.next_read_operation conn);
  let rec drain () =
    match Httpun.Server_connection.next_write_operation conn with
    | `Write iovecs ->
      let count = List.fold_left (fun count (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        count + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result conn (`Ok count);
      drain ()
    | `Yield -> `Open (Buffer.contents output)
    | `Close _ -> `Closed (Buffer.contents output)
  in
  drain ()

(* One HTTP/1.1 exchange in memory, through the ingress the HTTP/1.1
   listener runs. The client sends [request], then leaves ([eof]) or goes
   quiet. The read operation that follows is the one the listener's read
   loop asks for next: httpun handles a request it could not read to the
   end there. Every step is synchronous, so a writer that yields is a
   response nobody will finish. *)
let h1_exchange ?(eof = true) ~routes request =
  let trust_policy =
    match
      Server_request_authority.make_trust_policy
        ~bind_host:"localhost" ~bind_port:8935 ~https_port:None ~explicit_base_url:None
    with
    | Ok policy -> policy
    | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
  in
  h1_feed ~eof
    (Httpun.Server_connection.create (fun reqd ->
       Server_http_ingress.serve ~routes
         ~client_addr:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
         (Server_request_authority.classify_http1_request ~trust_policy (Httpun.Reqd.request reqd))
         (Masc.Http_reqd.of_httpun reqd)))
    request

let h1_outcome ~routes path =
  h1_exchange ~routes
    (Printf.sprintf "GET %s HTTP/1.1\r\nHost: localhost:8935\r\n\r\n" path)

let test_route_failure_follows_the_response_state () =
  let captured = ref None in
  let lines = ref [] in
  let logged text =
    List.length (List.filter (fun line -> String_util.contains_substring line text) !lines) in
  Console_sink.For_testing.reset ();
  Console_sink.For_testing.set_writer (Some (fun line -> lines := line :: !lines));
  Fun.protect ~finally:Console_sink.For_testing.reset (fun () ->
    with_gateway ~on_routes:(fun routes -> captured := Some routes) ~make_routes:failing_routes
      (fun ~player:_ ~reader:_ client ->
        let routes = match !captured with Some routes -> routes | None -> fail "missing routes" in
        (* The 500 says a fixed sentence: the exception's text can name a
           file of the server, so only the log has it (#50613). *)
        check bool "HTTP/2: a failure before the response is a 500 with the fixed body" true
          (match h2_outcome client "/early" with
           | `Ended (500, "Internal server error") -> true
           | `Ended _ | `Reset -> false);
        (match h1_outcome ~routes "/early" with
         | `Open output -> failf "HTTP/1.1: the 500 did not end: %S" output
         | `Closed output ->
           check bool "HTTP/1.1: a failure before the response is a 500" true
             (String_util.contains_substring output " 500 ");
           check bool "HTTP/1.1: the 500 has the fixed body" true
             (String_util.contains_substring output "\r\n\r\nInternal server error");
           check bool "HTTP/1.1: the 500 leaves the exception's text out" false
             (String_util.contains_substring output early_failure));
        check int "a failure before the response is logged on both" 2 (logged early_failure);
        check bool "HTTP/2: an auth configuration failure is a 503" true
          (match h2_outcome client "/auth-config" with
           | `Ended (503, _) -> true
           | `Ended _ | `Reset -> false);
        (match h1_outcome ~routes "/auth-config" with
         | `Open output -> failf "HTTP/1.1: the 503 did not end: %S" output
         | `Closed output ->
           check bool "HTTP/1.1: an auth configuration failure is a 503" true
             (String_util.contains_substring output " 503 "));
        check bool "HTTP/2: the half-sent stream is reset" true
          (match h2_outcome client "/half" with `Reset -> true | `Ended _ -> false);
        check int "HTTP/2: the failure is logged once" 1 (logged half_failure);
        (match h1_outcome ~routes "/half" with
         | `Open output -> failf "HTTP/1.1: the half-sent body stayed open: %S" output
         | `Closed output ->
           check bool "HTTP/1.1: the bytes before the failure went out" true
             (String_util.contains_substring output "7\r\npartial\r\n");
           check bool "HTTP/1.1: the body has no last chunk" false
             (String_util.contains_substring output "\r\n0\r\n\r\n"));
        check int "HTTP/1.1: the failure is logged once" 2 (logged half_failure);
        check bool "HTTP/2: a whole response stays whole" true
          (match h2_outcome client "/answered" with
           | `Ended (200, "done") -> true
           | `Ended _ | `Reset -> false);
        (match h1_outcome ~routes "/answered" with
         | `Open output -> failf "HTTP/1.1: the whole response did not end: %S" output
         | `Closed output ->
           check bool "HTTP/1.1: a whole response stays whole" true
             (String_util.contains_substring output " 200 "
              && String_util.contains_substring output "\r\n\r\ndone"));
        check int "a failure after a whole response is logged on both" 2
          (logged answered_failure);
        check bool "HTTP/2: a body the route closed stays whole" true
          (match h2_outcome client "/closed" with
           | `Ended (200, "done") -> true
           | `Ended _ | `Reset -> false);
        (match h1_outcome ~routes "/closed" with
         | `Open output -> failf "HTTP/1.1: the closed body did not end: %S" output
         | `Closed output ->
           check bool "HTTP/1.1: a body the route closed keeps its last chunk" true
             (String_util.contains_substring output "4\r\ndone\r\n"
              && String_util.contains_substring output "\r\n0\r\n\r\n"));
        check int "a failure after the route closed its body is logged on both" 2
          (logged closed_failure);
        (* HTTP/1.1 first: a response nobody ends stays open there at once,
           while the HTTP/2 client would wait for the test's timeout. *)
        (match h1_outcome ~routes "/auth-config-late" with
         | `Open output -> failf "HTTP/1.1: the late auth failure left the body open: %S" output
         | `Closed output ->
           check bool "HTTP/1.1: a late auth failure cuts the body like any failure" true
             (String_util.contains_substring output "7\r\npartial\r\n"
              && not (String_util.contains_substring output "\r\n0\r\n\r\n")));
        check bool "HTTP/2: a late auth failure resets the stream" true
          (match h2_outcome client "/auth-config-late" with `Reset -> true | `Ended _ -> false);
        (match h1_outcome ~routes "/sse-failed" with
         | `Open output -> failf "HTTP/1.1: the failed SSE response stayed open: %S" output
         | `Closed output ->
           check bool "HTTP/1.1: a failed SSE route's body has no last chunk" false
             (String_util.contains_substring output "\r\n0\r\n\r\n"));
        check bool "HTTP/2: a failed SSE route's stream is reset" true
          (match h2_outcome client "/sse-failed" with `Reset -> true | `Ended _ -> false);
        check int "a failed SSE route is logged on both" 2 (logged sse_failure)))

(* The HTTP/1.1 listener's error handler answers a request that failed
   before its response. httpun calls it with the exception, from its own
   runtime when a request handler raises ([Httpun.Reqd.report_exn]) and
   through [Http_reqd.report_exn]. Either way the body is the fixed sentence
   and the exception's text is logged once (#50613). *)
let test_h1_error_handler_answers_a_fixed_body () =
  let exception_text = "/srv/masc/fixture-path-in-an-exception" in
  let failed_request ~report =
    let lines = ref [] in
    Console_sink.For_testing.reset ();
    Console_sink.For_testing.set_writer (Some (fun line -> lines := line :: !lines));
    let outcome =
      Fun.protect ~finally:Console_sink.For_testing.reset (fun () ->
        h1_feed ~eof:true
          (Httpun.Server_connection.create
             ~error_handler:
               (Server_bootstrap_http.h1_error_handler
                  (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)))
             (fun reqd -> report reqd (Failure exception_text)))
          "GET /boom HTTP/1.1\r\nHost: localhost:8935\r\n\r\n")
    in
    let logged =
      List.length
        (List.filter (fun line -> String_util.contains_substring line exception_text) !lines)
    in
    match outcome with
    | `Open output -> failf "HTTP/1.1: the error response did not end: %S" output
    | `Closed output -> output, logged
  in
  List.iter
    (fun (label, report) ->
      let output, logged = failed_request ~report in
      check bool (label ^ ": answered as an internal error") true
        (String_util.contains_substring output " 500 ");
      check bool (label ^ ": the body is the fixed sentence") true
        (String_util.contains_substring output "\r\n\r\nInternal server error");
      check bool (label ^ ": the body leaves the exception's text out") false
        (String_util.contains_substring output exception_text);
      check int (label ^ ": the exception's text is logged once") 1 logged)
    [ "reported by httpun", Httpun.Reqd.report_exn
    ; ( "reported through Http_reqd"
      , fun reqd exn -> Masc.Http_reqd.report_exn (Masc.Http_reqd.of_httpun reqd) exn )
    ]

(* A request body that ends short reaches no route; the request has its
   answer or its end by then. A client that leaves mid-body cuts its body,
   and httpun answers that request itself. A route that fails after its
   response started cuts a chunked body still coming in. *)
let body_failure = "fixture route failed while its body was still coming"
let body_callback_failure = "fixture route failed in its body callback"

let body_routes ~delivered ~sw:_ ~clock:_ =
  Masc.Http_server_eio.Router.create ()
  |> Server_route.post Server_route.Always_public "/upload" (fun _request reqd ->
    Masc.Http_server_eio.Request.read_body_async reqd (fun body ->
      delivered := body :: !delivered;
      Masc.Http_server_eio.Response.text "stored" reqd))
  |> Server_route.post Server_route.Always_public "/read-then-raise" (fun _request reqd ->
    Masc.Http_server_eio.Request.read_body_async reqd (fun _body ->
      failwith body_callback_failure))
  |> Server_route.post Server_route.Always_public "/read-then-fail" (fun _request reqd ->
    let writer =
      Masc.Http_reqd.respond_with_streaming ~flush_headers_immediately:true reqd
        (Httpun.Response.create
           ~headers:(Httpun.Headers.of_list [ "transfer-encoding", "chunked" ]) `OK)
    in
    Masc.Http_reqd.Body_writer.write_string writer "partial";
    Masc.Http_server_eio.Request.read_body_async reqd (fun body ->
      delivered := body :: !delivered);
    failwith body_failure)

let post path ~fields body =
  Printf.sprintf "POST %s HTTP/1.1\r\nHost: localhost:8935\r\n%s\r\n%s" path fields body

let test_a_cut_request_body_reaches_no_route () =
  let delivered = ref [] in
  let captured = ref None in
  with_gateway ~on_routes:(fun routes -> captured := Some routes)
    ~make_routes:(body_routes ~delivered)
    (fun ~player:_ ~reader:_ _client ->
      let routes = match !captured with Some routes -> routes | None -> fail "missing routes" in
      (match h1_exchange ~routes (post "/upload" ~fields:"Content-Length: 5\r\n" "hello") with
       | `Open output -> failf "HTTP/1.1: the answer to a whole body did not end: %S" output
       | `Closed output ->
         check bool "a whole body gets the route's answer" true
           (String_util.contains_substring output "stored"));
      check (list string) "the route got the whole body" [ "hello" ] !delivered;
      delivered := [];
      (match
         h1_exchange ~routes
           (post "/upload" ~fields:"Transfer-Encoding: chunked\r\n" "5\r\nhello\r\n0\r\n\r\n")
       with
       | `Open output -> failf "HTTP/1.1: the answer to a whole chunked body did not end: %S" output
       | `Closed output ->
         check bool "a whole chunked body gets the route's answer" true
           (String_util.contains_substring output "stored"));
      check (list string) "the route got the whole chunked body" [ "hello" ] !delivered;
      delivered := [];
      (match h1_exchange ~routes (post "/upload" ~fields:"Content-Length: 10\r\n" "hello") with
       | `Open output -> failf "HTTP/1.1: the answer to a cut body did not end: %S" output
       | `Closed output ->
         check bool "httpun answers a body the client cut" true
           (String_util.contains_substring output " 400 "));
      check (list string) "a body the client cut reaches no route" [] !delivered;
      (match
         h1_exchange ~routes (post "/upload" ~fields:"Transfer-Encoding: chunked\r\n" "5\r\nhello\r\n")
       with
       | `Open output -> failf "HTTP/1.1: the answer to a cut chunked body did not end: %S" output
       | `Closed output ->
         check bool "httpun answers a chunked body the client cut" true
           (String_util.contains_substring output " 400 "));
      check (list string) "a chunked body the client cut reaches no route" [] !delivered;
      (match
         h1_exchange ~eof:false ~routes
           (post "/read-then-fail" ~fields:"Transfer-Encoding: chunked\r\n" "5\r\nhello\r\n")
       with
       | `Open output -> failf "HTTP/1.1: the failed route's response stayed open: %S" output
       | `Closed _ -> ());
      check (list string) "a chunked body its route's failure cut reaches no route" []
        !delivered;
      (* A route that raises once its body is read gets the same 500 as one
         that raises before it: the fixed sentence, with the text in the log. *)
      let lines = ref [] in
      Console_sink.For_testing.reset ();
      Console_sink.For_testing.set_writer (Some (fun line -> lines := line :: !lines));
      let outcome =
        Fun.protect ~finally:Console_sink.For_testing.reset (fun () ->
          h1_exchange ~routes (post "/read-then-raise" ~fields:"Content-Length: 5\r\n" "hello"))
      in
      (match outcome with
       | `Open output -> failf "HTTP/1.1: the body callback's 500 did not end: %S" output
       | `Closed output ->
         check bool "a body callback that raised is a 500" true
           (String_util.contains_substring output " 500 ");
         check bool "its 500 has the fixed body" true
           (String_util.contains_substring output "\r\n\r\nInternal server error");
         check bool "its 500 leaves the exception's text out" false
           (String_util.contains_substring output body_callback_failure));
      check int "the body callback's failure is logged once" 1
        (List.length
           (List.filter
              (fun line -> String_util.contains_substring line body_callback_failure)
              !lines)))

let test_fusion_workspace_admission () =
  with_gateway ~make_routes:production (fun ~player ~reader:_ client ->
    strict None (fun () ->
      let state = match Server_auth.For_testing.snapshot_server_state () with
        | Some state -> state | None -> fail "fixture server has no workspace" in
      let config = Masc.Mcp_server.workspace_config state in
      let base = Unix.realpath config.base_path in
      let root = Unix.realpath (Masc.Workspace.masc_dir config) in
      let target path fields = Uri.with_query (Uri.of_string path) fields |> Uri.to_string in
      let expected = [ "expected_base_path", [ base ]; "expected_masc_root", [ root ] ] in
      let foreign = [ "expected_base_path", [ base ^ "/foreign" ]; "expected_masc_root", [ root ] ] in
      let receipt = Masc.Workspace.read_precondition_admission_header in
      let read path fields = request_with_headers ~token:player ~meth:`GET client (target path fields) in
      Masc.Board.reset_global_for_test ();
      Masc.Board_dispatch.reset_for_test ();
      Result.get_ok (Masc.Board_dispatch.init_jsonl ~base_path:base
        ~recipient_lookup:Masc.Recipient_lookup.none_declared ());
      let post = match Masc.Board_dispatch.create_post ~author:"fixture" ~content:"original"
          ~post_kind:Masc.Board.System_post () with
        | Ok post -> post
        | Error error -> fail (Masc.Board.Post_publication_failure.to_string error) in
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs" expected in
      check int "bound list succeeds" 200 code;
      check bool "bound list attests workspace" true (List.mem receipt headers);
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs" foreign in
      check int "foreign list is refused before projection" 409 code;
      check bool "foreign list has no admission receipt" false (List.mem receipt headers);
      let code, _, _ = read "/api/v1/dashboard/fusion-runs" [ "expected_base_path", [ base ] ] in
      check int "partial workspace precondition is refused" 400 code;
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs/unknown" expected in
      check int "bound missing detail remains a 404" 404 code;
      check bool "bound detail attests workspace" true (List.mem receipt headers);
      let code, _, _ = read "/api/v1/dashboard/fusion-runs/unknown" foreign in
      check int "foreign detail is refused before lookup" 409 code;
      let code, headers, _ = read "/api/v1/dashboard/fusion-runs" [] in
      check int "unbound legacy list remains available" 200 code;
      check bool "unbound list is not attested" false (List.mem receipt headers);
      let board = "/api/v1/board/" ^ Masc.Board.Post_id.to_string post.id ^ "?format=flat" in
      let board_target fields = Uri.with_query (Uri.of_string board) (("format", ["flat"]) :: fields) |> Uri.to_string in
      let read_board fields = request_with_headers ~meth:`GET client (board_target fields) in
      let code, headers, _ = read_board expected in
      check int "bound Board original is readable" 200 code;
      check bool "bound Board original attests workspace" true (List.mem receipt headers);
      let code, headers, _ = read_board foreign in
      check int "foreign Board original is refused before lookup" 409 code;
      check bool "foreign Board original has no receipt" false (List.mem receipt headers);
      let code, _, _ = read board expected in
      check int "optional reaction actor still rejects the Player token" 403 code;
      let code, _, _ = read board foreign in
      check int "foreign workspace is refused before reaction auth, as on HTTP/1.1" 409 code;
      strict (Some "1") (fun () ->
        let code, _, _ = read_board expected in
        check int "strict mode still requires authentication" 401 code)))

let test_physical_skill_turn_evidence () =
  with_gateway ~make_routes:production (fun ~player ~reader client ->
    let state = match Server_auth.For_testing.snapshot_server_state () with
      | Some state -> state | None -> fail "fixture server has no workspace" in
    let config = Masc.Mcp_server.workspace_config state in
    let module Ledger = Masc.Keeper_skill_activation_ledger in
    let fixture = Yojson.Safe.from_file "fixtures/skill-ledger-async-actions.json" in
    let canonical = match Ledger.of_projection_yojson fixture with
      | Ok ledger -> ledger | Error error -> fail (Ledger.decode_error_code error) in
    let origin = Ledger.session_id canonical in
    let origin_dir = Masc.Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string origin) in
    Unix.mkdir origin_dir 0o700;
    let activations = Ledger.activations canonical in
    List.iter (fun activation -> match Ledger.record ~keeper_name:"skill-keeper-fixture" ~config ~trace_id:origin activation with
      | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error)) activations;
    List.iter (fun delivery -> match Ledger.observe_async_result_delivery ~keeper_name:"skill-keeper-fixture" ~config ~trace_id:origin
        ~expected_activations:activations delivery with
      | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error))
      (Ledger.async_result_deliveries canonical);
    List.iter (fun action -> match Ledger.observe_async_action ~keeper_name:"skill-keeper-fixture" ~config ~trace_id:origin action with
      | Ok _ -> () | Error error -> fail (Ledger.store_error_to_string error)) (Ledger.async_actions canonical);
    let path = "/api/v1/dashboard/skill-activations/physical-turn" in
    let target ?(workspace = []) turn =
      Uri.with_query (Uri.of_string path) (("turn_ref", [ turn ]) :: workspace) |> Uri.to_string in
    let base = Unix.realpath config.base_path in
    let root = Unix.realpath (Masc.Workspace.masc_dir config) in
    let matching = [ "expected_base_path", [ base ]; "expected_masc_root", [ root ] ] in
    let foreign = [ "expected_base_path", [ base ^ "/foreign" ]; "expected_masc_root", [ root ] ] in
    let admission = Masc.Workspace.read_precondition_admission_header in
    let receiving = "new-physical-trace#73" in
    strict None (fun () ->
      let code, body = request ~meth:`GET client path in
      check int "missing reference is a client error, not an unimplemented route" 400 code;
      check string "same missing-reference response as HTTP/1" "turn_ref query param is required"
        Yojson.Safe.Util.(Yojson.Safe.from_string body |> member "error" |> to_string);
      List.iter (fun invalid ->
        check int ("invalid physical turn is refused by the owner: " ^ invalid) 400
          (status ~meth:`GET client (target invalid)))
        [ "not-a-turn"; "trace#0"; "trace#-1"; "   #1" ]);
    strict (Some "1") (fun () ->
      check int "strict Public_read still requires a credential" 401
        (status ~meth:`GET client (target receiving));
      check int "a Player token lacks the CanReadState a strict Public_read requires" 403
        (status ~token:player ~meth:`GET client (target receiving));
      let code, headers, body = request_with_headers ~token:reader ~meth:`GET client (target receiving) in
      check int "authenticated physical lookup is served over H2" 200 code;
      check bool "unbound lookup has no workspace admission receipt" false (List.mem admission headers);
      let json = Yojson.Safe.from_string body in
      let expected = match Server_skill_physical_turn.project_string ~config receiving with
        | Ok json -> json | Error detail -> fail detail in
      check bool "same scoped owner projection as HTTP/1" true (Yojson.Safe.equal expected json);
      let open Yojson.Safe.Util in
      check string "exact physical turn survives transport" receiving (json |> member "turn_ref" |> to_string);
      let origins = json |> member "origins" |> to_list in
      check int "finds the cross-trace original ledger" 1 (List.length origins);
      let observed = List.hd origins in
      check int "keeps both physical handoffs" 2
        (observed |> member "async_result_deliveries" |> to_list |> List.length);
      check int "keeps all physical action links" 3
        (observed |> member "async_actions" |> to_list |> List.length);
      let code, headers, body = request_with_headers ~token:reader ~meth:`GET client
        (target ~workspace:matching receiving) in
      check int "matching workspace serves physical evidence" 200 code;
      check bool "matching workspace is attested" true (List.mem admission headers);
      check bool "workspace binding preserves the scoped evidence" true
        (Yojson.Safe.equal json (Yojson.Safe.from_string body));
      let code, headers, _ = request_with_headers ~token:reader ~meth:`GET client
        (target ~workspace:foreign receiving) in
      check int "foreign workspace is refused before projection" 409 code;
      check bool "foreign workspace is not attested" false (List.mem admission headers);
      let code, headers, _ = request_with_headers ~token:reader ~meth:`GET client
        (target ~workspace:[ "expected_base_path", [ base ] ] receiving) in
      check int "partial workspace binding is refused" 400 code;
      check bool "partial workspace is not attested" false (List.mem admission headers);
      let code, headers, _ = request_with_headers ~token:reader ~meth:`GET client
        (target ~workspace:matching "trace#0") in
      check int "matched workspace still rejects an invalid physical turn" 400 code;
      check bool "matched workspace remains attested on owner rejection" true (List.mem admission headers);
      let code, body = request ~token:reader ~meth:`GET client (target "new-physical-trace#74") in
      check int "adjacent physical turn remains readable" 200 code;
      check int "adjacent turn does not borrow the original's evidence" 0
        (Yojson.Safe.from_string body |> member "origins" |> to_list |> List.length)))

let test_goal_tree_bound_read_bypasses_stale_cache () =
  let captured_routes = ref None in
  with_gateway ~on_routes:(fun routes -> captured_routes := Some routes) ~make_routes:production (fun ~player ~reader:_ client ->
    strict None (fun () ->
      let state = match Server_auth.For_testing.snapshot_server_state () with
        | Some state -> state | None -> fail "fixture server has no workspace" in
      let config = Masc.Mcp_server.workspace_config state in
      let base = Unix.realpath config.base_path in
      let root = Unix.realpath (Masc.Workspace.masc_dir config) in
      let target base_path = Uri.with_query (Uri.of_string "/api/v1/dashboard/goals")
          [ "expected_base_path", [ base_path ]; "expected_masc_root", [ root ] ] |> Uri.to_string in
      let code, headers, _ = request_with_headers ~token:player ~meth:`GET client "/api/v1/dashboard/goals" in
      check int "unbound cache can be primed" 200 code;
      check bool "unbound read does not claim a direct observation" false
        (List.mem Masc.Server_utils.goal_tree_direct_read_header headers);
      let goal = match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"after cached tree"
          ~metric:"measurement" ~target_value:"1" () with
        | Ok (goal, `created, _) -> goal
        | Ok (_, `updated _, _) -> fail "fixture unexpectedly updated a Goal"
        | Error error -> fail (Goal_store.write_error_to_string error) in
      let routes = match !captured_routes with Some routes -> routes | None -> fail "missing H1 routes" in
      let authority = match Server_request_authority.of_host_port ~host:"localhost" ~port:8935 with
        | Ok authority -> authority | Error `Malformed -> fail "invalid fixture authority" in
      let h1_read ?(accept_encoding = "") path =
        let response = Buffer.create 1024 in
        let conn = Httpun.Server_connection.create (fun reqd ->
          Server_request_authority.with_current authority (fun () ->
            Masc.Http_server_eio.Router.dispatch routes (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd))) in
        let request = Printf.sprintf
            "GET %s HTTP/1.0\r\nHost: localhost:8935\r\nAuthorization: Bearer %s\r\nIf-None-Match: *\r\n%s\r\n"
            path player accept_encoding in
        let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
        ignore (Httpun.Server_connection.read_eof conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
        let rec drain () = match Httpun.Server_connection.next_write_operation conn with
          | `Write iovecs ->
            let count = List.fold_left (fun count (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string response (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              count + iov.len) 0 iovecs in
            Httpun.Server_connection.report_write_result conn (`Ok count);
            drain ()
          | `Yield ->
            let ready, resolve = Eio.Promise.create () in
            Httpun.Server_connection.yield_writer conn (fun () -> Eio.Promise.resolve resolve ());
            Eio.Promise.await ready;
            drain ()
          | `Close _ -> Buffer.contents response in
        drain () in
      let h1 = h1_read (target base) in
      let h1_headers = String.lowercase_ascii h1 in
      check bool "H1 conditional bound read returns a full body" true
        (String_util.contains_substring h1 " 200 " && String_util.contains_substring h1 goal.id);
      check bool "H1 attests its workspace and direct generation" true
        (String_util.contains_substring h1_headers "x-masc-workspace-read: matched-v1"
         && String_util.contains_substring h1_headers "x-masc-goal-tree-read: direct-v1"
         && String_util.contains_substring h1_headers "cache-control: private, no-store");
      let h1_gzip = h1_read ~accept_encoding:"Accept-Encoding: gzip\r\n" (target base) |> String.lowercase_ascii in
      check bool "H1 negotiates compression without a 304" true
        (String_util.contains_substring h1_gzip " 200 "
         && String_util.contains_substring h1_gzip "content-encoding: gzip"
         && String_util.contains_substring h1_gzip "cache-control: private, no-store");
      let h1_wildcard = h1_read ~accept_encoding:"Accept-Encoding: zstd;q=0, *;q=1\r\n" (target base) |> String.lowercase_ascii in
      check bool "H1 wildcard does not re-enable forbidden zstd" true
        (String_util.contains_substring h1_wildcard " 200 "
         && String_util.contains_substring h1_wildcard "content-encoding: gzip"
         && not (String_util.contains_substring h1_wildcard "content-encoding: zstd"));
      List.iter (fun fields ->
        let h1 = h1_read ~accept_encoding:fields (target base) |> String.lowercase_ascii in
        check bool "H1 combines repeated encoding fields" true
          (String_util.contains_substring h1 " 200 "
           && String_util.contains_substring h1 "content-encoding: gzip"
           && not (String_util.contains_substring h1 "content-encoding: zstd")))
        [ "Accept-Encoding: zstd;q=0\r\nAccept-Encoding: *;q=1\r\n";
          "Accept-Encoding: *;q=1\r\nAccept-Encoding: zstd;q=0\r\n" ];
      let h1_foreign = h1_read ~accept_encoding:"Accept-Encoding: zstd;q=0\r\nAccept-Encoding: *;q=1\r\n"
          (target (base ^ "/foreign")) |> String.lowercase_ascii in
      check bool "H1 refuses foreign workspace before direct generation" true
        (String_util.contains_substring h1_foreign " 409 "
         && not (String_util.contains_substring h1_foreign "x-masc-goal-tree-read: direct-v1")
         && not (String_util.contains_substring h1_foreign "content-encoding: zstd"));
      let code, headers, body = request_with_headers ~token:player
          ~extra_headers:[ "if-none-match", "*"; "origin", "http://localhost:8935" ]
          ~meth:`GET client (target base) in
      check int "bound read succeeds" 200 code;
      check bool "bound read attests the workspace" true
        (List.mem Masc.Workspace.read_precondition_admission_header headers);
      check bool "bound read attests direct generation" true
        (List.mem Masc.Server_utils.goal_tree_direct_read_header headers);
      check bool "bound response is not cacheable" true (List.mem ("cache-control", "private, no-store") headers);
      check bool "CORS exposes the direct-read receipt" true
        (List.exists (fun (name, value) -> String.equal name "access-control-expose-headers"
          && String_util.contains_substring (String.lowercase_ascii value) "x-masc-goal-tree-read") headers);
      let tree = Yojson.Safe.Util.(body |> Yojson.Safe.from_string |> member "tree" |> to_list) in
      check bool "bound response reads the committed Goal" true
        (List.exists (fun row -> Yojson.Safe.Util.(row |> member "id" |> to_string) = goal.id) tree);
      let code, headers, compressed = request_with_headers ~token:player
          ~extra_headers:[ "accept-encoding", "gzip" ] ~meth:`GET client (target base) in
      check int "compressed bound read succeeds" 200 code;
      check bool "H2 negotiates gzip" true (List.mem ("content-encoding", "gzip") headers);
      check bool "gzip body is smaller than the identity representation" true
        (String.length compressed < String.length body);
      let code, headers, _ = request_with_headers ~token:player
          ~extra_headers:[ "accept-encoding", "zstd;q=0, *;q=1" ] ~meth:`GET client (target base) in
      check int "wildcard bound read succeeds" 200 code;
      check bool "H2 wildcard does not re-enable forbidden zstd" true
        (List.mem ("content-encoding", "gzip") headers && not (List.mem ("content-encoding", "zstd") headers));
      List.iter (fun extra_headers ->
        let code, headers, _ = request_with_headers ~token:player ~extra_headers ~meth:`GET client (target base) in
        check int "repeated-field bound read succeeds" 200 code;
        check bool "H2 combines repeated encoding fields" true
          (List.mem ("content-encoding", "gzip") headers && not (List.mem ("content-encoding", "zstd") headers)))
        [ [ "accept-encoding", "zstd;q=0"; "accept-encoding", "*;q=1" ];
          [ "accept-encoding", "*;q=1"; "accept-encoding", "zstd;q=0" ] ];
      let code, headers, _ = request_with_headers ~token:player
          ~extra_headers:[ "accept-encoding", "zstd;q=0"; "accept-encoding", "*;q=1" ]
          ~meth:`GET client (target (base ^ "/foreign")) in
      check int "foreign workspace is refused" 409 code;
      check bool "refusal does not attest a direct read" false
        (List.mem Masc.Server_utils.goal_tree_direct_read_header headers);
      check bool "H2 refusal honors repeated encoding fields" false
        (List.mem ("content-encoding", "zstd") headers);
      strict (Some "1") (fun () ->
        let code, headers, _ = request_with_headers ~meth:`GET client (target base) in
        check int "strict authentication is still required" 401 code;
        check bool "authentication refusal has no direct-read receipt" false
          (List.mem Masc.Server_utils.goal_tree_direct_read_header headers));
      let old_scope = Masc.Mcp_server.workspace_scope state in
      Masc.Mcp_server.set_workspace_config state config |> Result.get_ok;
      check bool "same-path replacement invalidates the captured scope" false
        (Server_dashboard_http.goal_tree_scope_current state old_scope)))

let test_bound_goal_timeout_answers_while_read_pool_is_busy () =
  let routes = ref None in
  let runtime = ref None in
  let with_runtime ~env ~sw run =
    let was_ready = Eio_guard.is_ready () in
    Eio_guard.enable ();
    let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    let clock = Eio_mock.Clock.make () in
    Domain_pool_ref.set pool;
    Domain_pool_ref.set_read pool;
    Fun.protect ~finally:(fun () ->
      Domain_pool_ref.clear_for_tests ();
      if not was_ready then Eio_guard.disable ()) (fun () ->
      Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () ->
        Executor_pool_ref.For_testing.with_read_pool (Domain_pool.executor_pool pool) (fun () ->
          Dashboard_cache.For_testing.with_default_clock clock (fun () ->
            let occupied, mark_occupied = Eio.Promise.create () in
            let release, release_worker = Eio.Promise.create () in
            let blocker = Eio.Fiber.fork_promise ~sw (fun () ->
              Pool_lane.with_read (fun () ->
                Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
                  Eio.Promise.resolve mark_occupied (); Eio.Promise.await release))) in
            Eio.Promise.await occupied;
            runtime := Some (env, sw, clock);
            Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
              Eio.Promise.resolve release_worker ();
              Eio.Promise.await_exn blocker)) run)))) in
  with_gateway ~on_routes:(fun value -> routes := Some value) ~with_runtime ~make_routes:production
    (fun ~player ~reader:_ client -> strict None (fun () ->
      let env, sw, clock = match !runtime with
        | Some runtime -> runtime | None -> fail "fixture runtime missing" in
      let routes = match !routes with Some routes -> routes | None -> fail "fixture routes missing" in
      let state = match Server_auth.For_testing.snapshot_server_state () with
        | Some state -> state | None -> fail "fixture server missing" in
      let config = Masc.Mcp_server.workspace_config state in
      let target_for base = Uri.with_query (Uri.of_string "/api/v1/dashboard/goals")
        [ "expected_base_path", [base];
          "expected_masc_root", [Unix.realpath (Masc.Workspace.masc_dir config)] ] |> Uri.to_string in
      let target = target_for (Unix.realpath config.base_path) in
      let read_with_timeout ?(after_expiry = fun () -> ()) request =
        let pending = Eio.Fiber.fork_promise ~sw request in
        let rec expire_when_armed () =
          if not (Eio_mock.Clock.try_advance clock) then begin
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.001;
            expire_when_armed ()
          end in
        expire_when_armed ();
        after_expiry ();
        Eio.Promise.await_exn pending in
      let status, headers, _ = read_with_timeout (fun () ->
        request_with_headers ~token:player
          ~extra_headers:["accept-encoding", "zstd;q=0"; "accept-encoding", "*;q=1"] ~meth:`GET client target) in
      check int "H2 sends timeout before the worker is released" 504 status;
      check bool "H2 timeout uses the negotiated encoding" true
        (List.mem ("content-encoding", "gzip") headers && not (List.mem ("content-encoding", "zstd") headers));
      let authority = match Server_request_authority.of_host_port ~host:"localhost" ~port:8935 with
        | Ok authority -> authority | Error `Malformed -> fail "invalid fixture authority" in
      let h1_request ?(origin = "") ?(path = target) () =
        let output = Buffer.create 256 in
        let conn = Httpun.Server_connection.create (fun reqd ->
          Server_request_authority.with_current authority (fun () ->
            Masc.Http_server_eio.Router.dispatch routes (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd))) in
        let request = Printf.sprintf
          "GET %s HTTP/1.0\r\nHost: localhost:8935\r\nAuthorization: Bearer %s\r\nAccept-Encoding: zstd;q=0\r\nAccept-Encoding: *;q=1\r\n%s\r\n"
          path player origin in
        let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
        ignore (Httpun.Server_connection.read_eof conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
        let rec drain () = match Httpun.Server_connection.next_write_operation conn with
          | `Write iovecs ->
            let count = List.fold_left (fun count (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              count + iov.len) 0 iovecs in
            Httpun.Server_connection.report_write_result conn (`Ok count);
            drain ()
          | `Yield ->
            let ready, resolve = Eio.Promise.create () in
            Httpun.Server_connection.yield_writer conn (fun () -> Eio.Promise.resolve resolve ());
            Eio.Promise.await ready;
            drain ()
          | `Close _ -> Buffer.contents output in
        drain () in
      let h1 = read_with_timeout (fun () -> h1_request ()) |> String.lowercase_ascii in
      check bool "H1 sends timeout before the worker is released" true (String_util.contains_substring h1 " 504 ");
      check bool "H1 timeout uses the negotiated encoding" true
        (String_util.contains_substring h1 "content-encoding: gzip"
         && not (String_util.contains_substring h1 "content-encoding: zstd"));
      let foreign = Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2. (fun () ->
        h1_request ~path:(target_for (Unix.realpath config.base_path ^ "/foreign")) ())
        |> String.lowercase_ascii in
      check bool "H1 initial refusal does not queue behind the busy pool" true
        (String_util.contains_substring foreign " 409 "
         && not (String_util.contains_substring foreign "content-encoding: zstd"));
      let replace_scope () = Masc.Mcp_server.set_workspace_config state config |> Result.get_ok in
      let status, headers, _ = read_with_timeout ~after_expiry:replace_scope (fun () ->
        request_with_headers ~token:player ~extra_headers:["accept-encoding", "zstd;q=0";
          "accept-encoding", "*;q=1"; "origin", "https://attacker.invalid"]
          ~meth:`GET client target) in
      check int "H2 refuses a scope changed during a read" 409 status;
      check bool "H2 refusal carries no admission receipt" false
        (List.mem Masc.Workspace.read_precondition_admission_header headers);
      check bool "H2 changed-scope refusal honors repeated encoding fields" false
        (List.mem ("content-encoding", "zstd") headers);
      check bool "H2 refusal does not reflect an untrusted origin" false
        (List.exists (fun (name, _) -> String.equal name "access-control-allow-origin") headers);
      let h1 = read_with_timeout ~after_expiry:replace_scope
        (fun () -> h1_request ~origin:"Origin: https://attacker.invalid\r\n" ()) |> String.lowercase_ascii in
      check bool "H1 refuses a scope changed during a read" true (String_util.contains_substring h1 " 409 ");
      check bool "H1 refusal carries no admission receipt" false
        (String_util.contains_substring h1 "x-masc-workspace-read: matched-v1");
      check bool "H1 changed-scope refusal honors repeated encoding fields" false
        (String_util.contains_substring h1 "content-encoding: zstd");
      check bool "H1 refusal does not reflect an untrusted origin" false
        (String_util.contains_substring h1 "access-control-allow-origin:")))

(* The listener a health body names is the protocol the request came on.
   This exchange is HTTP/2, so the body says so; the table's handler once
   answered "http/1.1" for both protocols. *)
let test_health_names_the_h2_listener () =
  with_gateway ~make_routes:production (fun ~player:_ ~reader:_ client ->
    let code, body = request ~meth:`GET client "/health" in
    check int "health answers" 200 code;
    check string "the body names h2" "h2"
      Yojson.Safe.Util.(
        Yojson.Safe.from_string body |> member "protocol" |> member "listener" |> to_string))

(* Strict auth opens a request without a credential only when the route it
   reaches asks for none: [Always_public] or [Public_read Open_when_strict].
   The open paths are spelled as clients send them, so renaming a shared
   constant cannot move both sides. The browser <audio> element cannot send a
   bearer token, so the voice clip's file name is its capability, and a shared
   artifact link carries its id. The closed paths are guarded on HTTP/1; if one
   opened under strict auth, the H1/H2 parity tests would compare two open
   doors and prove nothing. *)
let test_strict_auth_opens_a_path_by_its_kind () =
  let module Router = Masc.Http_server_eio.Router in
  let captured = ref None in
  with_gateway ~on_routes:(fun routes -> captured := Some routes) ~make_routes:production
    (fun ~player:_ ~reader:_ _client -> ());
  let routes = match !captured with Some routes -> routes | None -> fail "no routes" in
  let opens_when_strict path =
    match Router.resolve routes (Httpun.Request.create `GET path) with
    | `Matched (route : Router.route) ->
      (match route.access with
       | Always_public | Public_read Open_when_strict -> true
       | Public_read Credential_when_strict | Read_auth | Permission _ | Token_permission _
       | Private_token_permission _ | Tool _ | Tool_observation _ | Tool_actor _
       | Self_authenticated _ | Manage_own_provider | Manage_own_keeper -> false)
    | `Method_not_allowed | `Not_found -> false
  in
  let artifact = "artifact-" ^ String.make 32 'a' in
  let sha256 = String.make 64 'a' in
  List.iter
    (fun (path, expected) -> check bool path expected (opens_when_strict path))
    [ "/api/v1/voice/audio/abc123", true
    ; "/api/v1/published-artifacts/" ^ artifact, true
    ; "/play", true
    ; "/play/agent.md", true
    ; "/play/x", false
    ; "/api/v1/voice/config", false
    ; "/api/v1/published-artifacts", false
    ; "/api/v1/published-artifact-checks", false
    ; "/api/v1/artifacts/" ^ sha256, false
    ; "/api/v1/artifacts-evil/" ^ sha256, false
    ; "/api/v1/artifact-bytes/" ^ sha256, false
    ; "/graphql", false
    ; "/api/v1/dashboard/workspace", false
    ; "/api/v1/status", false
    ; "/api/v1/openapi.json", false
    ; "/api/v1/gate/connector/names", false
    ; "/api/v1/board/curation", false
    ; "/api/v1/board/hearths", false
    ; "/api/v1/board/sub-boards", false
    ; "/api/v1/board/sub-boards/some-board", false
    ; "/api/v1/board/karma/ledger", false
    ; "/api/v1/karma", false
    ]

let () =
  run "H2 gateway"
    [ ( "one table"
      , [ test_case "HTTPS WebSocket discovery succeeds before the upgrade" `Quick
            test_https_websocket_discovery
        ; test_case "public read follows the router" `Quick test_public_read_follows_the_router
        ; test_case "token permission follows the router" `Quick
            test_token_permission_follows_the_router
        ; test_case "subpath routes check the token themselves" `Quick
            test_subpath_routes_check_the_token_themselves
        ; test_case "a path the router lacks is not found" `Quick
            test_a_path_the_router_lacks_is_not_found
        ; test_case "health names the h2 listener" `Quick test_health_names_the_h2_listener
        ; test_case "a route failure follows the response state" `Quick
            test_route_failure_follows_the_response_state
        ; test_case "the HTTP/1.1 error handler answers a fixed body" `Quick
            test_h1_error_handler_answers_a_fixed_body
        ; test_case "a cut request body reaches no route" `Quick
            test_a_cut_request_body_reaches_no_route
        ; test_case "Fusion workspace admission" `Quick test_fusion_workspace_admission
        ; test_case "physical Skill turn evidence" `Quick test_physical_skill_turn_evidence
        ; test_case "bound Goal tree bypasses stale cache" `Quick test_goal_tree_bound_read_bypasses_stale_cache
        ; test_case "bound Goal timeout answers while read pool is busy" `Quick test_bound_goal_timeout_answers_while_read_pool_is_busy
        ; test_case "strict auth opens a path by its kind" `Quick
            test_strict_auth_opens_a_path_by_its_kind
        ] )
    ]
