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

(* runtime.toml as setup saves it from a reference: the provider's
   account-home is the reference's path. *)
let saved_provider account_home =
  match Runtime_toml.parse_string (Printf.sprintf {|
[runtime]
default = "claude-code.claude-sonnet-5"

[providers.claude-code]
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true
account-home = %S

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude-code."claude-sonnet-5"]
|} account_home) with
  | Ok { Runtime_schema.providers = [ provider ]; _ } -> provider
  | Ok _ -> fail "expected one provider"
  | Error errors ->
    fail (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))

(* A provider setup saves from a login's reference runs on the home that login
   signed in to, so its email is read from the file the client wrote there.
   These are the server's calls, in its order. *)
let login_email_reaches_the_saved_provider () = fixture (fun root _ ->
  let id_token claims =
    let segment text = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet text in
    segment {|{"alg":"none"}|} ^ "." ^ segment claims ^ ".fixture-signature" in
  let workspace = root and cli_path = "fixture-cli" in
  List.iter (fun (client, integration_id, api_format, relative, body, expected) ->
    let login = Login.prepare ~runtime_root:root ~account_id:integration_id ~client ~existing:None |> ok in
    let reference = Login.publish ~workspace ~integration_id ~cli_path login |> ok in
    let account_home = match Accounts.resolve ~workspace ~integration_id ~cli_path reference |> account_ok with
      | Accounts.Native_home {account_home} -> account_home
      | Accounts.Antigravity_account _ -> fail "expected a native home" in
    let provider = { (saved_provider account_home) with Runtime_schema.id = integration_id; api_format } in
    check bool "nothing is read before the client signs in" true
      (Runtime_account_email.of_provider provider = Some (Error Runtime_account_email.Source_unavailable));
    let path = Filename.concat (Login.home_dir login) relative in
    Fs_compat.mkdir_p (Filename.dirname path);
    Auth.save_private_text_file path body;
    match Runtime_account_email.of_provider provider with
    | Some (Ok email) -> check string "the saved provider reads the login's own file" expected
                           (Runtime_account_email.to_string email)
    | Some (Error missing) -> fail (Runtime_account_email.missing_to_string missing)
    | None -> fail "a native provider runs on an account")
    [ Login.Codex, "codex-email", Runtime_schema.Codex_app_server_runtime, "auth.json",
      Printf.sprintf {|{"auth_mode":"chatgpt","tokens":{"id_token":%S}}|}
        (id_token {|{"email":"codex@example.com"}|}), "codex@example.com";
      Login.Claude, "claude-email", Runtime_schema.Claude_code_runtime, ".claude.json",
      {|{"oauthAccount":{"emailAddress":"claude@example.com"}}|}, "claude@example.com";
      Login.Muse, "muse-email", Runtime_schema.Muse_serve_runtime, ".config/muse/auth.json",
      {|{"schema_version":1,"providers":{"meta":{"user_email":"muse@example.com"}}}|}, "muse@example.com" ])

let muse_capture_and_reference () = fixture (fun root env ->
  let login = Login.prepare ~runtime_root:root ~account_id:"muse-login"
    ~client:Login.Muse ~existing:None |> ok in
  let home = Login.home_dir login in
  let child_env = Login.environment login |> ok in
  check (option string) "login cannot fork a detached launcher update" (Some "1")
    (value child_env "MUSE_NO_AUTO_UPDATE");
  check (option string) "login keeps the sign-in in auth.json, not the Keychain" (Some "file")
    (value child_env "TBH_CREDENTIAL_BACKEND");
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
    {|{"schema_version":1,"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}|};
  check bool "a sign-in left in the Keychain is not login capture" true (Result.is_error (observe ()));
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
  test_case "a login's email reaches the provider saved from it" `Quick login_email_reaches_the_saved_provider;
  test_case "native authentication without model calls" `Quick native_authentication_observation;
  test_case "Muse capture and durable account selection" `Quick muse_capture_and_reference;
  test_case "Claude reauthentication identity" `Quick claude_reference_spelling]]
