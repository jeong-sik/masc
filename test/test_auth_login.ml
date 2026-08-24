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
      check (option string) "worker login creates no bootstrap admin" None
        (Auth.read_initial_admin base_path);
      check string "client env passthrough" "MASC_TOKEN"
        report.mcp_token_env_var;
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
        (String_util.string_contains_substring ~needle:"export MASC_TOKEN="
           shell);
      let json = Auth_login.to_yojson report in
      check string "json status" "ok"
        (Yojson.Safe.Util.member "status" json
        |> Yojson.Safe.Util.to_string);
      check (list string) "json login schema"
        [ "agent_name"
        ; "auth_change"
        ; "auth_config_path"
        ; "base_path"
        ; "bearer_token"
        ; "dashboard_url"
        ; "mcp_client"
        ; "mcp_url"
        ; "raw_token_file"
        ; "role"
        ; "status"
        ]
        (json
         |> Yojson.Safe.Util.to_assoc
         |> List.map fst
         |> List.sort String.compare);
      check string "json raw token file" report.raw_token_file
        (Yojson.Safe.Util.member "raw_token_file" json
         |> Yojson.Safe.Util.to_string);
      check string "json mcp url" report.mcp_url
        (Yojson.Safe.Util.member "mcp_url" json
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
        (String_util.string_contains_substring ~needle:"export CUSTOM_MCP_TOKEN="
           shell);
      let json = Auth_login.to_yojson report in
      check string "json client env passthrough" "CUSTOM_MCP_TOKEN"
        (Yojson.Safe.Util.member "mcp_client" json
         |> Yojson.Safe.Util.member "token_env_var"
         |> Yojson.Safe.Util.to_string)

let test_login_url_uses_uri_components () =
  with_temp_dir "auth-login-uri" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"::1" ~port:8935
      ~agent_name:"agent +&" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN" ~token_lifetime:Auth_login.With_expiry ()
  with
  | Error err ->
    failf "login mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
    let dashboard = Uri.of_string report.dashboard_url in
    check (option string) "IPv6 host" (Some "::1") (Uri.host dashboard);
    check (option int) "port" (Some 8935) (Uri.port dashboard);
    check string "dashboard path" "/dashboard" (Uri.path dashboard);
    check (option string) "agent query round-trip" (Some "agent +&")
      (Uri.get_query_param dashboard "agent");
    let mcp = Uri.of_string report.mcp_url in
    check (option string) "MCP IPv6 host" (Some "::1") (Uri.host mcp);
    check string "MCP path" "/mcp" (Uri.path mcp)

(* What login persists is what a local client can read back. Asserting the
   round trip rather than the path keeps the two sides free to move together
   and pinned to each other. *)
let test_persisted_token_round_trips () =
  with_temp_dir "auth-login-read" @@ fun base_path ->
  check (option string) "absent agent has no persisted token" None
    (Auth_login.read_persisted_token ~base_path ~agent_name:"masc-tui");
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"masc-tui" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:Auth_login.With_expiry ()
  with
  | Error err ->
      failf "login mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
      check (option string) "the client reads back what login wrote"
        (Some report.bearer_token)
        (Auth_login.read_persisted_token ~base_path ~agent_name:"masc-tui");
      check (option string) "another agent's file is not borrowed" None
        (Auth_login.read_persisted_token ~base_path ~agent_name:"other-agent")

let () =
  run "auth_login"
    [
      ( "login",
        [
          test_case "with-expiry honors caller env var" `Quick
            test_login_with_expiry_uses_caller_env_var;
          test_case "long-lived honors caller env var + no expires_at"
            `Quick test_login_long_lived_passes_env_var_through;
          test_case "URL uses URI components" `Quick
            test_login_url_uses_uri_components;
          test_case "persisted token round-trips" `Quick
            test_persisted_token_round_trips;
        ] );
    ]
