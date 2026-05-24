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
        agent_name (Masc_domain.masc_error_to_string err)

let raw_token_file base_path agent_name =
  Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")

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
  with_env "MASC_HOST" "0.0.0.0" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "1" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
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

(* The previous test "reports Claude and Gemini MCP client identities"
   was removed: the per-client diagnostic that it locked is gone.
   The server is now MCP-client-agnostic, so it holds no list of
   "known" clients to diagnose. Operators who need per-client
   readiness checks compose them externally over the raw
   doctor-auth JSON. *)

let test_json_no_longer_emits_mcp_clients_field () =
  with_temp_dir "auth-doctor-no-mcp-clients" @@ fun base_path ->
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
  save_credential_or_fail base_path ~agent_name:"admin"
    ~role:Masc_domain.Admin ~raw_token:"admin-token";
  Auth.save_private_text_file (raw_token_file base_path "admin")
    "admin-token";
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_AUTH_STRICT" "" @@ fun () ->
  with_env "MASC_ADMIN_TOKEN" "" @@ fun () ->
  with_env "MASC_MCP_TOKEN" "" @@ fun () ->
  let report =
    Auth_doctor.analyze ~base_path_input:base_path
      ~default_base_path:base_path ()
  in
  let json_string =
    Auth_doctor.to_yojson report |> Yojson.Safe.to_string
  in
  check bool "json omits mcp_clients key" false
    (contains_substring ~needle:"\"mcp_clients\"" json_string);
  check bool "text omits mcp_clients section" false
    (contains_substring ~needle:"mcp_clients:"
       (Auth_doctor.render_text report))

let () =
  run "auth_doctor"
    [
      ( "doctor",
        [
          test_case "errors when no admin bearer source exists" `Quick
            test_errors_when_no_admin_bearer_source_exists;
          test_case "ignores stale admin raw token file" `Quick
            test_ignores_stale_admin_raw_token_file;
          test_case "json omits mcp_clients field" `Quick
            test_json_no_longer_emits_mcp_clients_field;
        ] );
    ]
