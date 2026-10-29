(* Actual GitHub-login route and adapter, through the production H2 connection
   runner. A blocked tmp GitHub config directory makes the real login lane
   refuse before it can run gh. This covers the adapter's error-event send and
   wrapped cancellation, not a successful device flow or subprocess output. *)
open Alcotest

module Identity = Masc.Keeper_github_identity
module Resources = Server_h2_response_resources
module Registry = Server_h2_stream_registry

type capacity = Exact_frame | One_byte_short

type response =
  { headers : H2.Response.t Eio.Promise.t
  ; finished : (string, unit) result Eio.Promise.t
  ; stream_error : H2.Client_connection.error Eio.Promise.t
  ; body : Buffer.t
  }

let require = function Ok value -> value | Error detail -> fail detail

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path

let request ~meth ~token client path =
  let headers, publish_headers = Eio.Promise.create () in
  let finished, finish = Eio.Promise.create () in
  let stream_error, publish_error = Eio.Promise.create () in
  let body = Buffer.create 256 in
  let finish_once value =
    if not (Eio.Promise.is_resolved finished) then Eio.Promise.resolve finish value
  in
  let writer = H2_eio.Client.request client ~flush_headers_immediately:true
    (H2.Request.create ~scheme:"http" meth path
       ~headers:(H2.Headers.of_list
         [ ":authority", "localhost:8935"
         ; "authorization", "Bearer " ^ token
         ]))
    ~error_handler:(fun error ->
      (* Aborted EOF can settle [finished] before the typed stream reset is
         delivered. Retain both independently, as the actual client does. *)
      if not (Eio.Promise.is_resolved stream_error) then
        Eio.Promise.resolve publish_error error;
      finish_once (Error ()))
    ~response_handler:(fun response reader ->
      Eio.Promise.resolve publish_headers response;
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () ->
          match H2.Body.Reader.completion reader with
          | Complete -> finish_once (Ok (Buffer.contents body))
          | Pending | Aborted -> finish_once (Error ()))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string body (Bigstringaf.substring chunk ~off ~len);
          read ())
      in
      read ())
  in
  H2.Body.Writer.close writer;
  { headers; finished; stream_error; body }

let with_gateway capacity run =
  let base_path = Filename.temp_dir "h2-github-response-" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      (match previous_fs with
       | Some fs -> Fs_compat.set_fs fs
       | None -> Fs_compat.clear_fs ());
      remove_tree base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      (* A test deadlock must fail instead of keeping its socket reader alive.
         This is a fixture bound, not a server stream-idle policy. *)
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~sw (fun () ->
              let state = Masc.Mcp_server.For_testing.create_state ~base_path in
              let config = Masc.Mcp_server.workspace_config state in
              ignore (Masc.Workspace.init config ~agent_name:None);
              let keeper_name = "github-response-fixture" in
              let keeper_toml = Keeper_sandbox_config.keeper_toml_path
                ~base_path ~agent_name:keeper_name in
              Fs_compat.mkdir_p (Filename.dirname keeper_toml);
              Out_channel.with_open_bin keeper_toml (fun out ->
                output_string out
                  "[keeper]\ninstructions = \"GitHub response fixture\"\n\
                   sandbox_profile = \"docker\"\nsandbox_image = \"base\"\n");
              let meta = Masc_test_deps.meta_of_json_fixture
                (`Assoc ["name", `String keeper_name]) |> require in
              Masc.Keeper_meta_store.replace_snapshot config meta |> require;
              let blocked_path = Identity.config_dir ~config ~keeper_name in
              Fs_compat.mkdir_p (Filename.dirname blocked_path);
              Out_channel.with_open_bin blocked_path (fun out ->
                output_string out "fixture: this is not a directory");
              let effective_meta = match
                  Masc.Keeper_meta_store.read_effective_meta config keeper_name |> require with
                | Some meta -> meta
                | None -> fail "actual route cannot find its Keeper fixture"
              in
              (match effective_meta.sandbox_profile with
               | Keeper_types_profile_sandbox.Docker -> ()
               | Keeper_types_profile_sandbox.Micro_vm
               | Keeper_types_profile_sandbox.Remote_ssh ->
                 fail "fixture must select the local GitHub lane before any remote shaping");
              let lane_error = match Masc.Keeper_github_login_lane.for_keeper
                  ~config ~meta:effective_meta
                  ~hostname:Identity.default_hostname with
                | Error detail -> detail
                | Ok _ -> fail "fixture did not prevent the actual gh lane from running"
              in
              let expected_event = Printf.sprintf "event: error\ndata: %s\n\n"
                (Yojson.Safe.to_string (`Assoc ["message", `String lane_error])) in
              let frame_bytes = String.length expected_event in
              let max_pending_bytes = match capacity with
                | Exact_frame -> frame_bytes
                | One_byte_short -> frame_bytes - 1
              in
              let resources = Resources.create ~max_pending_bytes in
              Auth.save_auth_config base_path
                {Masc_domain.default_auth_config with enabled=true; require_token=true};
              let token = match Auth.create_token base_path ~agent_name:"operator"
                  ~role:Masc_domain.Admin with
                | Ok (token, _) -> token
                | Error error -> fail (Masc_domain.masc_error_to_string error)
              in
              Server_auth.For_testing.restore_server_state (Some state);
              let trust_policy = Server_request_authority.make_trust_policy
                ~bind_host:"localhost" ~bind_port:8935 ~explicit_base_url:None
                |> Result.map_error Server_request_authority.trust_policy_error_to_string
                |> require in
              let gateway = Server_h2_gateway.make_request_handler ~routes:(Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock:(Eio.Stdenv.clock env)) ~trust_policy ~sw
                ~clock:(Eio.Stdenv.clock env) ~server_start_time:0. in
              let escaped = ref [] in
              let login_closed, close_login = Eio.Promise.create () in
              let sibling_closed, close_sibling = Eio.Promise.create () in
              let handler ~request_sw addr reqd =
                if String.equal (H2.Reqd.request reqd).target "/sibling" then (
                  Eio.Switch.on_release request_sw (fun () ->
                    Eio.Promise.resolve close_sibling ());
                  Server_h2_gateway_helpers.h2_respond_text reqd "alive"
                ) else (
                  Eio.Switch.on_release request_sw (fun () ->
                    Eio.Promise.resolve close_login ());
                  try gateway ~request_sw addr reqd with
                  | Eio.Cancel.Cancelled _ as exn -> escaped := exn :: !escaped; raise exn
                  | exn -> escaped := exn :: !escaped; raise exn
                )
              in
              let streams = Registry.create () in
              let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
              let closing = ref false in
              let connection_errors = ref 0 in
              let server = Eio.Fiber.fork_promise ~sw (fun () ->
                Eio.Switch.run (fun conn_sw ->
                  Server_bootstrap_http.serve_h2_connection ~streams ~resources
                    ~sw:conn_sw ~h2_request_handler:handler
                    ~h2_error_handler:(Server_h2_gateway.make_error_handler ())
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow)) in
              let client = H2_eio.Client.create_connection ~sw
                ~error_handler:(fun _ ->
                  if not !closing then incr connection_errors) client_flow in
              Fun.protect
                ~finally:(fun () ->
                  closing := true;
                  Eio.Flow.shutdown client_flow `All)
                (fun () ->
                  run ~client ~token ~keeper_name ~expected_event ~resources ~streams
                    ~login_closed ~sibling_closed;
                  check int "gateway contains the adapter failure" 0 (List.length !escaped);
                  check int "connection has no error" 0 !connection_errors;
                  check bool "invalid config entry stays untouched" true
                    ((Unix.lstat blocked_path).Unix.st_kind = Unix.S_REG));
              Eio.Promise.await_exn server)))))

let test_login_error_event capacity =
  with_gateway capacity (fun ~client ~token ~keeper_name ~expected_event ~resources ~streams
      ~login_closed ~sibling_closed ->
    let login = request ~meth:`POST ~token client
      ("/api/v1/keepers/" ^ keeper_name ^ "/github-login") in
    let response = Eio.Promise.await login.headers in
    check int "actual GitHub route opened the stream" 200
      (H2.Status.to_code response.status);
    check (option string) "actual GitHub stream type" (Some "text/event-stream")
      (H2.Headers.get response.headers "content-type");
    (match capacity with
     | Exact_frame ->
       (match Eio.Promise.await login.finished with
        | Ok body -> check string "whole actual adapter error event" expected_event body
        | Error () -> fail "exactly fitting GitHub error event failed");
       check bool "fitting event has no stream error" false
         (Eio.Promise.is_resolved login.stream_error)
     | One_byte_short ->
       (match Eio.Promise.await login.stream_error with
        | `Protocol_error (code, _) ->
          check bool "wrapped capacity failure resets its own stream" true
            (code = H2.Error_code.InternalError)
        | `Malformed_response _ | `Invalid_response_body_length _ | `Exn _ ->
          fail "expected the gateway's typed stream reset");
       (match Eio.Promise.await login.finished with
        | Error () -> ()
        | Ok _ -> fail "overflow became a successful short GitHub event stream");
       check int "refused frame delivers no partial payload" 0 (Buffer.length login.body));
    Eio.Promise.await login_closed;
    check int "login stream scope is released" 0 (Registry.active_streams streams);
    check int "completed or failed login releases capacity" 0 (Resources.pending_bytes resources);
    check bool "same H2 connection still answers PING" true
      (match Eio.Promise.await (H2_eio.Client.ping client) with
       | Ok () -> true | Error `EOF -> false);
    let sibling = request ~meth:`GET ~token client "/sibling" in
    let response = Eio.Promise.await sibling.headers in
    check int "sibling status after login" 200 (H2.Status.to_code response.status);
    (match Eio.Promise.await sibling.finished with
     | Ok body -> check string "sibling can use the same response capacity" "alive" body
     | Error () -> fail "GitHub login failure killed its sibling");
    Eio.Promise.await sibling_closed;
    check int "sibling stream scope is released" 0 (Registry.active_streams streams);
    check int "sibling releases reused capacity" 0 (Resources.pending_bytes resources))

let () = run "H2 actual GitHub response resources"
  ["production route", [
    test_case "exactly fitting login error event remains complete" `Quick
      (fun () -> test_login_error_event Exact_frame);
    test_case "overflow wrapped by actual login stays stream-local" `Quick
      (fun () -> test_login_error_event One_byte_short);
  ]]
