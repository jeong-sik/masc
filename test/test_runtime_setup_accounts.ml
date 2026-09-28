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
  match Email.inventory_json ~lookup:Accounts.email config with
  | `List rows -> List.map (fun row -> match row with
      | `Assoc fields -> (match List.assoc_opt "integration_id" fields with
        | Some (`String id) -> id, Yojson.Safe.to_string row
        | _ -> fail "row without integration_id")
      | _ -> fail "row is not an object") rows |> List.sort compare
  | _ -> fail "account emails are not a list"

let recorded_login_email () = fixture (fun directory _ ->
  let account_home = Filename.concat directory "claude-home" in
  Unix.mkdir account_home 0o700;
  let oauth_file = Filename.concat directory "agy-oauth.json" in
  write oauth_file "{}";
  let account = Email.Native_home account_home in
  check bool "nothing is recorded before a login" true (Accounts.email account = Email.Absent);
  let email = match Email.of_claude_account {|{"oauthAccount":{"emailAddress":"operator@example.com"}}|} with
    | Ok email -> email | Error missing -> fail (Email.missing_to_string missing) in
  Accounts.set_email account (Some email) |> get;
  check bool "login email is read back" true (Accounts.email account = Email.Recorded email);
  check bool "another spelling is another account" true
    (Accounts.email (Email.Native_home (account_home ^ "/")) = Email.Absent);
  check bool "a credential file with the same text is another account" true
    (Accounts.email (Email.Credential_file account_home) = Email.Absent);
  let records = List.fold_left Filename.concat directory ["masc"; "credentials"; "setup-accounts"; "account-emails"] in
  let files = Sys.readdir records |> Array.to_list in
  check int "one record" 1 (List.length files);
  let record = Filename.concat records (List.hd files) in
  check int "record is private" 0o600 ((Unix.stat record).st_perm land 0o777);
  check (list (pair string string)) "inventory reads the record, only for selected accounts"
    [ "agy", {|{"integration_id":"agy","state":"absent"}|};
      "claude-selected", {|{"integration_id":"claude-selected","state":"recorded","email":"operator@example.com"}|} ]
    (inventory_rows (inventory_config ~account_home ~oauth_file));
  check (list string) "inventory opens no account file" [] (Sys.readdir account_home |> Array.to_list);
  let original = In_channel.with_open_bin record In_channel.input_all in
  write record (Yojson.Safe.to_string (`Assoc ["schema",`String "masc.setup_account_email.v1";
    "account_kind",`String "native_home";"account",`String "/elsewhere";"email",`String "other@example.com"]));
  check bool "a record naming another account is not shown" true (Accounts.email account = Email.Unreadable);
  write record original;
  Unix.chmod record 0o644;
  check bool "a readable-by-others record is not trusted" true (Accounts.email account = Email.Unreadable);
  Unix.chmod record 0o600;
  Accounts.set_email account None |> get;
  check bool "a later login without an email clears the old one" true (Accounts.email account = Email.Absent))

let () = run "setup account references" ["private account",[
  test_case "native home revalidated on resolution" `Quick native_home_revalidated;
  test_case "native home scoped reference" `Quick native_home_scope;
  test_case "persistent scoped reference" `Quick persisted_scope;
  test_case "private manifest and credential required" `Quick private_manifest;
  test_case "failed import preserves source and cleans destination" `Quick failed_import_cleanup;
  test_case "client login files report the account email" `Quick client_login_files;
  test_case "login email record feeds the setup inventory" `Quick recorded_login_email]]
