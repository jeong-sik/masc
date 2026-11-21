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
    "XDG_CACHE_HOME"; "XDG_RUNTIME_DIR"; "BROWSER"] in
  let previous = List.map (fun name -> name, Sys.getenv_opt name) names in
  Fun.protect ~finally:(fun () ->
    List.iter (fun (name, value) -> restore name value) previous;
    Fs_compat.remove_tree root) (fun () ->
      List.iter (fun name -> Unix.putenv name "ambient-fixture") names;
      Unix.putenv "XDG_CONFIG_HOME" root;
      Eio_main.run (fun env -> run root env))

let values env key =
  Array.to_list env |> List.filter_map (fun entry ->
    match String.index_opt entry '=' with
    | Some offset when String.equal key (String.sub entry 0 offset) ->
      Some (String.sub entry (offset + 1) (String.length entry - offset - 1))
    | Some _ | None -> None)

let value env key = List.nth_opt (values env key) 0

(* The sign-in a terminal of this machine starts. *)
(* The login of a sign-in that a terminal of this machine starts. *)
let at_this_machine = Login.prepare ~browser:Login.host_browser

let isolated_native_login () = fixture (fun root _ ->
  List.iter (fun (client, id, variable, argv) ->
    let login = at_this_machine ~runtime_root:root ~account_id:id ~client ~existing:None |> ok in
    let home = Login.home_dir login in
    check int "new login owns private directory" 0o700 ((Unix.stat home).st_perm land 0o777);
    check (list string) "official login command" argv (Login.argv ~cli_path:"fixture-cli" login);
    check bool "native device or code flow uses pipes" false (Login.is_pty login);
    check bool "native login command exits itself" true (Option.is_none (Login.saved_login_check login));
    let env = Login.environment login |> ok in
    check (option string) "child selects new account" (Some home) (value env variable);
    check (option string) "ambient provider key omitted" None (value env "ANTHROPIC_API_KEY");
    check (option string) "ambient Meta key omitted" None (value env "META_API_KEY");
    check (option string) "host environment unchanged" (Some "ambient-fixture") (Sys.getenv_opt "META_API_KEY"))
    [ Login.Codex, "codex-login", "CODEX_HOME", ["fixture-cli"; "login"; "--device-auth"];
      Login.Claude, "claude-login", "CLAUDE_CONFIG_DIR", ["fixture-cli"; "auth"; "login"] ];
  check bool "path traversal rejected before allocation" true
    (Result.is_error (at_this_machine ~runtime_root:root ~account_id:"../escape"
      ~client:Login.Claude ~existing:None)))

(* Someone at another machine signs in. The server's own environment names a
   browser command here ([fixture]); the child is still handed one command,
   an executable file at an absolute path, in place of the browser of this
   machine. The sign-in a terminal of this machine starts is not handed it. *)
let a_remote_sign_in_is_handed_no_browser_of_this_machine () = fixture (fun root _ ->
  let browser = Login.no_host_browser () |> ok in
  let command = match Login.browser_command browser with
    | Some command -> command
    | None -> fail "a remote sign-in is handed no command" in
  check bool "the command is spelled from the root" false (Filename.is_relative command);
  check bool "the command is a regular file" true ((Unix.stat command).st_kind = Unix.S_REG);
  Unix.access command [ Unix.X_OK ];
  check (option string) "a sign-in at this machine is handed none" None
    (Login.browser_command Login.host_browser);
  List.iter (fun (client, id) ->
    let remote =
      Login.prepare ~browser ~runtime_root:root ~account_id:(id ^ "-remote") ~client
        ~existing:None |> ok in
    check (list string) "the child is handed that command once" [ command ]
      (values (Login.environment remote |> ok) "BROWSER");
    let local =
      at_this_machine ~runtime_root:root ~account_id:(id ^ "-local") ~client ~existing:None
      |> ok in
    check bool "a sign-in at this machine is not handed that command" false
      (List.mem command (values (Login.environment local |> ok) "BROWSER")))
    [ Login.Codex, "codex"; Login.Claude, "claude" ])

(* The command is the [true] an absolute directory of PATH holds. A machine
   that has none has nothing to hand over, and the answer needs no login: a
   login is prepared only with it, so a refusal leaves no home behind. *)
let the_browser_command_comes_from_path_or_the_sign_in_is_refused () = fixture (fun root _ ->
  let asked path =
    Login.no_host_browser
      ~getenv:(fun name -> if String.equal name "PATH" then path else None) () in
  let tools = Filename.concat root "tools" in
  Unix.mkdir tools 0o700;
  check bool "no PATH" true (Result.is_error (asked None));
  check bool "a directory that holds none" true (Result.is_error (asked (Some tools)));
  let utility = Filename.concat tools "true" in
  Out_channel.with_open_bin utility (fun out -> output_string out "#!/bin/sh\n");
  Unix.chmod utility 0o700;
  check (option string) "the one a directory of PATH holds" (Some utility)
    (Login.browser_command (asked (Some tools) |> ok)))

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
    let login = at_this_machine ~runtime_root:root ~account_id:integration_id ~client ~existing:None |> ok in
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
      {|{"oauthAccount":{"emailAddress":"claude@example.com"}}|}, "claude@example.com" ])

let claude_reference_spelling () = fixture (fun root _ ->
  let home = Filename.concat root "claude-home" in Unix.mkdir home 0o700;
  let selected = Filename.concat root "claude-selected" in Unix.symlink home selected;
  let reference = Accounts.register_home ~workspace:root ~integration_id:"claude-code"
    ~cli_path:"claude" ~account_home:selected |> account_ok in
  let binding = Accounts.resolve ~workspace:root ~integration_id:"claude-code"
    ~cli_path:"claude" reference |> account_ok in
  let login = at_this_machine ~runtime_root:root ~account_id:"reauth"
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
    let login = at_this_machine ~runtime_root:root ~account_id:id ~client ~existing:None |> ok in
    Login.observe ~mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env)
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / root) ~cli_path
      ~account_request:Runtime_account_access.Operator_call login in
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

(* Plan D1-6a: the home a new login made is found again by its id, and an id
   with no home, or an Antigravity login, finds none. *)
let a_new_logins_home_is_found_again () = fixture (fun root _ ->
  let login = at_this_machine ~runtime_root:root ~account_id:"acct-1" ~client:Login.Claude ~existing:None |> ok in
  check (result string string) "the same home" (Ok (Login.home_dir login))
    (Login.account_home ~runtime_root:root ~account_id:"acct-1" ~client:Login.Claude);
  check bool "no home for another id" true
    (Result.is_error (Login.account_home ~runtime_root:root ~account_id:"acct-2" ~client:Login.Claude));
  check bool "none for Antigravity" true
    (Result.is_error (Login.account_home ~runtime_root:root ~account_id:"acct-1" ~client:Login.Antigravity)))

let antigravity_reauthentication_starts_without_a_login () = fixture (fun root env ->
  let (_ : Runtime_account_access.host_account) =
    Masc_test_deps.host_account Runtime_account_access.Antigravity in
  let credential_file = Filename.concat root "selected-oauth" in
  let contents = Masc_test_deps.antigravity_oauth_fixture "selected-account" in
  Auth.save_private_text_file credential_file contents;
  let reference, _ = Accounts.create ~workspace:root ~integration_id:"antigravity" ~cli_path:"agy"
    ~import:(fun ~base_path:_ -> Ok {Accounts.credential_file; timeout_s=123.; catalog=`Null})
    |> account_ok in
  let existing = Accounts.resolve ~workspace:root ~integration_id:"antigravity" ~cli_path:"agy" reference
    |> account_ok in
  let login = at_this_machine ~runtime_root:root ~account_id:"reauthentication"
    ~client:Login.Antigravity ~existing:(Some existing) |> ok in
  check string "selected credential is unchanged" contents (Fs_compat.load_file credential_file);
  let check_saved = match Login.saved_login_check login with
    | Some check -> check | None -> fail "interactive login needs a completion observation" in
  check (result bool string) "old credentials cannot skip authentication" (Ok false) (check_saved ());
  let destination = Filename.concat (Login.home_dir login) ".gemini/antigravity-cli/antigravity-oauth-token" in
  Auth.save_private_text_file destination "{";
  check (result bool string) "an unfinished login does not kill its writer" (Ok false) (check_saved ());
  let continued = ref false in
  let module Session = Runtime_setup_login_session in
  let session_result = Eio.Time.with_timeout (Eio.Stdenv.clock env) 10. (fun () ->
    Ok (Session.with_session ~workspace:root ~actor:(Session.Agent "operator")
    ~account_key:(Login.home_dir login) (fun session ->
      Session.run ~saved_login:check_saved session ~env:(env :> Eio_unix.Stdenv.base)
        ~child_env:(Login.environment login |> ok) ~cwd:(Login.home_dir login)
        ~argv:["python3"; "-c";
          "import os,sys,time\npath,login=sys.argv[1:]\n"
          ^ "with open(path,'w') as f: f.write('{')\nprint('writing',flush=True)\n"
          ^ "sys.stdin.readline()\nwith open(path,'w') as f: f.write(login)\n"
          ^ "while True: time.sleep(1)\n";
          destination; contents]
        ~terminal:true ~is_closed:(fun () -> false) ~on_ready:(fun () -> ())
        ~on_input_ready:(fun () -> ()) ~on_output:(fun _ ->
          if not !continued then (
            continued := true;
            match Session.submit ~workspace:root ~actor:(Session.Agent "operator")
              ~login_id:(Session.id session) (Session.Text "finish-sign-in") with
            | Ok () -> () | Error error -> fail (Session.error_message error)))))) in
  (match session_result with
   | Ok (Ok ()) -> ()
   | Ok (Error error) -> fail (Session.error_message error)
   | Error `Timeout -> fail "saved login did not stop the interactive client");
  check bool "the partial credential's producer continued" true !continued;
  check (result bool string) "newly saved login ends authentication" (Ok true) (check_saved ());
  check string "observation preserves the client's login" contents (Fs_compat.load_file destination))

let () = run "official login adapters" ["selected accounts", [
  test_case "Antigravity reauthentication has no prior login" `Quick antigravity_reauthentication_starts_without_a_login;
  test_case "native login isolation" `Quick isolated_native_login;
  test_case "a remote sign-in is handed no browser of this machine" `Quick
    a_remote_sign_in_is_handed_no_browser_of_this_machine;
  test_case "the browser command comes from PATH or the sign-in is refused" `Quick
    the_browser_command_comes_from_path_or_the_sign_in_is_refused;
  test_case "a login's email reaches the provider saved from it" `Quick login_email_reaches_the_saved_provider;
  test_case "native authentication without model calls" `Quick native_authentication_observation;
  test_case "Claude reauthentication identity" `Quick claude_reference_spelling;
  test_case "a new login's home is found again" `Quick a_new_logins_home_is_found_again]]
