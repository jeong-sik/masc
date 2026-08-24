open Alcotest

module Routes = Server_routes_http_routes_channel_gate
module Mcp_server = Masc.Mcp_server
module Http_server_eio = Masc.Http_server_eio
module Workspace = Masc.Workspace
module Keeper_types_profile = Masc.Keeper_types_profile
module Keeper_meta_store = Masc.Keeper_meta_store
module U = Yojson.Safe.Util

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let rec with_envs names value f =
  match names with
  | [] -> f ()
  | name :: rest -> with_env name value (fun () -> with_envs rest value f)

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "sidecar-state-%d-%06d" (Unix.getpid ()) !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          ) else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)

let with_sidecar_paths prefix dir f =
  let status_path = Filename.concat dir (prefix ^ "-status.json") in
  let binding_path = Filename.concat dir (prefix ^ "-bindings.json") in
  let audit_path = Filename.concat dir (prefix ^ "-audit.jsonl") in
  let env_names suffix =
    let legacy = String.uppercase_ascii prefix ^ suffix in
    [ legacy; "MASC_" ^ legacy ]
  in
  with_envs (env_names "_STATUS_PATH") (Some status_path) (fun () ->
    with_envs (env_names "_BINDING_STORE_PATH") (Some binding_path) (fun () ->
      with_envs (env_names "_BINDING_AUDIT_PATH") (Some audit_path) f))

let test_resolve_connector_status_name_trims_and_lowercases () =
  check (option string) "name is trimmed and lowercased" (Some "discord")
    (Routes.resolve_connector_status_name ~name:"  Discord  " ())

let test_resolve_connector_status_name_ignores_blank_inputs () =
  check (option string) "blank name ignored" None
    (Routes.resolve_connector_status_name ~name:"   " ());
  check (option string) "absent name ignored" None
    (Routes.resolve_connector_status_name ())

let python_utc_iso_now () =
  let z = Gate_time_util.iso8601_of_unix (Unix.gettimeofday ()) in
  String.sub z 0 (String.length z - 1) ^ ".123456+00:00"

let test_gate_time_parser_accepts_python_utc_isoformat () =
  check bool "python UTC isoformat parsed" true
    (Option.is_some (Gate_time_util.parse_iso8601_opt (python_utc_iso_now ())));
  check bool "explicit non-UTC offset normalizes" true
    (Option.is_some
       (Gate_time_util.parse_iso8601_opt "2026-06-06T00:00:00+09:00"))

let test_connector_capability_wire_contract () =
  check
    (list string)
    "closed capability order and wire values"
    [ "runtime_status"; "bindings"; "audit" ]
    (List.map
       Channel_gate_connector_capability.to_wire
       Channel_gate_connector_capability.all)

let test_slack_bind_persists_binding_and_audit () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "slack" dir (fun () ->
    match
      Channel_gate_slack_state.bind ~channel_id:"C123" ~keeper_name:"luna"
        ~actor_name:"dashboard"
    with
    | Error err -> fail err
    | Ok json ->
        check string "channel" "slack" (json |> U.member "channel" |> U.to_string);
        let bindings = json |> U.member "configured_bindings" |> U.to_list in
        check int "one configured binding" 1 (List.length bindings);
        check int "runtime binding count" 1
          (json |> U.member "runtime_bindings_count" |> U.to_int);
        check string "keeper persisted" "luna"
          (List.hd bindings |> U.member "keeper_name" |> U.to_string);
        let audit = json |> U.member "recent_audit" |> U.to_list in
        check int "one audit event" 1 (List.length audit);
        check string "audit actor" "dashboard"
          (List.hd audit |> U.member "actor_name" |> U.to_string))

let test_slack_binding_store_error_is_typed () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "slack" dir (fun () ->
    let binding_path = Filename.concat dir "slack-bindings.json" in
    let oc = open_out_bin binding_path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{not-json");
    match
      Channel_gate_slack_state.resolve_keeper_for_channel_result
        ~channel_id:"C123"
    with
    | Ok _ -> fail "expected invalid Slack binding store to return Error"
    | Error _ -> ())

let check_binding_store_failure_projection label json =
  check bool (label ^ " binding read failed") false
    (json |> U.member "binding_store_read_ok" |> U.to_bool);
  check bool (label ^ " unavailable") false
    (json |> U.member "available" |> U.to_bool);
  check bool (label ^ " binding error retained") true
    (json |> U.member "binding_store_error" |> U.to_string
     |> String.length |> ( < ) 0)

let test_slack_status_surfaces_binding_store_failure () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "slack" dir (fun () ->
    let oc = open_out_bin (Filename.concat dir "slack-bindings.json") in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{not-json");
    check_binding_store_failure_projection "slack"
      (Channel_gate_slack_state.connector_json ()))

let test_telegram_status_surfaces_binding_store_failure () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "telegram" dir (fun () ->
    let oc = open_out_bin (Filename.concat dir "telegram-bindings.json") in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{not-json");
    check_binding_store_failure_projection "telegram"
      (Channel_gate_telegram_state.connector_json ()))


let test_slack_default_paths_resolve_under_base_path () =
  with_temp_dir (fun base_dir ->
    with_temp_dir (fun cwd_dir ->
      with_env "MASC_BASE_PATH" (Some base_dir) (fun () ->
        with_env "MASC_BASE_PATH_INPUT" None (fun () ->
          with_envs
            [
              "SLACK_BINDING_STORE_PATH"; "MASC_SLACK_BINDING_STORE_PATH"
            ; "SLACK_BINDING_AUDIT_PATH"; "MASC_SLACK_BINDING_AUDIT_PATH"
            ]
            None
            (fun () ->
              let original_cwd = Sys.getcwd () in
              Fun.protect
                ~finally:(fun () -> Sys.chdir original_cwd)
                (fun () ->
                  Sys.chdir cwd_dir;
                  match
                    Channel_gate_slack_state.bind ~channel_id:"C123"
                      ~keeper_name:"luna" ~actor_name:"dashboard"
                  with
                  | Error err -> fail err
                  | Ok json ->
                    let expected_binding_path =
                      Filename.concat base_dir ".gate/runtime/slack/bindings.json"
                    in
                    check string "binding store path under base" expected_binding_path
                      (json |> U.member "binding_store_path" |> U.to_string);
                    check bool "binding written under base" true
                      (Sys.file_exists expected_binding_path);
                    check bool "binding not written under cwd" false
                      (Sys.file_exists
                         (Filename.concat cwd_dir ".gate/runtime/slack/bindings.json"))))))))

let test_telegram_connector_json_reads_runtime_status () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "telegram" dir (fun () ->
    ignore
      (Channel_gate_telegram_state.bind ~channel_id:"12345" ~keeper_name:"luna"
         ~actor_name:"dashboard");
    let status_path = Filename.concat dir "telegram-status.json" in
    Yojson.Safe.to_file status_path
      (`Assoc
        [
          ("updated_at", `String (python_utc_iso_now ()));
          ("connected", `Bool true);
          ("gate_base_url", `String "http://127.0.0.1:8935");
          ("gate_healthy", `Bool true);
          ("gate_health_checked_at", `String (python_utc_iso_now ()));
          ("last_message_at", `String "2026-06-06T00:00:00Z");
          ("messages_processed", `Int 7);
          ("messages_failed", `Int 1);
          ("binding_source", `String "persisted");
          ("runtime_bindings_count", `Int 1);
          ("pid", `Int 4242);
        ]);
    let json = Channel_gate_telegram_state.connector_json () in
    check string "connector id" "telegram"
      (json |> U.member "connector_id" |> U.to_string);
    check bool "available" true (json |> U.member "available" |> U.to_bool);
    check bool "connected" true (json |> U.member "connected" |> U.to_bool);
    check int "messages processed" 7
      (json |> U.member "messages_processed" |> U.to_int);
    check int "configured bindings count" 1
      (json |> U.member "configured_bindings" |> U.to_list |> List.length))

let test_slack_connector_json_carries_identity () =
  with_temp_dir @@ fun dir ->
  with_sidecar_paths "slack" dir (fun () ->
    (* Regression: the dashboard connectors endpoint matches a connected
       gateway to its tile by [connector_id] (findConnector(connectors,
       "slack")). Slack's connector_json used to omit connector_id/display_name
       — Discord/Telegram carry them — so a connected Slack gateway rendered as
       an unstarted "설정 필요" placeholder. Both fields must be present. *)
    let json = Channel_gate_slack_state.connector_json () in
    check string "connector id" "slack"
      (json |> U.member "connector_id" |> U.to_string);
    check string "display name" "Slack"
      (json |> U.member "display_name" |> U.to_string);
    check
      (testable Yojson.Safe.pp Yojson.Safe.equal)
      "connector capabilities use the canonical projection"
      Channel_gate_connector_capability.all_json
      (json |> U.member "capabilities");
    check string "status source" "in_process_gateway"
      (json |> U.member "status_source" |> U.to_string);
    check bool "gateway state surfaced" true
      (json |> U.member "gateway_state" |> U.to_string
       |> String.trim |> String.length > 0))

(* Regression: /api/v1/gate/keeper-status route error paths.
   RFC-0371 B4 — the old handler derived 404 by substring-matching "keeper
   not found" in a rendered tool error.  The fix introduced a typed
   [keeper_exists] precheck so the route answers 400/404/503 directly.
   These tests pin the error_json wire contract and the four error-path
   response shapes so a future refactor cannot silently revert to
   substring-based classification. *)

let test_error_json_wire_shape () =
  let json = Channel_gate.error_json "name is required" in
  check bool "ok is false" false (json |> U.member "ok" |> U.to_bool);
  check string "error message" "name is required"
    (json |> U.member "error" |> U.to_string)

let test_error_json_unknown_keeper_includes_name () =
  let json = Channel_gate.error_json "unknown keeper: beta" in
  check bool "ok is false" false (json |> U.member "ok" |> U.to_bool);
  check string "error contains keeper name" "unknown keeper: beta"
    (json |> U.member "error" |> U.to_string)


(* HTTP boundary regression tests for GET /api/v1/gate/keeper-status *)

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> Alcotest.fail "failed to construct loopback request authority"

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok token_info -> token_info
  | Error msg -> Alcotest.failf "create_token failed: %s" (Masc_domain.masc_error_to_string msg)

let with_temp_base_path f =
  with_temp_dir (fun dir ->
    let auth_config =
      { Masc_domain.default_auth_config with enabled = true; require_token = true }
    in
    Auth.save_auth_config dir auth_config;
    let token, _cred =
      create_token_exn dir ~agent_name:"gate-admin" ~role:Masc_domain.Admin
    in
    let state = Mcp_server.For_testing.create_state ~base_path:dir in
    f dir state token)

let dispatch_gate_route ~sw ~clock state token target_path =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Routes.add_routes ~sw ~clock (Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf
        "GET %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\nAuthorization: Bearer %s\r\n\r\n"
        target_path token
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str
    in
    let rec feed off =
      let remaining = Bigstringaf.length bytes - off in
      if remaining > 0 then (
        let consumed =
          Httpun.Server_connection.read conn bytes ~off ~len:remaining
        in
        if consumed <= 0 then Alcotest.fail "httpun test feed made no progress";
        feed (off + consumed))
    in
    feed 0;
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
          List.iter
            (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
               Buffer.add_string response_buf
                 (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
            iovecs;
          let written =
            List.fold_left
              (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
              0 iovecs
          in
          Httpun.Server_connection.report_write_result conn (`Ok written);
          flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)

let parse_http_response response_str =
  let lines = String.split_on_char '\n' response_str in
  let status_code =
    match lines with
    | status_line :: _ ->
        (match String.split_on_char ' ' (String.trim status_line) with
         | _ver :: code_str :: _ -> int_of_string code_str
         | _ -> Alcotest.failf "Could not parse status line: %S" status_line)
    | [] -> Alcotest.fail "Empty response"
  in
  let json =
    match String.index_opt response_str '{' with
    | Some idx ->
        let body_str = String.sub response_str idx (String.length response_str - idx) in
        Yojson.Safe.from_string (String.trim body_str)
    | None ->
        Alcotest.failf "No JSON body found in response: %S" response_str
  in
  (status_code, json)

let test_keeper_status_http_400_missing_name () =
  with_temp_base_path (fun dir state token ->
    Printf.printf "TEST DIR: %s, CONFIG BASE PATH: %s\n%!" dir (Mcp_server.workspace_config state).Workspace.base_path;
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let response = dispatch_gate_route ~sw ~clock state token "/api/v1/gate/keeper-status" in
                let status, json = parse_http_response response in
        check int "http status 400" 400 status;
        check bool "ok is false" false (json |> U.member "ok" |> U.to_bool);
        check string "error message" "name is required" (json |> U.member "error" |> U.to_string))))

let test_keeper_status_http_400_blank_name () =
  with_temp_base_path (fun dir state token ->
    Printf.printf "TEST DIR: %s, CONFIG BASE PATH: %s\n%!" dir (Mcp_server.workspace_config state).Workspace.base_path;
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let response = dispatch_gate_route ~sw ~clock state token "/api/v1/gate/keeper-status?name=%20%20" in
                let status, json = parse_http_response response in
        check int "http status 400" 400 status;
        check bool "ok is false" false (json |> U.member "ok" |> U.to_bool);
        check string "error message" "name is required" (json |> U.member "error" |> U.to_string))))

let test_keeper_status_http_404_unknown_keeper () =
  with_temp_base_path (fun dir state token ->
    Printf.printf "TEST DIR: %s, CONFIG BASE PATH: %s\n%!" dir (Mcp_server.workspace_config state).Workspace.base_path;
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let response = dispatch_gate_route ~sw ~clock state token "/api/v1/gate/keeper-status?name=nonexistent_keeper" in
                let status, json = parse_http_response response in
        check int "http status 404" 404 status;
        check bool "ok is false" false (json |> U.member "ok" |> U.to_bool);
        check string "error message" "unknown keeper: nonexistent_keeper" (json |> U.member "error" |> U.to_string))))

let test_keeper_status_http_503_meta_read_error () =
  with_temp_base_path (fun dir state token ->
    Printf.printf "TEST DIR: %s, CONFIG BASE PATH: %s\n%!" dir (Mcp_server.workspace_config state).Workspace.base_path;
    let config = Mcp_server.workspace_config state in
    let corrupt_path = Keeper_types_profile.keeper_meta_path config "corrupt_keeper" in
    Fs_compat.mkdir_p (Filename.dirname corrupt_path);
    let oc = open_out corrupt_path in
    output_string oc "{ invalid json syntax }";
    close_out oc;
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let response = dispatch_gate_route ~sw ~clock state token "/api/v1/gate/keeper-status?name=corrupt_keeper" in
                let status, json = parse_http_response response in
        check int "http status 503" 503 status;
        check bool "ok is false" false (json |> U.member "ok" |> U.to_bool);
        check bool "error non-empty" true (String.length (json |> U.member "error" |> U.to_string) > 0))))

let runtime_toml = {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "gate_runtime_" ".toml" in
  let oc = open_out path in
  output_string oc runtime_toml;
  close_out oc;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e

let test_keeper_status_http_200_valid_keeper () =
  init_runtime_default_for_tests ();
  with_temp_base_path (fun _dir state token ->
    let config = Mcp_server.workspace_config state in
    let json =
      `Assoc
        [ ("name", `String "valid_keeper")
        ; ("agent_name", `String "keeper-valid_keeper-agent")
        ; ("trace_id", `String "trace-valid_keeper")
        ]
    in
    let meta =
      match Masc_test_deps.meta_of_json_fixture json with
      | Ok m -> m
      | Error err -> Alcotest.failf "meta_of_json_fixture failed: %s" err
    in
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error err -> Alcotest.failf "replace_snapshot failed: %s" err);
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let response = dispatch_gate_route ~sw ~clock state token "/api/v1/gate/keeper-status?name=valid_keeper" in
        let status, json = parse_http_response response in
        check int "http status 200" 200 status;
        check string "keeper name in response" "valid_keeper" (json |> U.member "name" |> U.to_string))))

let test_keeper_status_http_502_dispatch_failure () =
  with_temp_base_path (fun dir state token ->
    let agents_dir = Workspace.agents_dir (Mcp_server.workspace_config state) in
    Fs_compat.mkdir_p agents_dir;
    let valid_path = Filename.concat agents_dir "valid_keeper.json" in
    let oc = open_out valid_path in
    output_string oc {|{"name":"analyst"}|};
    close_out oc;
    Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run (fun sw ->
        let req = Httpun.Request.create `GET "/api/v1/gate/keeper-status?name=valid_keeper" in
        let response_buf = Buffer.create 1024 in
        Server_auth.publish_server_state state;
        let conn =
          Httpun.Server_connection.create (fun reqd ->
            Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
              let args = `Assoc [ ("name", `String "analyst"); ("tail_order", `String "invalid_order_value") ] in
              Routes.respond_keeper_tool_json ~sw ~clock state req reqd ~tool_name:"masc_keeper_status" ~args))
        in
        let request_str = Printf.sprintf "GET /api/v1/gate/keeper-status?name=valid_keeper HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\nAuthorization: Bearer %s\r\n\r\n" token in
        let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str in
        let rec feed off =
          let remaining = Bigstringaf.length bytes - off in
          if remaining > 0 then (
            let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
            if consumed <= 0 then Alcotest.fail "httpun feed made no progress";
            feed (off + consumed))
        in
        feed 0;
        let rec flush () =
          match Httpun.Server_connection.next_write_operation conn with
          | `Write iovecs ->
              List.iter
                (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
                   Buffer.add_string response_buf
                     (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
                iovecs;
              let written =
                List.fold_left
                  (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
                  0 iovecs
              in
              Httpun.Server_connection.report_write_result conn (`Ok written);
              flush ()
          | `Yield | `Close _ -> ()
        in
        flush ();
        let status, json = parse_http_response (Buffer.contents response_buf) in
        check int "http status 502" 502 status;
        check bool "ok is false" false (json |> U.member "ok" |> U.to_bool);
        check bool "error contains message" true (String.length (json |> U.member "error" |> U.to_string) > 0))))
let () =
  run "channel_gate_connector_routes"
    [
      ( "keeper_status_route_http_contract",
        [
          test_case "error_json wire shape" `Quick
            test_error_json_wire_shape;
          test_case "unknown keeper error includes name" `Quick
            test_error_json_unknown_keeper_includes_name;
          test_case "HTTP 400 Bad Request on missing name" `Quick
            test_keeper_status_http_400_missing_name;
          test_case "HTTP 400 Bad Request on blank name" `Quick
            test_keeper_status_http_400_blank_name;
          test_case "HTTP 404 Not Found on unknown keeper" `Quick
            test_keeper_status_http_404_unknown_keeper;
          test_case "HTTP 503 Service Unavailable on corrupt meta read error" `Quick
            test_keeper_status_http_503_meta_read_error;
          test_case "HTTP 200 OK on valid keeper status dispatch" `Quick
            test_keeper_status_http_200_valid_keeper;
          test_case "HTTP 502 Bad Gateway on post-precheck dispatch failure" `Quick
            test_keeper_status_http_502_dispatch_failure;
        ] );

      ( "resolve_connector_status_name",
        [
          test_case "trims and lowercases the name" `Quick
            test_resolve_connector_status_name_trims_and_lowercases;
          test_case "ignores blank and absent input" `Quick
            test_resolve_connector_status_name_ignores_blank_inputs;
        ] );
      ( "sidecar_connector_state",
        [
          test_case "gate time parses python UTC isoformat" `Quick
            test_gate_time_parser_accepts_python_utc_isoformat;
          test_case "connector capability wire contract" `Quick
            test_connector_capability_wire_contract;
          test_case "slack bind persists binding and audit" `Quick
            test_slack_bind_persists_binding_and_audit;
          test_case "slack binding read errors are typed" `Quick
            test_slack_binding_store_error_is_typed;
          test_case "slack status surfaces binding read failure" `Quick
            test_slack_status_surfaces_binding_store_failure;
          test_case "slack default paths resolve under base path" `Quick
            test_slack_default_paths_resolve_under_base_path;
          test_case "telegram connector json reads runtime status" `Quick
            test_telegram_connector_json_reads_runtime_status;
          test_case "telegram status surfaces binding read failure" `Quick
            test_telegram_status_surfaces_binding_store_failure;
          test_case "slack connector json carries connector_id/display_name" `Quick
            test_slack_connector_json_carries_identity;
        ] );
    ]
