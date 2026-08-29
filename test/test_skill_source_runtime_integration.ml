open Alcotest
open Masc

let runtime_with_skills =
  {|[skills]
resource-read-max-bytes = 65536

[[skills.sources]]
id = "project"
anchor = "base-path"
path = ".agents/skills"
access = "read-only"

[providers.local]
protocol = "ollama-http"
endpoint = "http://127.0.0.1:11434"

[models.sample]
api-name = "sample"
max-context = 1024

[local.sample]

[runtime]
default = "local.sample"
|}
;;

let test_skills_namespace_is_not_a_provider () =
  match Runtime_toml.parse_string runtime_with_skills with
  | Error errors ->
    fail
      (String.concat
         "; "
         (List.map
            (fun (error : Runtime_toml.parse_error) ->
               error.path ^ ": " ^ error.message)
            errors))
  | Ok config ->
    check int "one provider" 1 (List.length config.Runtime_schema.providers);
    check int "one binding" 1 (List.length config.Runtime_schema.bindings)
;;

let test_runtime_save_precondition_rejects_skill_config () =
  let malformed =
    runtime_with_skills
    ^ "\n[[skills.sources]]\nid = \"broken\"\nanchor = \"base-path\"\npath = \"../escape\"\naccess = \"read-only\"\n"
  in
  match
    Runtime.validate_config_text
      ~runtime_config_path:"/tmp/runtime.toml"
      malformed
  with
  | Ok () -> fail "runtime save precondition accepted malformed Skill source"
  | Error detail ->
    check bool
      "Skill path diagnostic"
      true
      (String_util.contains_substring detail "skills.sources[1].path")
;;

let () =
  run
    "skill_source_runtime_integration"
    [ ( "runtime"
      , [ test_case "skills namespace is reserved" `Quick
            test_skills_namespace_is_not_a_provider
        ; test_case "save validates Skill sources" `Quick
            test_runtime_save_precondition_rejects_skill_config
        ] )
    ]
;;
