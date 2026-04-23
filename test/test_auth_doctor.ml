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

let save_credential_or_fail base_path ~agent_name ~role ~raw_token =
  match
    Auth.save_raw_token_credential base_path ~agent_name ~role ~raw_token
  with
  | Ok _ -> ()
  | Error err ->
      failf "failed to seed credential for %s: %s"
        agent_name (Types.masc_error_to_string err)

let raw_token_file base_path agent_name =
  Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")

let test_warns_for_codex_worker_admin_route_mismatch () =
  with_temp_dir "auth-doctor-warn" @@ fun base_path ->
  let auth_cfg =
    Types.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"codex" ~role:Types.Worker
    ~raw_token:"codex-token";
  save_credential_or_fail base_path ~agent_name:"codex-mcp-client"
    ~role:Types.Worker ~raw_token:"codex-mcp-token";
  save_credential_or_fail base_path ~agent_name:"dashboard-dev"
    ~role:Types.Admin ~raw_token:"dashboard-dev-token";
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
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
    Types.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"codex" ~role:Types.Worker
    ~raw_token:"codex-token";
  with_env "MASC_HOST" "0.0.0.0" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "1" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
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
    Types.
      {
        enabled = true;
        room_secret_hash = None;
        require_token = true;
        token_expiry_hours = 24;
      }
  in
  Auth.save_auth_config base_path auth_cfg;
  save_credential_or_fail base_path ~agent_name:"admin" ~role:Types.Admin
    ~raw_token:"live-admin-token";
  Auth.save_private_text_file (raw_token_file base_path "admin")
    "stale-admin-token";
  with_env "MASC_HOST" "0.0.0.0" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "1" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
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
        ] );
    ]
