open Alcotest
open Masc
module A = Runtime_account_runtime

let config =
  match
    Runtime_toml.parse_string
      {|
[runtime]
default = "claude_code.claude-sonnet-5"

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true

[claude_code."claude-sonnet-5"]
|}
  with
  | Ok config -> config
  | Error _ -> fail "fixture runtime.toml refused"
;;

let of_template ?(config = config) ?(account = A.Login) ~template ~binding account_home =
  A.of_template config ~template ~provider_id:"acct-1" ~account_home ~account ~binding
;;

let outcome = function
  | Ok (runtime : Runtime_instance.t) -> "ok " ^ runtime.id
  | Error error -> A.error_to_string error
;;

(* Plan D1-6a: the runtime of a person's account is the template with its id
   and home replaced, and the template's binding of the model. *)
let the_template_with_the_persons_home () =
  let home = Filename.temp_dir ~perms:0o700 "account-runtime-" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree home)
    (fun () ->
      match of_template ~template:"claude_code" ~binding:(A.Model "claude-sonnet-5") (Some home) with
      | Error error -> fail (A.error_to_string error)
      | Ok runtime ->
        check string "the id is the account's binding" "acct-1.claude-sonnet-5" runtime.Runtime_instance.id;
        check (option string) "the home is the person's" (Some home) runtime.provider.account_home;
        check
          string
          "no template"
          (A.error_to_string (A.Template_not_declared "codex"))
          (match of_template ~template:"codex" ~binding:(A.Model "claude-sonnet-5") (Some home) with
           | Ok _ -> "ok"
           | Error error -> A.error_to_string error);
        check
          string
          "no binding of the model"
          (A.error_to_string (A.Model_not_bound { template = "claude_code"; model = "gpt-5.5" }))
          (match of_template ~template:"claude_code" ~binding:(A.Model "gpt-5.5") (Some home) with
           | Ok _ -> "ok"
           | Error error -> A.error_to_string error))
;;

(* Plan D2-8: a Keeper turn chooses the binding whose Runtime id on the
   account is the id its Keeper record names. The id the binding makes on the
   template, or on another account, chooses nothing. *)
let the_binding_of_a_runtime_id () =
  let home = Filename.temp_dir ~perms:0o700 "account-runtime-" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree home)
    (fun () ->
      let runtime runtime_id = outcome (of_template ~template:"claude_code" ~binding:(A.Runtime runtime_id) (Some home)) in
      check string "the account's Runtime" "ok acct-1.claude-sonnet-5" (runtime "acct-1.claude-sonnet-5");
      check
        string
        "the same as the model's"
        (outcome (of_template ~template:"claude_code" ~binding:(A.Model "claude-sonnet-5") (Some home)))
        (runtime "acct-1.claude-sonnet-5");
      List.iter
        (fun runtime_id ->
           check
             string
             ("no binding makes " ^ runtime_id)
             (A.error_to_string (A.Runtime_not_bound { template = "claude_code"; runtime_id }))
             (runtime runtime_id))
        [ "claude_code.claude-sonnet-5"; "acct-2.claude-sonnet-5"; "acct-1"; "acct-1.claude-sonnet" ])
;;

(* RFC a-persons-api-key-is-their-own-provider-account 3.4 and 3.5: the
   credential of the provider of an account is of the account. A key account
   takes its key file, read before any runtime is made, and a login account
   takes none, whatever the workspace declared for the template. *)
let the_credential_is_of_the_account () =
  let root = Filename.temp_dir ~perms:0o700 "account-runtime-key-" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
      let home = Filename.concat root "home" in
      Unix.mkdir home 0o700;
      let account_id =
        match Authz_types.Provider_account_id.of_string "acct-1" with
        | Ok id -> id
        | Error _ -> fail "fixture account id refused"
      in
      let generation = Authz_types.Key_generation.first in
      let key_file =
        match Runtime_account_home_layout.key_file ~runtime_root:root ~account_id ~generation with
        | Ok path -> path
        | Error detail -> fail detail
      in
      let binding = A.Model "claude-sonnet-5" in
      let code = function
        | Ok (runtime : Runtime_instance.t) -> "ok " ^ runtime.id
        | Error error -> A.error_code error
      in
      let credentials = function
        | Ok (runtime : Runtime_instance.t) -> runtime.provider.Runtime_schema.credentials
        | Error error -> fail (A.error_to_string error)
      in
      let credential = option (testable Runtime_schema.pp_credential Runtime_schema.equal_credential) in
      let on_key () = of_template ~account:(A.Key { key_file }) ~template:"claude_code" ~binding (Some home) in
      check string "a key account whose file is not there" "key_missing" (code (on_key ()));
      (match Runtime_api_key_file.key_of_string "sk-test-account-runtime" with
       | None -> fail "fixture key refused"
       | Some key ->
         (match Runtime_api_key_file.write ~runtime_root:root ~account_id ~generation key with
          | Ok () -> ()
          | Error _ -> fail "fixture key not written"));
      check
        credential
        "a key account runs on its key file"
        (Some (Runtime_schema.File key_file))
        (credentials (on_key ()));
      Unix.chmod key_file 0o640;
      check string "a key file its group reads" "key_unreadable" (code (on_key ()));
      Unix.chmod key_file 0o600;
      let declared =
        { config with
          providers =
            List.map
              (fun (provider : Runtime_schema.provider) ->
                { provider with credentials = Some (Runtime_schema.File key_file) })
              config.providers
        }
      in
      check
        credential
        "a login account takes no credential the workspace declared for the template"
        None
        (credentials (of_template ~config:declared ~template:"claude_code" ~binding (Some home)));
      check
        string
        "an official client without an account home is refused"
        "not_materialized"
        (code (of_template ~template:"claude_code" ~binding None)))
;;

(* RFC a-persons-api-key-is-their-own-provider-account 3.9: an HTTP provider
   account has no CLI account_home, never inherits operator credentials or
   headers from its template, preserves catalog provider identity, and is
   sealed with seal_person_api. *)
let http_provider_template () =
  let http_config =
    match
      Runtime_toml.parse_string
        {|
[runtime]
default = "claude.claude-sonnet-5"

[providers.claude]
display-name = "Anthropic API"
protocol = "messages-http"
endpoint = "https://api.anthropic.com"

[providers.claude.credentials]
type = "inline"
value = "sk-operator-should-never-leak"

[providers.claude.headers]
x-operator-secret = "op-header-should-never-leak"

[providers.vertex]
display-name = "Vertex Gemini"
protocol = "vertex-gemini"
endpoint = "https://us-central1-aiplatform.googleapis.com/v1/projects/p/locations/us-central1/publishers/google"

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true

[models."gemini-2.5-pro"]
api-name = "gemini-2.5-pro"
max-context = 1000000
tools-support = true
streaming = true

[claude."claude-sonnet-5"]
[vertex."gemini-2.5-pro"]
|}
    with
    | Ok config -> config
    | Error _ -> fail "http fixture runtime.toml refused"
  in
  let root = Filename.temp_dir ~perms:0o700 "account-runtime-http-" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
      let account_id =
        match Authz_types.Provider_account_id.of_string "acct-1" with
        | Ok id -> id
        | Error _ -> fail "fixture account id refused"
      in
      let generation = Authz_types.Key_generation.first in
      let key_file =
        match Runtime_account_home_layout.key_file ~runtime_root:root ~account_id ~generation with
        | Ok path -> path
        | Error detail -> fail detail
      in
      let code = function
        | Ok (runtime : Runtime_instance.t) -> "ok " ^ runtime.id
        | Error error -> A.error_code error
      in
      let binding = A.Model "claude-sonnet-5" in
      check
        string
        "missing key file on HTTP template reports key_missing"
        "key_missing"
        (code
           (of_template
              ~config:http_config
              ~account:(A.Key { key_file })
              ~template:"claude"
              ~binding
              None));
      (match Runtime_api_key_file.key_of_string "sk-person-http-key" with
       | None -> fail "fixture key refused"
       | Some key ->
         (match Runtime_api_key_file.write ~runtime_root:root ~account_id ~generation key with
          | Ok () -> ()
          | Error _ -> fail "fixture key not written"));
      (match
         of_template
           ~config:http_config
           ~account:(A.Key { key_file })
           ~template:"claude"
           ~binding
           None
       with
       | Error error -> fail (A.error_to_string error)
       | Ok runtime ->
         check string "HTTP runtime id" "acct-1.claude-sonnet-5" runtime.id;
         check (option string) "HTTP account has no account_home" None runtime.provider.account_home;
         check bool "HTTP account drops template headers" true (runtime.provider.headers = None);
         let credential =
           option (testable Runtime_schema.pp_credential Runtime_schema.equal_credential)
         in
         check
           credential
           "HTTP account takes the person's key file"
           (Some (Runtime_schema.File key_file))
           runtime.provider.credentials;
         check
           (option string)
           "catalog provider identity preserved across account rename"
           (Some "claude")
           runtime.provider.catalog_provider;
         (match runtime.execution with
          | Runtime_execution.Agent_core sealed ->
            check bool "HTTP runtime sealed as Person_api" true (Runtime_account_access.is_person_api sealed);
            let decl = Runtime_account_access.api_declaration sealed in
            check string "api_declaration api_key empty" "" (decl.api_key :> string);
            check int "api_declaration headers stripped" 0 (List.length decl.headers);
            check (option string) "declaration preserves catalog provider_id" (Some "claude") decl.provider_id;
            check
              bool
              "host authorize_api refuses Person_api"
              true
              (Result.is_error (Runtime_account_access.authorize_api sealed))
          | Runtime_execution.Claude_code _
          | Runtime_execution.Codex_app_server _
          | Runtime_execution.Antigravity_cli _
          | Runtime_execution.Acp _ -> fail "expected Agent_core execution"));
      check
        string
        "HTTP template with account_home is refused"
        "not_materialized"
        (code
           (of_template
              ~config:http_config
              ~account:(A.Key { key_file })
              ~template:"claude"
              ~binding
              (Some "/tmp")));
      check
        string
        "HTTP template with Login account is refused"
        "not_materialized"
        (code (of_template ~config:http_config ~account:A.Login ~template:"claude" ~binding None));
      check
        string
        "Vertex Gemini refuses person key account"
        "not_materialized"
        (code
           (of_template
              ~config:http_config
              ~account:(A.Key { key_file })
              ~template:"vertex"
              ~binding:(A.Model "gemini-2.5-pro")
              None));
      Unix.chmod key_file 0o640;
      check
        string
        "open key file on HTTP template reports key_unreadable"
        "key_unreadable"
        (code
           (of_template
              ~config:http_config
              ~account:(A.Key { key_file })
              ~template:"claude"
              ~binding
              None)))
;;

(* task-3830: [Runtime_person_template.error] carries only template/binding/materialization
   failures (never key-file errors); [Runtime_account_runtime] owns [Key_missing] and
   [Key_unreadable] and maps template errors without changing codes or messages. *)
let person_template_error_surface () =
  let module T = Runtime_person_template in
  let classify = function
    | T.Template_not_declared _ -> "template_not_declared"
    | T.Model_not_bound _ -> "model_not_bound"
    | T.Runtime_not_bound _ -> "runtime_not_bound"
    | T.Not_materialized _ -> "not_materialized"
  in
  let pairs : (T.error * A.error) list =
    [ ( T.Template_not_declared "codex"
      , A.Template_not_declared "codex" )
    ; ( T.Model_not_bound { template = "claude_code"; model = "gpt-5.5" }
      , A.Model_not_bound { template = "claude_code"; model = "gpt-5.5" } )
    ; ( T.Runtime_not_bound { template = "claude_code"; runtime_id = "acct-2.claude-sonnet-5" }
      , A.Runtime_not_bound { template = "claude_code"; runtime_id = "acct-2.claude-sonnet-5" } )
    ; ( T.Not_materialized "bad config"
      , A.Not_materialized "bad config" )
    ]
  in
  List.iter
    (fun (t_err, a_err) ->
       let expected_code = classify t_err in
       check string "template error_code" expected_code (T.error_code t_err);
       check string "account error_code parity" (T.error_code t_err) (A.error_code a_err);
       check
         string
         "account error_to_string parity"
         (T.error_to_string t_err)
         (A.error_to_string a_err))
    pairs;
  (match T.binding_of config ~template:"missing" ~provider_id:"acct-1" ~binding:(T.Model "m") with
   | Ok _ -> fail "expected Template_not_declared"
   | Error err -> check string "binding_of error_code" "template_not_declared" (T.error_code err));
  (match A.binding_of config ~template:"missing" ~provider_id:"acct-1" ~binding:(A.Model "m") with
   | Ok _ -> fail "expected mapped Template_not_declared"
   | Error err -> check string "account binding_of error_code" "template_not_declared" (A.error_code err));
  check
    string
    "key_missing error_to_string"
    (Runtime_api_key_file.read_error_to_string Runtime_api_key_file.Key_missing)
    (A.error_to_string A.Key_missing);
  check
    string
    "key_unreadable error_to_string"
    (Runtime_api_key_file.read_error_to_string
       (Runtime_api_key_file.Key_unreadable Runtime_api_key_file.Open_to_others))
    (A.error_to_string (A.Key_unreadable Runtime_api_key_file.Open_to_others));
  let provider_account_id =
    match Authz_types.Provider_account_id.of_string "acct-1" with
    | Ok id -> id
    | Error _ -> fail "fixture account id refused"
  in
  let integration_id =
    match Authz_types.Integration_id.of_string "claude_code" with
    | Ok id -> id
    | Error _ -> fail "fixture integration id refused"
  in
  (match
     A.of_person_template
       config
       ~template:"missing"
       ~provider_account_id
       ~integration_id
       ~account_home:None
       ~binding:(A.Model "m")
   with
   | Ok _ -> fail "expected mapped of_person_template Template_not_declared"
   | Error err ->
     check string "account of_person_template error_code" "template_not_declared" (A.error_code err))
;;

let () =
  run
    "runtime_account_runtime"
    [ ( "of_template"
      , [ test_case "the template with the person's home" `Quick the_template_with_the_persons_home
        ; test_case "the binding of a Runtime id" `Quick the_binding_of_a_runtime_id
        ; test_case "the credential is of the account" `Quick the_credential_is_of_the_account
        ; test_case "HTTP provider template" `Quick http_provider_template
        ; test_case "person template error surface" `Quick person_template_error_surface
        ] )
    ]
;;
