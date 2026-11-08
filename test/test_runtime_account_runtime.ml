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

let of_template ~template ~model home =
  A.of_template config ~template ~provider_id:"acct-1" ~account_home:home ~model
;;

(* Plan D1-6a: the runtime of a person's account is the template with its id
   and home replaced, and the template's binding of the model. *)
let the_template_with_the_persons_home () =
  let home = Filename.temp_dir ~perms:0o700 "account-runtime-" "" |> Unix.realpath in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree home)
    (fun () ->
      match of_template ~template:"claude_code" ~model:"claude-sonnet-5" home with
      | Error error -> fail (A.error_to_string error)
      | Ok runtime ->
        check string "the id is the account's binding" "acct-1.claude-sonnet-5" runtime.Runtime_instance.id;
        check (option string) "the home is the person's" (Some home) runtime.provider.account_home;
        check
          string
          "no template"
          (A.error_to_string (A.Template_not_declared "codex"))
          (match of_template ~template:"codex" ~model:"claude-sonnet-5" home with
           | Ok _ -> "ok"
           | Error error -> A.error_to_string error);
        check
          string
          "no binding of the model"
          (A.error_to_string (A.Model_not_bound { template = "claude_code"; model = "gpt-5.5" }))
          (match of_template ~template:"claude_code" ~model:"gpt-5.5" home with
           | Ok _ -> "ok"
           | Error error -> A.error_to_string error))
;;

let () =
  run
    "runtime_account_runtime"
    [ ( "of_template"
      , [ test_case "the template with the person's home" `Quick the_template_with_the_persons_home ] )
    ]
;;
