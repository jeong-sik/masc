open Alcotest
open Masc_mcp

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

let test_login_enables_bearer_auth_and_prints_codex_exports () =
  with_temp_dir "auth-login" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"codex-mcp-client" ~role:Types.Worker ()
  with
  | Error err ->
      failf "login mint failed: %s" (Types.masc_error_to_string err)
  | Ok report ->
      let cfg = Auth.load_auth_config base_path in
      check bool "auth enabled" true cfg.enabled;
      check bool "require token" true cfg.require_token;
      check string "agent" "codex-mcp-client" report.agent_name;
      check string "role" "worker"
        (Types.agent_role_to_string report.role);
      check string "codex env" "MASC_MCP_TOKEN"
        report.codex_token_env_var;
      check string "client env" "MASC_MCP_TOKEN"
        report.mcp_token_env_var;
      check bool "codex login unsupported" false
        report.codex_login_supported;
      check bool "raw token file exists" true
        (Sys.file_exists report.raw_token_file);
      (match
         Auth.find_credential_by_token base_path
           ~token:report.bearer_token
       with
       | Ok cred ->
           check string "token owner" "codex-mcp-client"
             cred.agent_name
       | Error err ->
           failf "minted token did not verify: %s"
             (Types.masc_error_to_string err));
      let shell = Auth_login.render_shell report in
      check bool "shell exports mcp token" true
        (contains_substring ~needle:"export MASC_MCP_TOKEN="
           shell);
      let text = Auth_login.render_text report in
      check bool "text explains codex login" true
        (contains_substring
           ~needle:"`codex mcp login` is OAuth-only"
           text);
      let json = Auth_login.to_yojson report in
      check string "json status" "ok"
        (Yojson.Safe.Util.member "status" json
        |> Yojson.Safe.Util.to_string)

let test_login_prints_claude_client_env () =
  with_temp_dir "auth-login-claude" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"claude" ~role:Types.Worker ()
  with
  | Error err ->
      failf "login mint failed: %s" (Types.masc_error_to_string err)
  | Ok report ->
      check string "agent" "claude" report.agent_name;
      check string "client env" "MASC_CLAUDE_MCP_TOKEN"
        report.mcp_token_env_var;
      check string "codex env remains pinned" "MASC_MCP_TOKEN"
        report.codex_token_env_var;
      let shell = Auth_login.render_shell report in
      check bool "shell exports claude token" true
        (contains_substring ~needle:"export MASC_CLAUDE_MCP_TOKEN="
           shell);
      check bool "shell does not export codex token for claude login" false
        (contains_substring ~needle:"export MASC_MCP_TOKEN=" shell);
      let json = Auth_login.to_yojson report in
      check string "json client env" "MASC_CLAUDE_MCP_TOKEN"
        (Yojson.Safe.Util.member "mcp_client" json
         |> Yojson.Safe.Util.member "token_env_var"
         |> Yojson.Safe.Util.to_string)

let () =
  run "auth_login"
    [
      ( "login",
        [
          test_case "enables bearer auth and prints Codex exports" `Quick
            test_login_enables_bearer_auth_and_prints_codex_exports;
          test_case "prints Claude client env" `Quick
            test_login_prints_claude_client_env;
        ] );
    ]
