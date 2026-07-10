module Types = Masc_domain

open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let contains_substring ~needle s =
  let nl = String.length needle in
  let sl = String.length s in
  if nl = 0 || nl > sl then
    false
  else
    let limit = sl - nl in
    let rec loop i =
      if i > limit then false
      else if String.sub s i nl = needle then true
      else loop (i + 1)
    in
    loop 0

(* With_expiry path: caller passes the default env var name, mint
   honors it verbatim. Agent_name is just a free string — the server
   no longer derives env names from it. *)
let test_login_with_expiry_uses_caller_env_var () =
  with_temp_dir "auth-login" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"test-agent" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:Auth_login.With_expiry ()
  with
  | Error err ->
      failf "login mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
      let cfg = Auth.load_auth_config base_path in
      check bool "auth enabled" true cfg.enabled;
      check bool "require token" true cfg.require_token;
      check string "agent" "test-agent" report.agent_name;
      check string "role" "worker"
        (Masc_domain.agent_role_to_string report.role);
      check string "client env passthrough" "MASC_TOKEN"
        report.mcp_token_env_var;
      check string "dashboard URL carries only the agent hint"
        "http://127.0.0.1:8935/dashboard?agent=test-agent"
        report.dashboard_url;
      check bool "dashboard URL excludes bearer token" false
        (contains_substring ~needle:report.bearer_token report.dashboard_url);
      check bool "raw token file exists" true
        (Sys.file_exists report.raw_token_file);
      (match
         Auth.find_credential_by_token base_path
           ~token:report.bearer_token
       with
       | Ok cred ->
           check string "token owner" "test-agent" cred.agent_name
       | Error err ->
           failf "minted token did not verify: %s"
             (Masc_domain.masc_error_to_string err));
      (match
         Auth.check_permission base_path ~agent_name:"test-agent"
           ~token:(Some report.bearer_token)
           ~permission:Masc_domain.CanInit
       with
       | Ok () -> fail "worker login token must not have admin permission"
       | Error (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _)) -> ()
       | Error err ->
           failf "expected forbidden for worker admin action: %s"
             (Masc_domain.masc_error_to_string err));
      (match
         Auth.resolve_role base_path ~agent_name:"test-agent"
           ~token:(Some report.bearer_token)
       with
       | Ok Masc_domain.Worker -> ()
       | Ok role ->
           failf "expected worker effective role, got %s"
             (Masc_domain.agent_role_to_string role)
       | Error err ->
           failf "expected worker effective role: %s"
             (Masc_domain.masc_error_to_string err));
      let shell = Auth_login.render_shell report in
      check bool "shell exports caller-named env var" true
        (contains_substring ~needle:"export MASC_TOKEN="
           shell);
      let json = Auth_login.to_yojson report in
      check string "json status" "ok"
        (Yojson.Safe.Util.member "status" json
        |> Yojson.Safe.Util.to_string)

(* Long_lived path: caller passes an arbitrary env var name and
   asks for a no-expiry credential. The server passes the name
   through verbatim and stores a credential with expires_at=None.
   The choice is the caller's — there is no agent-name match. *)
let test_login_long_lived_passes_env_var_through () =
  with_temp_dir "auth-login-long-lived" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"long-lived-daemon" ~role:Masc_domain.Worker
      ~token_env_var:"CUSTOM_MCP_TOKEN"
      ~token_lifetime:Auth_login.Long_lived ()
  with
  | Error err ->
      failf "long-lived login mint failed: %s"
        (Masc_domain.masc_error_to_string err)
  | Ok report ->
      check string "agent" "long-lived-daemon" report.agent_name;
      check string "client env passthrough" "CUSTOM_MCP_TOKEN"
        report.mcp_token_env_var;
      check string "long-lived dashboard URL carries no bearer"
        "http://127.0.0.1:8935/dashboard?agent=long-lived-daemon"
        report.dashboard_url;
      check bool "long-lived dashboard URL excludes bearer token" false
        (contains_substring ~needle:report.bearer_token report.dashboard_url);
      (match
         Auth.find_credential_by_token base_path
           ~token:report.bearer_token
       with
       | Ok cred ->
           check (option string) "long-lived token has no expires_at"
             None cred.expires_at
       | Error err ->
           failf "minted long-lived token did not verify: %s"
             (Masc_domain.masc_error_to_string err));
      let shell = Auth_login.render_shell report in
      check bool "shell exports caller-named env var" true
        (contains_substring ~needle:"export CUSTOM_MCP_TOKEN="
           shell);
      let json = Auth_login.to_yojson report in
      check string "json client env passthrough" "CUSTOM_MCP_TOKEN"
        (Yojson.Safe.Util.member "mcp_client" json
         |> Yojson.Safe.Util.member "token_env_var"
         |> Yojson.Safe.Util.to_string)

let () =
  run "auth_login"
    [
      ( "login",
        [
          test_case "with-expiry honors caller env var" `Quick
            test_login_with_expiry_uses_caller_env_var;
          test_case "long-lived honors caller env var + no expires_at"
            `Quick test_login_long_lived_passes_env_var_through;
        ] );
    ]
