open Alcotest
open Masc
module Accounts = Runtime_setup_accounts

let get = function Ok value -> value | Error error -> fail (Accounts.error_message error)
let write path contents = Auth.save_private_text_file path contents
let fixture f =
  let directory = Filename.temp_file "setup-account-reference" "" in
  Unix.unlink directory; Unix.mkdir directory 0o700;
  let previous = Sys.getenv_opt "XDG_CONFIG_HOME" in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "XDG_CONFIG_HOME" (Option.value previous ~default:"");
    Fs_compat.remove_tree directory) (fun () ->
      Unix.putenv "XDG_CONFIG_HOME" directory;
      let workspace = Filename.concat directory "workspace" in
      Unix.mkdir workspace 0o700;
      Eio_main.run (fun _ -> f directory workspace))

let import ~base_path =
  let runtime_root=Common.masc_dir_from_base_path ~base_path in
  check int "native account requires private runtime root" 0o700 ((Unix.stat runtime_root).st_perm land 0o777);
  let credential_file = Filename.concat base_path "account.json" in
  write credential_file "fixture-selected-account";
  Ok {Accounts.credential_file; timeout_s=123.5; catalog=`Assoc ["models",`List []]}
let create workspace = Accounts.create ~workspace ~integration_id:"antigravity" ~cli_path:"agy" ~import |> get
let credential_file = function
  | Accounts.Antigravity_account account -> account.credential_file
  | Native_home _ -> fail "expected Antigravity account"
let resolve workspace reference = Accounts.resolve ~workspace ~integration_id:"antigravity" ~cli_path:"agy" reference

let persisted_scope () = fixture (fun directory workspace ->
  let reference,_ = create workspace in
  let serialized = Accounts.reference_to_string reference in
  check bool "opaque reference has no path" true (Auth.is_generated_token_shape serialized);
  let restored = Accounts.reference_of_string serialized |> get in
  let binding = resolve workspace restored |> get in
  check string "selected credential retained" "fixture-selected-account"
    (In_channel.with_open_bin (credential_file binding) In_channel.input_all);
  check int "private credential" 0o600 ((Unix.stat (credential_file binding)).st_perm land 0o777);
  let other = Filename.concat directory "other" in Unix.mkdir other 0o700;
  (match resolve other restored with Error Scope_mismatch -> () | _ -> fail "cross-workspace reference accepted");
  (match Accounts.resolve ~workspace ~integration_id:"other" ~cli_path:"agy" restored with
   | Error Scope_mismatch -> () | _ -> fail "cross-integration reference accepted");
  (match Accounts.resolve ~workspace ~integration_id:"antigravity" ~cli_path:"different-cli" restored with
   | Error Scope_mismatch -> () | _ -> fail "cross-CLI reference accepted");
  Unix.rmdir workspace; Unix.mkdir workspace 0o700;
  check bool "owner restart does not require in-memory account state" true (Result.is_ok (resolve workspace restored));
  let relocated = Filename.concat directory "relocated" in Unix.rename workspace relocated;
  (match resolve relocated restored with Error Scope_mismatch -> () | _ -> fail "relocation must request explicit import");
  check bool "saved global credential survives relocation" true (Sys.file_exists (credential_file binding)))

let private_manifest () = fixture (fun _ workspace ->
  let reference,_ = create workspace in
  let binding = resolve workspace reference |> get in
  let manifest = Filename.concat (Filename.dirname (credential_file binding)) "reference.json" in
  Unix.chmod manifest 0o644;
  (match resolve workspace reference with Error Private_storage_unavailable -> () | _ -> fail "public manifest accepted");
  Unix.chmod manifest 0o600;
  Unix.chmod (credential_file binding) 0o644;
  (match resolve workspace reference with Error Private_storage_unavailable -> () | _ -> fail "public OAuth file accepted");
  (match Accounts.reference_of_string "../account" with Error Invalid_reference -> () | _ -> fail "path reference accepted"))

let failed_import_cleanup () = fixture (fun directory workspace ->
  let source = Filename.concat directory "source-account.json" in write source "source-fixture";
  let allocated = ref None in
  let import ~base_path =
    allocated := Some base_path;
    Ok {Accounts.credential_file=source; timeout_s=30.; catalog=`Null} in
  (match Accounts.create ~workspace ~integration_id:"antigravity" ~cli_path:"agy" ~import with
   | Error Import_failed -> () | _ -> fail "source account outside managed home accepted");
  check string "source account unchanged" "source-fixture" (In_channel.with_open_bin source In_channel.input_all);
  check bool "failed import directory removed" false (Sys.file_exists (Option.get !allocated)))

let native_home_scope () = fixture (fun directory workspace ->
  let account_home = Filename.concat directory "selected-home" in
  Unix.mkdir account_home 0o700;
  let reference = Accounts.register_home ~workspace ~integration_id:"muse-code"
    ~cli_path:"muse" ~account_home |> get in
  let retried = Accounts.register_home ~workspace ~integration_id:"muse-code"
    ~cli_path:"muse" ~account_home |> get in
  check string "refresh and abandoned retry reuse one reference"
    (Accounts.reference_to_string reference) (Accounts.reference_to_string retried);
  (match Accounts.resolve ~workspace ~integration_id:"muse-code" ~cli_path:"muse" reference |> get with
   | Native_home selected -> check string "explicit selected home retained" account_home selected.account_home
   | Antigravity_account _ -> fail "native account changed transport");
  (match Accounts.resolve ~workspace ~integration_id:"codex" ~cli_path:"muse" reference with
   | Error Scope_mismatch -> () | _ -> fail "cross-client home reference accepted");
  check (list string) "reference does not write authentication or settings" []
    (Sys.readdir account_home |> Array.to_list);
  let other = Accounts.register_home ~workspace ~integration_id:"codex"
    ~cli_path:"codex" ~account_home |> get in
  check bool "different scopes retain independent references" false
    (Accounts.reference_to_string reference = Accounts.reference_to_string other);
  check bool "another selection leaves the original usable" true
    (Result.is_ok (Accounts.resolve ~workspace ~integration_id:"muse-code" ~cli_path:"muse" reference));
  check bool "registration preserves the selected account" true (Sys.is_directory account_home))

let native_home_revalidated () = fixture (fun directory workspace ->
  let account_home = Filename.concat directory "selected-home" in
  Unix.mkdir account_home 0o700;
  let reference = Accounts.register_home ~workspace ~integration_id:"muse-code"
    ~cli_path:"muse" ~account_home |> get in
  let resolve () = Accounts.resolve ~workspace ~integration_id:"muse-code"
    ~cli_path:"muse" reference in
  Unix.rmdir account_home;
  check bool "deleted account cannot resolve" true (Result.is_error (resolve ()));
  write account_home "replacement file";
  check bool "file replacement cannot resolve" true (Result.is_error (resolve ()));
  Unix.unlink account_home;
  Unix.symlink "/" account_home;
  if (Unix.stat "/").st_uid <> Unix.geteuid () then
    check bool "foreign-owned symlink target cannot resolve" true (Result.is_error (resolve ()));
  Unix.unlink account_home;
  Unix.mkdir account_home 0o700;
  check bool "owned directory remains usable" true (Result.is_ok (resolve ())))

module Email = Runtime_account_email

let email_of = function
  | Ok email -> Email.to_string email
  | Error missing -> fail (Email.missing_to_string missing)
let missing = function
  | Ok email -> fail ("unexpected email " ^ Email.to_string email)
  | Error missing -> missing
let id_token claims =
  let segment text = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet text in
  segment {|{"alg":"none"}|} ^ "." ^ segment claims ^ ".fixture-signature"

(* Each client's own login file shape, written as the client writes it.
   Synthetic values only. *)
let client_login_files () =
  check string "Codex auth.json OpenID email" "codex@example.com"
    (email_of (Email.of_codex_auth (Printf.sprintf {|{"auth_mode":"chatgpt","tokens":{"id_token":%S,"access_token":"a"}}|}
       (id_token {|{"sub":"s","email":"codex@example.com"}|}))));
  check bool "Codex API-key login reports no email" true
    (missing (Email.of_codex_auth {|{"auth_mode":"apikey","OPENAI_API_KEY":"k","tokens":null}|}) = Email.Not_reported);
  check string "Claude Code account file email" "claude@example.com"
    (email_of (Email.of_claude_account {|{"userID":"u","oauthAccount":{"accountUuid":"a","emailAddress":"claude@example.com"}}|}));
  check bool "Claude Code without an OAuth account reports no email" true
    (missing (Email.of_claude_account {|{"userID":"u"}|}) = Email.Not_reported);
  check string "Muse auth document email" "muse@example.com"
    (email_of (Email.of_muse_auth {|{"schema_version":1,"providers":{"meta":{"mechanism":"oauth","user_email":"muse@example.com"}}}|}));
  check string "Antigravity OAuth OpenID email" "google@example.com"
    (email_of (Email.of_google_oauth (Printf.sprintf {|{"token":{"access_token":"a"},"auth_method":"oauth","id_token":%S}|}
       (id_token {|{"iss":"https://accounts.google.com","sub":"s","email":"google@example.com"}|}))));
  check bool "a key given twice is not guessed" true
    (missing (Email.of_claude_account {|{"oauthAccount":{"emailAddress":"a@example.com","emailAddress":"b@example.com"}}|})
     = Email.Source_unrecognized);
  check bool "control characters are not displayable email" true
    (missing (Email.of_claude_account "{\"oauthAccount\":{\"emailAddress\":\"a@example.com\\u001b[2J\"}}") = Email.Invalid_email);
  check bool "a token that is not three segments is unrecognized" true
    (missing (Email.of_google_oauth {|{"id_token":"not-a-token"}|}) = Email.Source_unrecognized);
  check bool "unparseable bytes are unrecognized" true (missing (Email.of_muse_auth "{") = Email.Source_unrecognized)

let inventory_config ~account_home ~oauth_file =
  match Runtime_toml.parse_string (Printf.sprintf {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000

[stub-http.stub-model]

[providers.claude-selected]
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true
account-home = %S

[providers.claude-inherited]
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude-selected."claude-sonnet-5"]

[claude-inherited."claude-sonnet-5"]

[providers.agy]
protocol = "antigravity-cli"
command = "/usr/bin/true"
is-non-interactive = true
timeout-s = 10.0
credentials = { type = "file", path = %S }

[models.gemini]
api-name = "gemini-fixture"
max-context = 128000

[agy.gemini]
|} account_home oauth_file) with
  | Ok config -> config
  | Error errors ->
    fail (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))

let inventory_rows config =
  match Email.inventory_json config with
  | `List rows -> List.map (fun row -> match row with
      | `Assoc fields -> (match List.assoc_opt "integration_id" fields with
        | Some (`String id) -> id, Yojson.Safe.to_string row
        | _ -> fail "row without integration_id")
      | _ -> fail "row is not an object") rows |> List.sort compare
  | _ -> fail "account emails are not a list"

let with_env bindings f =
  let set name = function Some value -> Unix.putenv name value | None -> Unix.unsetenv name in
  let previous = List.map (fun (name, _) -> name, Sys.getenv_opt name) bindings in
  Fun.protect ~finally:(fun () -> List.iter (fun (name, value) -> set name value) previous)
    (fun () -> List.iter (fun (name, value) -> set name value) bindings; f ())

(* Each account's email is read from its client's login file when the
   inventory is built, inherited homes included, so a sign-in made after setup
   shows at once. Synthetic values only. A test executable may not write under
   HOME, so every file is written while the real HOME is set, and the fixture
   HOME is set only around the reads. *)
let live_login_emails () = fixture (fun directory _ ->
  let home = Filename.concat directory "home" in
  let account_home = Filename.concat directory "claude-home" in
  let elsewhere = Filename.concat directory "elsewhere" in
  List.iter (fun path -> Unix.mkdir path 0o700) [home; account_home; elsewhere];
  let oauth_file = Filename.concat directory "agy-oauth.json" in
  let config = inventory_config ~account_home ~oauth_file in
  let inherited id api_format = match Runtime_schema.provider_of_id config "claude-inherited" with
    | Some provider -> { provider with Runtime_schema.id; api_format }
    | None -> fail "claude-inherited is declared" in
  let config = { config with Runtime_schema.providers = config.providers @
    [ inherited "codex-inherited" Runtime_schema.Codex_app_server_runtime;
      inherited "muse-inherited" Runtime_schema.Muse_serve_runtime ] } in
  let write_in parent relative contents =
    let path = List.fold_left Filename.concat parent relative in
    Fs_compat.mkdir_p (Filename.dirname path);
    write path contents in
  let claude address = Printf.sprintf {|{"oauthAccount":{"emailAddress":%S}}|} address in
  let codex address = Printf.sprintf {|{"auth_mode":"chatgpt","tokens":{"id_token":%S}}|}
      (id_token (Printf.sprintf {|{"sub":"s","email":%S}|} address)) in
  let muse address = Printf.sprintf {|{"schema_version":1,"providers":{"meta":{"user_email":%S}}}|} address in
  let row id state = id, Printf.sprintf {|{"integration_id":%S,%s}|} id state in
  let read id address = row id (Printf.sprintf {|"state":"read","email":%S|} address) in
  let unavailable id = row id {|"state":"not_read","cause":"source_unavailable"|} in
  (* The environment around every read holds none of the credentials Claude
     Code uses before its /login account, unless a check names one. *)
  let rows_under env =
    let unset =
      List.filter_map
        (fun name -> if List.mem_assoc name env then None else Some (name, None))
        Runtime_claude_code.environment_credential_names in
    with_env (env @ unset) (fun () -> inventory_rows config) in
  let inherited_env = ["HOME", Some home; "CODEX_HOME", None; "CLAUDE_CONFIG_DIR", None] in
  check (list (pair string string)) "a missing login file says so for every account, HTTP providers have none"
    [ unavailable "agy"; unavailable "claude-inherited"; unavailable "claude-selected";
      unavailable "codex-inherited"; unavailable "muse-inherited" ]
    (rows_under inherited_env);
  write oauth_file (Printf.sprintf {|{"token":{"access_token":"a"},"id_token":%S}|}
    (id_token {|{"sub":"s","email":"google@example.com"}|}));
  write_in account_home [".claude.json"] (claude "selected@example.com");
  (* Claude Code keeps the inherited account in HOME/.claude.json. The
     HOME/.claude directory is its config directory, and a .claude.json there
     is not it. *)
  write_in home [".claude.json"] (claude "inherited@example.com");
  write_in home [".claude"; ".claude.json"] (claude "config-dir@example.com");
  write_in home [".codex"; "auth.json"] (codex "codex-default@example.com");
  (* The fixture's XDG_CONFIG_HOME is [directory]. *)
  write_in directory ["muse"; "auth.json"] (muse "muse@example.com");
  check (list (pair string string)) "each account's own login file names it"
    [ read "agy" "google@example.com"; read "claude-inherited" "inherited@example.com";
      read "claude-selected" "selected@example.com"; read "codex-inherited" "codex-default@example.com";
      read "muse-inherited" "muse@example.com" ]
    (rows_under inherited_env);
  write_in account_home [".claude.json"] (claude "relogin@example.com");
  check (option string) "a sign-in made outside setup shows at once"
    (Some (snd (read "claude-selected" "relogin@example.com")))
    (List.assoc_opt "claude-selected" (rows_under inherited_env));
  let environment_credential = snd (row "claude-inherited" {|"state":"not_read","cause":"environment_credential"|}) in
  check (list (option string)) "an inherited API key is not the login file's account; a selected home never gets it"
    [ Some environment_credential; Some (snd (read "claude-selected" "relogin@example.com")) ]
    (let rows = rows_under (inherited_env @ ["ANTHROPIC_API_KEY", Some "fixture-key"]) in
     [ List.assoc_opt "claude-inherited" rows; List.assoc_opt "claude-selected" rows ]);
  (* Claude Code reads a provider switch as on only for 1, true, yes or on. *)
  List.iter (fun (name, extra, expected) ->
    check (option string) name (Some expected)
      (List.assoc_opt "claude-inherited" (rows_under (inherited_env @ extra))))
    [ "a switch set to 0 is off", ["CLAUDE_CODE_USE_BEDROCK", Some "0"], snd (read "claude-inherited" "inherited@example.com");
      "a switch set to True is on", ["CLAUDE_CODE_USE_VERTEX", Some " True "], environment_credential;
      "an empty API key is no credential", ["ANTHROPIC_API_KEY", Some ""], snd (read "claude-inherited" "inherited@example.com") ];
  (* A FIFO where the login file should be is not opened: opening it would
     block the reading thread until something wrote to it. *)
  let selected_file = Filename.concat account_home ".claude.json" in
  Unix.unlink selected_file;
  Unix.mkfifo selected_file 0o600;
  check (option string) "a login file that is not a regular file is unavailable"
    (Some (snd (unavailable "claude-selected")))
    (List.assoc_opt "claude-selected" (rows_under inherited_env));
  Unix.unlink selected_file;
  write_in elsewhere [".claude.json"] (claude "claude-dir@example.com");
  write_in elsewhere ["auth.json"] (codex "codex-dir@example.com");
  let rows = rows_under ["HOME", Some home; "CODEX_HOME", Some elsewhere; "CLAUDE_CONFIG_DIR", Some elsewhere] in
  check (list (option string)) "an inherited CLAUDE_CONFIG_DIR or CODEX_HOME is where the client looks"
    [ Some (snd (read "claude-inherited" "claude-dir@example.com"));
      Some (snd (read "codex-inherited" "codex-dir@example.com")) ]
    [ List.assoc_opt "claude-inherited" rows; List.assoc_opt "codex-inherited" rows ];
  (* Claude Code reads the legacy .config.json in its config directory while it
     exists. *)
  write_in elsewhere [".config.json"] (claude "legacy@example.com");
  check (option string) "a legacy config file comes first"
    (Some (snd (read "claude-inherited" "legacy@example.com")))
    (List.assoc_opt "claude-inherited"
       (rows_under ["HOME", Some home; "CODEX_HOME", None; "CLAUDE_CONFIG_DIR", Some elsewhere]));
  write_in home [".config"; "muse"; "auth.json"] (muse "home-muse@example.com");
  let rows = rows_under ["HOME", Some home; "CODEX_HOME", None; "CLAUDE_CONFIG_DIR", Some "";
                         "XDG_CONFIG_HOME", None] in
  check (list (option string)) "an empty CLAUDE_CONFIG_DIR is unset, and Muse falls back to HOME/.config"
    [ Some (snd (read "claude-inherited" "inherited@example.com"));
      Some (snd (read "muse-inherited" "home-muse@example.com")) ]
    [ List.assoc_opt "claude-inherited" rows; List.assoc_opt "muse-inherited" rows ])

let email_batch_provider ~home id =
  let config = inventory_config ~account_home:home ~oauth_file:(Filename.concat home "oauth.json") in
  match Runtime_schema.provider_of_id config "claude-selected" with
  | Some provider -> {provider with Runtime_schema.id}
  | None -> fail "selected account missing"

let email_batch_addresses observations =
  List.map (fun (observation : Email.observation) -> observation.integration_id, email_of observation.email) observations

let shared_login_observation_and_rotation () = fixture (fun directory _ ->
  let home = Filename.concat directory "shared-login" in
  Unix.mkdir home 0o700;
  let path = Filename.concat home ".claude.json" in
  let login email = Printf.sprintf {|{"oauthAccount":{"emailAddress":%S}}|} email in
  write path (login "before@example.com");
  let providers = List.map (email_batch_provider ~home) ["first";"second"] in
  let calls = ref 0 in
  let read source =
    incr calls;
    let observed = Email.read_source source in
    write path (login "after@example.com");
    observed in
  let observations = Email.observe_providers ~read providers in
  check int "one selected login read in a shared response" 1 !calls;
  check (list (pair string string)) "aliases keep separate rows from the same observation"
    ["first","before@example.com";"second","before@example.com"] (email_batch_addresses observations);
  let observations = Email.observe_providers ~read providers in
  check int "next response rereads the selected source" 2 !calls;
  check (list (pair string string)) "rotation is visible on the next observation"
    ["first","after@example.com";"second","after@example.com"] (email_batch_addresses observations);
  match Email.providers_json providers with
  | `List rows -> check int "public inventory keeps both integration rows" 2 (List.length rows)
  | _ -> fail "public inventory is not a row list")

let failed_login_sharing_and_independent_sources () = fixture (fun directory _ ->
  let home = Filename.concat directory "malformed-login" in
  let other = Filename.concat directory "unavailable-login" in
  List.iter (fun path -> Unix.mkdir path 0o700) [home;other];
  write (Filename.concat home ".claude.json") "{";
  let first = email_batch_provider ~home "first" in
  let second = {first with Runtime_schema.id="second"} in
  let unavailable = {first with Runtime_schema.id="unavailable"; account_home=Some other} in
  let inherited = {first with Runtime_schema.id="inherited"; account_home=None} in
  let http = {first with Runtime_schema.id="http"; api_format=Messages_api; credentials=None} in
  with_env ["ANTHROPIC_API_KEY",Some "synthetic-env-credential"] (fun () ->
    let calls = ref 0 in
    let read source = incr calls; Email.read_source source in
    let observations = Email.observe_providers ~read [first;second;unavailable;inherited;http] in
    let gap id = match List.find_opt (fun (row : Email.observation) -> row.integration_id=id) observations with
      | Some row -> missing row.email | None -> fail (id ^ " missing from observations") in
    check int "failed shared file and another file remain two observations" 2 !calls;
    check int "environment refusal remains a row, HTTP has no account row" 4 (List.length observations);
    check bool "malformed shared source remains unavailable for both aliases" true
      (gap "first" = Email.Source_unrecognized && gap "second" = Email.Source_unrecognized);
    check bool "another unavailable source does not become the shared error" true
      (gap "unavailable" = Email.Source_unavailable);
    check bool "environment credential bypasses login-file reader" true
      (gap "inherited" = Email.Environment_credential);
    write (Filename.concat home ".claude.json") {|{"oauthAccount":{"emailAddress":"recovered@example.com"}}|};
    let recovered = Email.observe_providers ~read [first;second] in
    check int "failed observation is not sticky across responses" 3 !calls;
    check (list (pair string string)) "both aliases observe the repaired source"
      ["first","recovered@example.com";"second","recovered@example.com"] (email_batch_addresses recovered)))

let same_path_client_interpretations_remain_separate () = fixture (fun directory _ ->
  let home = Filename.concat directory "dual-format-login" in
  Unix.mkdir home 0o700;
  let path = Runtime_verification_codex_home.auth_path ~codex_home:home in
  write path (Printf.sprintf {|{"tokens":{"id_token":%S},"id_token":%S}|}
    (id_token {|{"email":"codex@example.com"}|}) (id_token {|{"email":"google@example.com"}|}));
  let base = email_batch_provider ~home "codex" in
  let codex = {base with Runtime_schema.api_format=Codex_app_server_runtime} in
  let google = {base with Runtime_schema.id="google"; api_format=Antigravity_cli_runtime;
    credentials=Some (File path); account_home=None} in
  let calls = ref 0 in
  let observations = Email.observe_providers ~read:(fun source -> incr calls; Email.read_source source) [codex;google] in
  check int "equal path with different client formats has two source observations" 2 !calls;
  check (list (pair string string)) "each client interprets its own declared login format"
    ["codex","codex@example.com";"google","google@example.com"] (email_batch_addresses observations))

let inherited_login_selection_is_frozen_before_reads () = fixture (fun directory _ ->
  let first_home = Filename.concat directory "first-codex" in
  let next_home = Filename.concat directory "next-codex" in
  List.iter (fun home -> Unix.mkdir home 0o700) [first_home;next_home];
  let login home email = write (Runtime_verification_codex_home.auth_path ~codex_home:home)
    (Printf.sprintf {|{"tokens":{"id_token":%S}}|} (id_token (Printf.sprintf {|{"email":%S}|} email))) in
  login first_home "first@example.com"; login next_home "next@example.com";
  let base = email_batch_provider ~home:first_home "first" in
  let first = {base with Runtime_schema.api_format=Codex_app_server_runtime; account_home=None} in
  let second = {first with Runtime_schema.id="second"} in
  with_env ["CODEX_HOME",Some first_home] (fun () ->
    let calls = ref 0 in
    let read source = incr calls; let result = Email.read_source source in
      Unix.putenv "CODEX_HOME" next_home; result in
    let observations = Email.observe_providers ~read [first;second] in
    check int "source selections are frozen before the first read effect" 1 !calls;
    check (list (pair string string)) "one response cannot switch an alias midway"
      ["first","first@example.com";"second","first@example.com"] (email_batch_addresses observations);
    let next = Email.observe_providers ~read [first;second] in
    check int "new response resolves the new inherited home" 2 !calls;
    check (list (pair string string)) "new selection is not cached process-wide"
      ["first","next@example.com";"second","next@example.com"] (email_batch_addresses next)))

let cancelled_login_observation_never_retries () = fixture (fun directory _ ->
  let provider = email_batch_provider ~home:directory "first" in
  let alias = {provider with Runtime_schema.id="second"} in
  let calls = ref 0 in
  let exception Observation_cancelled in
  (match Email.observe_providers ~read:(fun _ -> incr calls;
      raise (Eio.Cancel.Cancelled Observation_cancelled)) [provider;alias] with
   | _ -> fail "cancelled source became inventory rows"
   | exception Eio.Cancel.Cancelled Observation_cancelled -> ());
  check int "cancellation cannot retry the reader for an alias" 1 !calls)


let () = run "setup account references" ["private account",[
  test_case "shared login observation and later rotation" `Quick shared_login_observation_and_rotation;
  test_case "failed source sharing keeps independent sources" `Quick failed_login_sharing_and_independent_sources;
  test_case "same path keeps client interpretations separate" `Quick same_path_client_interpretations_remain_separate;
  test_case "inherited login sources freeze before read effects" `Quick inherited_login_selection_is_frozen_before_reads;
  test_case "cancelled source observation never retries an alias" `Quick cancelled_login_observation_never_retries;
  test_case "native home revalidated on resolution" `Quick native_home_revalidated;
  test_case "native home scoped reference" `Quick native_home_scope;
  test_case "persistent scoped reference" `Quick persisted_scope;
  test_case "private manifest and credential required" `Quick private_manifest;
  test_case "failed import preserves source and cleans destination" `Quick failed_import_cleanup;
  test_case "client login files report the account email" `Quick client_login_files;
  test_case "setup inventory reads every account's login file" `Quick live_login_emails]]
