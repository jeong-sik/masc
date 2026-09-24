open Alcotest

module Helpers = Server_h2_gateway_helpers

type completion = End_of_body | Oversized_body

let rec remove_tree path =
  if Sys.is_directory path then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path

let trust_policy () =
  match Server_request_authority.make_trust_policy
    ~bind_host:"localhost" ~bind_port:8935 ~explicit_base_url:None with
  | Ok policy -> policy
  | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)

let with_gateway run =
  Masc_test_deps.with_process_env "MASC_OAUTH_ENABLED" (Some "1") @@ fun () ->
  let base_path = Filename.temp_file "masc-h2-oauth-fibers" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      remove_tree base_path)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 @@ fun () ->
      Eio.Switch.run @@ fun sw ->
      Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
        (fun () ->
          let state = Masc.Mcp_server.For_testing.create_state ~base_path in
          ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config state)
            ~agent_name:None);
          Server_auth.For_testing.restore_server_state (Some state);
          let gateway = Server_h2_gateway.make_request_handler
            ~trust_policy:(trust_policy ()) ~sw ~clock:(Eio.Stdenv.clock env)
            ~server_start_time:0. in
          let pool = Domain_pool.create ~sw ~domain_count:1 env#domain_mgr in
          let previous_pool = Domain_pool_ref.get () in
          Eio.Switch.on_release sw (fun () ->
            match previous_pool with
            | None -> Domain_pool_ref.clear_for_tests ()
            | Some pool -> Domain_pool_ref.set pool);
          Domain_pool_ref.set pool;
          Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool)
            (fun () ->
              let occupied, occupy = Eio.Promise.create () in
              let released, release_worker = Eio.Promise.create () in
              let release () =
                if not (Eio.Promise.is_resolved released) then
                  Eio.Promise.resolve release_worker () in
              (* Release before the switch joins its worker, including when
                 a regression times out or an assertion fails. *)
              Fun.protect ~finally:release (fun () ->
                Eio.Fiber.fork ~sw (fun () ->
                  Domain_pool.submit_cpu pool (fun () ->
                    Eio.Promise.resolve occupy ();
                    Eio.Promise.await released));
                Eio.Promise.await occupied;
                let reader_ready, mark_reader_ready = Eio.Promise.create () in
                let handler ~request_sw addr reqd =
                  match (H2.Reqd.request reqd).target with
                  | "/fast" -> Helpers.h2_respond_json ~compress:false reqd "alive"
                  | "/oauth/register" ->
                    gateway ~request_sw addr reqd;
                    (* No DATA has been sent yet. Returning from the actual
                       gateway means its OAuth body reader is registered. *)
                    Eio.Promise.resolve mark_reader_ready ()
                  | path -> failf "unexpected fixture path %s" path in
                let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
                let server = Eio.Fiber.fork_promise ~sw (fun () ->
                  Eio.Switch.run @@ fun conn_sw ->
                  Server_bootstrap_http.serve_h2_connection ~sw:conn_sw
                    ~h2_request_handler:handler
                    ~h2_error_handler:(Server_h2_gateway.make_error_handler ())
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow) in
                let closing = ref false in
                let client = H2_eio.Client.create_connection ~sw
                  ~error_handler:(fun _ ->
                    if not !closing then fail "unexpected H2 connection error")
                  client_flow in
                run ~client ~client_flow ~reader_ready ~release;
                release ();
                closing := true;
                Eio.Flow.close client_flow;
                Eio.Promise.await_exn server))))

let open_request ~meth client path =
  let reply, resolve = Eio.Promise.create () in
  let request = H2.Request.create ~scheme:"http" meth path
    ~headers:(H2.Headers.of_list
      [ ":authority", "localhost:8935"
      ; "accept-encoding", "gzip"
      ; "content-type", "application/json"
      ]) in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true request
    ~error_handler:(fun _ ->
      if not (Eio.Promise.is_resolved reply) then Eio.Promise.resolve resolve (Error ()))
    ~response_handler:(fun response reader ->
      let body = Buffer.create 256 in
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> Eio.Promise.resolve resolve
          (Ok (response, Buffer.contents body)))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string body (Bigstringaf.substring chunk ~off ~len);
          read ()) in
      read ()) in
  writer, reply

let await_reply reply =
  match Eio.Promise.await reply with
  | Ok response -> response
  | Error () -> fail "H2 stream failed before its response"

let test_oauth_body_progress completion =
  with_gateway (fun ~client ~client_flow ~reader_ready ~release ->
    let writer, slow = open_request ~meth:`POST client "/oauth/register" in
    Eio.Promise.await reader_ready;
    let body, message = match completion with
      | End_of_body -> "{}", "redirect_uris is required"
      | Oversized_body ->
        String.make (Server_oauth_service.max_request_body_bytes + 1) 'x',
        "request body is too large" in
    H2.Body.Writer.write_string writer body;
    let written, mark_written = Eio.Promise.create () in
    H2.Body.Writer.flush writer (fun result -> Eio.Promise.resolve mark_written result);
    check bool "OAuth DATA reached the transport" true
      (match Eio.Promise.await written with `Written -> true | `Closed -> false);
    (match completion with
     | End_of_body ->
       (* Writer.flush acknowledges DATA, but Writer.close only queues its
          END_STREAM for a later scheduler pass. Send that empty DATA frame
          on stream 1 directly so it is definitely before the following PING.
          This fixture never writes through this request writer again. *)
       Eio.Flow.copy_string "\000\000\000\000\001\000\000\000\001" client_flow
     | Oversized_body ->
       (* Keep the upload open: oversize rejection must not wait for EOF. *)
       ());
    check bool "PING progresses after OAuth DATA while the worker is occupied" true
      (match Eio.Promise.await (H2_eio.Client.ping client) with
       | Ok () -> true
       | Error `EOF -> false);
    let fast_writer, fast = open_request ~meth:`GET client "/fast" in
    H2.Body.Writer.close fast_writer;
    let response, fast_body = await_reply fast in
    check int "sibling status" 200 (H2.Status.to_code response.status);
    check string "sibling completes before worker release" "alive" fast_body;
    check bool "OAuth response remains queued for the held worker" false
      (Eio.Promise.is_resolved slow);
    release ();
    let response, actual_body = await_reply slow in
    check int "OAuth rejection status" 400 (H2.Status.to_code response.status);
    let expected_json = Server_oauth_service.oauth_error_json
      (Auth_oauth.Invalid_request message) |> Yojson.Safe.to_string in
    let expected_body, expected_headers = Masc.Http_response_payload.compress_body
      ~accept_encoding:(Some "gzip") expected_json in
    check string "OAuth rejection body" expected_body actual_body;
    check (option string) "OAuth compression headers"
      (List.assoc_opt "content-encoding" expected_headers)
      (H2.Headers.get response.headers "content-encoding");
    check (option string) "OAuth rejection remains non-cacheable" (Some "no-store")
      (H2.Headers.get response.headers "cache-control"))

let () = run "H2 OAuth request fibers" ["DATA callbacks", [
  test_case "EOF preserves PING and sibling progress" `Quick
    (fun () -> test_oauth_body_progress End_of_body);
  test_case "oversize preserves PING and sibling progress before EOF" `Quick
    (fun () -> test_oauth_body_progress Oversized_body);
]]
