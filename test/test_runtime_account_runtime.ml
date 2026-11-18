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

let of_template ?(config = config) ?(account = A.Login) ~template ~binding home =
  A.of_template config ~template ~provider_id:"acct-1" ~account_home:home ~account ~binding
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
      match of_template ~template:"claude_code" ~binding:(A.Model "claude-sonnet-5") home with
      | Error error -> fail (A.error_to_string error)
      | Ok runtime ->
        check string "the id is the account's binding" "acct-1.claude-sonnet-5" runtime.Runtime_instance.id;
        check (option string) "the home is the person's" (Some home) runtime.provider.account_home;
        check
          string
          "no template"
          (A.error_to_string (A.Template_not_declared "codex"))
          (match of_template ~template:"codex" ~binding:(A.Model "claude-sonnet-5") home with
           | Ok _ -> "ok"
           | Error error -> A.error_to_string error);
        check
          string
          "no binding of the model"
          (A.error_to_string (A.Model_not_bound { template = "claude_code"; model = "gpt-5.5" }))
          (match of_template ~template:"claude_code" ~binding:(A.Model "gpt-5.5") home with
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
      let runtime runtime_id = outcome (of_template ~template:"claude_code" ~binding:(A.Runtime runtime_id) home) in
      check string "the account's Runtime" "ok acct-1.claude-sonnet-5" (runtime "acct-1.claude-sonnet-5");
      check
        string
        "the same as the model's"
        (outcome (of_template ~template:"claude_code" ~binding:(A.Model "claude-sonnet-5") home))
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
      let on_key () = of_template ~account:(A.Key { key_file }) ~template:"claude_code" ~binding home in
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
        (credentials (of_template ~config:declared ~template:"claude_code" ~binding home)))
;;

let () =
  run
    "runtime_account_runtime"
    [ ( "of_template"
      , [ test_case "the template with the person's home" `Quick the_template_with_the_persons_home
        ; test_case "the binding of a Runtime id" `Quick the_binding_of_a_runtime_id
        ; test_case "the credential is of the account" `Quick the_credential_is_of_the_account
        ] )
    ]
;;
