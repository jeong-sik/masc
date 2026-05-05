module Types = Masc_domain

open Alcotest
open Masc_mcp

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let valid_codex_config =
  {|[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
bearer_token_env_var = "MASC_MCP_TOKEN"
|}

let with_valid_codex_config dir f =
  let path = Filename.concat dir "codex-config.toml" in
  write_file path valid_codex_config;
  with_env "MASC_CODEX_CONFIG_PATH" path f

let contains_substring ~needle s =
  let nl = String.length needle in
  let sl = String.length s in
  if nl = 0 || nl > sl then false
  else
    let limit = sl - nl in
    let rec loop i =
      if i > limit then false
      else if String.sub s i nl = needle then true
      else loop (i + 1)
    in
    loop 0

let list_contains_substring ~needle values =
  List.exists (contains_substring ~needle) values

let expected_codex_config_stage_names =
  [
    "codex_config_file";
    "codex_config_parse";
    "codex_server_config";
    "codex_auth_model";
    "codex_http_headers";
    "codex_agent_header";
    "codex_oauth_login";
  ]

let check_codex_config_stage_names (config : Codex_mcp_config_doctor.t) =
  let names =
    List.map
      (fun (stage : Codex_mcp_config_doctor.stage) -> stage.name)
      config.stages
  in
  check (list string) "stable codex config stage names"
    expected_codex_config_stage_names names

let save_credential_or_fail base_path ~agent_name ~role ~raw_token =
  match
    Auth.save_raw_token_credential base_path ~agent_name ~role ~raw_token
  with
  | Ok _ -> ()
  | Error err ->
      failf "failed to seed credential for %s: %s"
        agent_name (Masc_domain.masc_error_to_string err)

let raw_token_file base_path agent_name =
  Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")

let find_mcp_client report client_name =
  match
    List.find_opt
      (fun (client : Auth_doctor.mcp_client) ->
        String.equal client.client_name client_name)
      (report : Auth_doctor.t).mcp_clients
  with
  | Some client -> client
  | None -> failf "missing mcp client report for %s" client_name

let test_warns_for_codex_worker_admin_route_mismatch () =
  with_temp_dir "auth-doctor-warn" @@ fun base_path ->
  let auth_cfg =
    Masc_domain.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"codex" ~role:Masc_domain.Worker
    ~raw_token:"codex-token";
  save_credential_or_fail base_path ~agent_name:"codex-mcp-client"
    ~role:Masc_domain.Worker ~raw_token:"codex-mcp-token";
  save_credential_or_fail base_path ~agent_name:"dashboard-dev"
    ~role:Masc_domain.Admin ~raw_token:"dashboard-dev-token";
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_valid_codex_config base_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  check string "status" "warn"
    (Auth_doctor.status_to_string report.status);
  check bool "token-bound admin ready" true
    report.token_bound_admin_http_ready;
  check bool "dashboard dev endpoint available" true
    report.dashboard_dev_token_available;
  check bool "warns on codex worker" true
    (list_contains_substring
       ~needle:"codex is role=worker"
       report.warnings);
  check bool "warns on codex-mcp-client worker" true
    (list_contains_substring
       ~needle:"codex-mcp-client is role=worker"
       report.warnings);
  check bool "suggests admin bearer for cascade save" true
    (list_contains_substring
       ~needle:"Use dashboard-dev or another admin bearer"
       report.next_actions)

let test_errors_when_no_admin_bearer_source_exists () =
  with_temp_dir "auth-doctor-error" @@ fun base_path ->
  let auth_cfg =
    Masc_domain.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"codex" ~role:Masc_domain.Worker
    ~raw_token:"codex-token";
  with_env "MASC_HOST" "0.0.0.0" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "1" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_valid_codex_config base_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  check string "status" "error"
    (Auth_doctor.status_to_string report.status);
  check bool "token-bound admin not ready" false
    report.token_bound_admin_http_ready;
  check bool "dashboard dev endpoint unavailable" false
    report.dashboard_dev_token_available;
  check bool "warns about missing admin bearer" true
    (list_contains_substring
       ~needle:"No usable admin bearer source was detected"
       report.warnings);
  check bool "next action points to runbook" true
    (list_contains_substring
       ~needle:"LOCAL-DASHBOARD-AUTH-RUNBOOK"
       report.next_actions)

let test_ignores_stale_admin_raw_token_file () =
  with_temp_dir "auth-doctor-stale" @@ fun base_path ->
  let auth_cfg =
    Masc_domain.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"admin" ~role:Masc_domain.Admin
    ~raw_token:"live-admin-token";
  Auth.save_private_text_file (raw_token_file base_path "admin")
    "stale-admin-token";
  with_env "MASC_HOST" "0.0.0.0" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "1" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_valid_codex_config base_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  check string "status" "error"
    (Auth_doctor.status_to_string report.status);
  check bool "stale token file not counted as ready" false
    report.token_bound_admin_http_ready;
  check bool "stale token file omitted from admin bearer sources" false
    (list_contains_substring ~needle:"token_file:admin"
       report.admin_bearer_sources);
  check bool "warns about missing usable admin bearer" true
    (list_contains_substring
       ~needle:"No usable admin bearer source was detected"
       report.warnings)

let test_reports_codex_mcp_bearer_env () =
  with_temp_dir "auth-doctor-codex-mcp" @@ fun base_path ->
  let auth_cfg =
    Masc_domain.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"admin" ~role:Masc_domain.Admin
    ~raw_token:"admin-token";
  Auth.save_private_text_file (raw_token_file base_path "admin")
    "admin-token";
  save_credential_or_fail base_path ~agent_name:"codex-mcp-client"
    ~role:Masc_domain.Worker ~raw_token:"codex-mcp-token";
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "codex-mcp-token" @@ fun () ->
  with_valid_codex_config base_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  check string "codex server name" "masc"
    report.codex_mcp.server_name;
  check string "codex auth model" "bearer_token_env"
    report.codex_mcp.auth_model;
  check string "codex token status" "live"
    report.codex_mcp.token_status;
  check (option string) "codex token agent"
    (Some "codex-mcp-client")
    report.codex_mcp.token_agent;
  check (option string) "codex token role" (Some "worker")
    report.codex_mcp.token_role;
  check (option bool) "codex can read state" (Some true)
    report.codex_mcp.token_can_read_state;
  check bool "codex login unsupported" false
    report.codex_mcp.login_supported;
  check bool "doctor text names bearer env" true
    (contains_substring ~needle:"token_env_var: MASC_MCP_TOKEN"
       (Auth_doctor.render_text report));
  check bool "no codex login warning when env is live" false
    (list_contains_substring ~needle:"codex mcp login"
       report.warnings)

let test_reports_claude_and_gemini_mcp_client_identities () =
  with_temp_dir "auth-doctor-mcp-clients" @@ fun base_path ->
  let auth_cfg =
    Masc_domain.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"admin" ~role:Masc_domain.Admin
    ~raw_token:"admin-token";
  Auth.save_private_text_file (raw_token_file base_path "admin")
    "admin-token";
  save_credential_or_fail base_path ~agent_name:"claude"
    ~role:Masc_domain.Worker ~raw_token:"claude-token";
  Auth.save_private_text_file (raw_token_file base_path "claude")
    "claude-token";
  save_credential_or_fail base_path ~agent_name:"gemini"
    ~role:Masc_domain.Worker ~raw_token:"gemini-token";
  Auth.save_private_text_file (raw_token_file base_path "gemini")
    "gemini-token";
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_env "MASC_CLAUDE_MCP_TOKEN" "" @@ fun () ->
  with_env "MASC_GEMINI_MCP_TOKEN" "" @@ fun () ->
  with_valid_codex_config base_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  let claude = find_mcp_client report "claude" in
  check string "claude agent" "claude" claude.agent_name;
  check string "claude env" "MASC_CLAUDE_MCP_TOKEN"
    claude.token_env_var;
  check string "claude token source" "token_file" claude.token_source;
  check string "claude token status" "live" claude.token_status;
  check bool "claude identity ready" true claude.identity_ready;
  let gemini = find_mcp_client report "gemini" in
  check string "gemini env" "MASC_GEMINI_MCP_TOKEN"
    gemini.token_env_var;
  check bool "gemini identity ready" true gemini.identity_ready;
  check bool "json exposes mcp clients" true
    (contains_substring ~needle:"\"mcp_clients\""
       (Auth_doctor.to_yojson report |> Yojson.Safe.to_string));
  check bool "text names claude env" true
    (contains_substring ~needle:"MASC_CLAUDE_MCP_TOKEN"
       (Auth_doctor.render_text report))

let test_reports_codex_config_pipeline_stages () =
  with_temp_dir "auth-doctor-codex-config-ok" @@ fun base_path ->
  let auth_cfg =
    Masc_domain.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"codex-mcp-client"
    ~role:Masc_domain.Worker ~raw_token:"codex-mcp-token";
  save_credential_or_fail base_path ~agent_name:"admin" ~role:Masc_domain.Admin
    ~raw_token:"admin-token";
  Auth.save_private_text_file (raw_token_file base_path "admin")
    "admin-token";
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "codex-mcp-token" @@ fun () ->
  with_valid_codex_config base_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  let config = report.codex_mcp.config in
  check bool "codex config file present" true config.file_present;
  check bool "masc server present" true config.server_present;
  check (option string) "bearer env var"
    (Some "MASC_MCP_TOKEN")
    config.bearer_token_env_var;
  check (option bool) "bearer env var matches" (Some true)
    config.bearer_token_env_matches;
  check (option bool) "no hardcoded authorization header" (Some false)
    config.authorization_header_present;
  check (option bool) "accept header ok" (Some true)
    config.accept_header_ok;
  check (option bool) "agent header ok" (Some true)
    config.x_masc_agent_ok;
  check bool "no codex config pipeline warning" false
    (list_contains_substring ~needle:"Codex MCP pipeline"
       report.warnings);
  check bool "json exposes config stages" true
    (contains_substring ~needle:"\"stages\""
       (Auth_doctor.to_yojson report |> Yojson.Safe.to_string));
  check_codex_config_stage_names config

let test_reports_stable_codex_config_stages_when_file_missing () =
  with_temp_dir "auth-doctor-codex-config-missing" @@ fun base_path ->
  let missing_path = Filename.concat base_path "missing-codex.toml" in
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_env "MASC_CODEX_CONFIG_PATH" missing_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  let config = report.codex_mcp.config in
  check bool "codex config file missing" false config.file_present;
  check_codex_config_stage_names config;
  check bool "oauth login remains classified as skip" true
    (List.exists
       (fun (stage : Codex_mcp_config_doctor.stage) ->
         String.equal stage.name "codex_oauth_login"
         && match stage.status with
            | Codex_mcp_config_doctor.Stage_skip -> true
            | Codex_mcp_config_doctor.Stage_pass
            | Codex_mcp_config_doctor.Stage_warn
            | Codex_mcp_config_doctor.Stage_fail ->
                false)
       config.stages);
  check bool "suggests config path repair" true
    (list_contains_substring ~needle:"MASC_CODEX_CONFIG_PATH"
       report.next_actions)

let test_warns_when_codex_config_uses_wrong_server_name () =
  with_temp_dir "auth-doctor-codex-config-wrong-name" @@ fun base_path ->
  let config_path = Filename.concat base_path "codex-config.toml" in
  write_file config_path
    {|[mcp_servers.mago]
url = "http://127.0.0.1:8935/mcp"
http_headers = { "Accept" = "application/json, text/event-stream" }
bearer_token_env_var = "MASC_MCP_TOKEN"
|};
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_env "MASC_CODEX_CONFIG_PATH" config_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  check bool "masc server missing" false
    report.codex_mcp.config.server_present;
  check bool "captures wrong server name" true
    (List.mem "mago" report.codex_mcp.config.server_names);
  check bool "warns with wrong server name detail" true
    (list_contains_substring
       ~needle:"configured server names: mago"
       report.warnings);
  check bool "suggests canonical server section" true
    (list_contains_substring
       ~needle:"Create a [mcp_servers.masc] entry"
       report.next_actions)

let test_warns_when_codex_config_uses_hardcoded_authorization () =
  with_temp_dir "auth-doctor-codex-config-hardcoded-auth" @@ fun base_path ->
  let config_path = Filename.concat base_path "codex-config.toml" in
  write_file config_path
    {|[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
http_headers = { "Accept" = "application/json, text/event-stream", "Authorization" = "Bearer stale-token" }
bearer_token_env_var = "MASC_MCP_TOKEN"
|};
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  with_env "MASC_CODEX_CONFIG_PATH" config_path @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  check (option bool) "authorization header detected" (Some true)
    report.codex_mcp.config.authorization_header_present;
  check bool "warns about hardcoded authorization" true
    (list_contains_substring
       ~needle:"http_headers still contains Authorization"
       report.warnings);
  check bool "does not leak token literal" false
    (list_contains_substring ~needle:"stale-token" report.warnings)

let () =
  run "auth_doctor"
    [
      ( "doctor",
        [
          test_case "warns for codex worker admin mismatch" `Quick
            test_warns_for_codex_worker_admin_route_mismatch;
          test_case "errors when no admin bearer source exists" `Quick
            test_errors_when_no_admin_bearer_source_exists;
          test_case "ignores stale admin raw token file" `Quick
            test_ignores_stale_admin_raw_token_file;
          test_case "reports Codex MCP bearer env" `Quick
            test_reports_codex_mcp_bearer_env;
          test_case "reports Claude and Gemini MCP client identities" `Quick
            test_reports_claude_and_gemini_mcp_client_identities;
          test_case "reports Codex MCP config pipeline stages" `Quick
            test_reports_codex_config_pipeline_stages;
          test_case "reports stable Codex MCP config stages when file missing"
            `Quick
            test_reports_stable_codex_config_stages_when_file_missing;
          test_case "warns when Codex MCP config uses wrong server name" `Quick
            test_warns_when_codex_config_uses_wrong_server_name;
          test_case "warns when Codex MCP config uses hardcoded auth" `Quick
            test_warns_when_codex_config_uses_hardcoded_authorization;
        ] );
    ]
