open Alcotest
open Masc
module Login = Runtime_setup_login_client
module Accounts = Runtime_setup_accounts

let ok = function Ok value -> value | Error detail -> fail detail
let account_ok result = result |> Result.map_error Accounts.error_message |> ok
let restore name = function Some value -> Unix.putenv name value | None -> Unix.unsetenv name
let fixture run =
  let root = Filename.temp_dir ~perms:0o700 "setup-login-client-" "" |> Unix.realpath in
  let names = ["XDG_CONFIG_HOME"; "META_API_KEY"; "ANTHROPIC_API_KEY";
    "CODEX_HOME"; "CLAUDE_CONFIG_DIR"; "XDG_DATA_HOME"; "XDG_STATE_HOME";
    "XDG_CACHE_HOME"; "XDG_RUNTIME_DIR"] in
  let previous = List.map (fun name -> name, Sys.getenv_opt name) names in
  Fun.protect ~finally:(fun () ->
    List.iter (fun (name, value) -> restore name value) previous;
    Fs_compat.remove_tree root) (fun () ->
      List.iter (fun name -> Unix.putenv name "ambient-fixture") names;
      Unix.putenv "XDG_CONFIG_HOME" root;
      Eio_main.run (fun env -> run root env))

let value env key =
  Array.to_list env |> List.find_map (fun entry ->
    match String.index_opt entry '=' with
    | Some offset when String.equal key (String.sub entry 0 offset) ->
      Some (String.sub entry (offset + 1) (String.length entry - offset - 1))
    | Some _ | None -> None)

let isolated_native_login () = fixture (fun root _ ->
  List.iter (fun (client, id, variable, argv) ->
    let login = Login.prepare ~runtime_root:root ~account_id:id ~client ~existing:None |> ok in
    let home = Login.home_dir login in
    check int "new login owns private directory" 0o700 ((Unix.stat home).st_perm land 0o777);
    check (list string) "official login command" argv (Login.argv ~cli_path:"fixture-cli" login);
    check bool "native device or code flow uses pipes" false (Login.is_pty login);
    let env = Login.environment login |> ok in
    check (option string) "child selects new account" (Some home) (value env variable);
    check (option string) "ambient provider key omitted" None (value env "ANTHROPIC_API_KEY");
    check (option string) "ambient Meta key omitted" None (value env "META_API_KEY");
    check (option string) "host environment unchanged" (Some "ambient-fixture") (Sys.getenv_opt "META_API_KEY"))
    [ Login.Codex, "codex-login", "CODEX_HOME", ["fixture-cli"; "login"; "--device-auth"];
      Login.Claude, "claude-login", "CLAUDE_CONFIG_DIR", ["fixture-cli"; "auth"; "login"];
      Login.Muse, "muse-login", "HOME", ["fixture-cli"; "login"] ];
  check bool "path traversal rejected before allocation" true
    (Result.is_error (Login.prepare ~runtime_root:root ~account_id:"../escape"
      ~client:Login.Muse ~existing:None)))

let muse_capture_and_reference () = fixture (fun root env ->
  let login = Login.prepare ~runtime_root:root ~account_id:"muse-login"
    ~client:Login.Muse ~existing:None |> ok in
  let home = Login.home_dir login in
  let child_env = Login.environment login |> ok in
  check (option string) "login cannot fork a detached launcher update" (Some "1")
    (value child_env "MUSE_NO_AUTO_UPDATE");
  List.iter (fun (name, suffix) ->
    check (option string) "Muse owns every XDG root" (Some (Filename.concat home suffix))
      (value child_env name))
    ["XDG_CONFIG_HOME", ".config"; "XDG_DATA_HOME", ".local/share";
     "XDG_CACHE_HOME", ".cache"; "XDG_STATE_HOME", ".local/state";
     "XDG_RUNTIME_DIR", ".local/run"];
  check (option string) "no invented Muse auth override" None (value child_env "MUSE_AUTH_PATH");
  let observe () = Login.observe ~mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env) ~cwd:(Eio.Stdenv.fs env) ~cli_path:"unused" login in
  check bool "missing captured login is rejected" true (Result.is_error (observe ()));
  Fs_compat.mkdir_p (Filename.concat home ".config/muse");
  let auth = Filename.concat home ".config/muse/auth.json" in
  Auth.save_private_text_file auth {|{"schema_version":1,"providers":{"meta":{}}}|};
  check bool "mere credential file is not login capture" true (Result.is_error (observe ()));
  Auth.save_private_text_file auth
    {|{"schema_version":1,"providers":{"meta":{"api_key":"synthetic-selected-account"}}}|};
  (match observe () |> ok with
   | Login.Login_completed -> ()
   | Login.Authenticated | Login.Credential_captured -> fail "Muse capture claimed authentication");
  let reference = Login.publish ~workspace:root ~integration_id:"muse-code" ~cli_path:"muse" login |> ok in
  let binding = Accounts.resolve ~workspace:root ~integration_id:"muse-code" ~cli_path:"muse" reference |> account_ok in
  let again = Login.prepare ~runtime_root:root ~account_id:"retry"
    ~client:Login.Muse ~existing:(Some binding) |> ok in
  check string "explicit reauthentication selects exact same account" home (Login.home_dir again))

let claude_reference_spelling () = fixture (fun root _ ->
  let home = Filename.concat root "claude-home" in Unix.mkdir home 0o700;
  let selected = Filename.concat root "claude-selected" in Unix.symlink home selected;
  let reference = Accounts.register_home ~workspace:root ~integration_id:"claude-code"
    ~cli_path:"claude" ~account_home:selected |> account_ok in
  let binding = Accounts.resolve ~workspace:root ~integration_id:"claude-code"
    ~cli_path:"claude" reference |> account_ok in
  let login = Login.prepare ~runtime_root:root ~account_id:"reauth"
    ~client:Login.Claude ~existing:(Some binding) |> ok in
  check string "Claude keychain identity keeps configured spelling" selected (Login.home_dir login);
  check (option string) "login sees same keychain identity" (Some selected)
    (value (Login.environment login |> ok) "CLAUDE_CONFIG_DIR"))

let native_authentication_observation () = fixture (fun root env ->
  let script name body =
    let path = Filename.concat root name in
    Auth.save_private_text_file path ("#!/bin/sh\nset -eu\n" ^ body);
    Unix.chmod path 0o700;
    path in
  let emit body = "printf '%s\\n' " ^ Filename.quote body ^ "\n" in
  let observe client id cli_path =
    let login = Login.prepare ~runtime_root:root ~account_id:id ~client ~existing:None |> ok in
    Login.observe ~mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / root) ~cli_path login in
  let codex name account = script name
      ("[ \"$1\" = app-server ]\nIFS= read -r request\n"
       ^ emit {|{"id":1,"result":{"userAgent":"fixture"}}|}
       ^ "IFS= read -r notification\nIFS= read -r request\n" ^ emit account) in
  let unauthenticated = codex "provider-managed"
      {|{"id":2,"result":{"account":null,"requiresOpenaiAuth":false}}|} in
  check bool "Codex provider-managed response is not a logged-in account" true
    (Result.is_error (observe Login.Codex "codex-managed" unauthenticated));
  let authenticated = codex "codex-authenticated"
      {|{"id":2,"result":{"account":{"type":"chatgpt","planType":"pro"},"requiresOpenaiAuth":true}}|} in
  (match observe Login.Codex "codex-auth" authenticated |> ok with
   | Login.Authenticated -> ()
   | Login.Login_completed | Login.Credential_captured -> fail "native authentication lost");
  let claude = script "claude-authenticated"
      ("[ \"$#\" = 4 ]\n[ \"$1\" = --setting-sources= ]\n[ \"$2\" = auth ]\n[ \"$3\" = status ]\n[ \"$4\" = --json ]\n"
       ^ emit {|{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","apiProvider":"firstParty"}|}) in
  (match observe Login.Claude "claude-auth" claude |> ok with
   | Login.Authenticated -> ()
   | Login.Login_completed | Login.Credential_captured -> fail "native authentication lost"))

let () = run "official login adapters" ["selected accounts", [
  test_case "native login isolation" `Quick isolated_native_login;
  test_case "native authentication without model calls" `Quick native_authentication_observation;
  test_case "Muse capture and durable account selection" `Quick muse_capture_and_reference;
  test_case "Claude reauthentication identity" `Quick claude_reference_spelling]]
