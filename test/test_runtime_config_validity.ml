open Alcotest
open Masc

let empty_env _name = None

let parse_or_fail content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> doc
  | Error msg -> failf "TOML parse failed: %s" msg

let rec repo_root_from dir =
  let dune_project = Filename.concat dir "dune-project" in
  if Sys.file_exists dune_project then dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      failf "unable to locate repo root from cwd=%s" (Sys.getcwd ())
    else repo_root_from parent

let repo_root () = repo_root_from (Sys.getcwd ())

let test_runtime_json_not_in_repo_config () =
  let path = Filename.concat (repo_root ()) "config/runtime.json" in
  check bool "retired runtime.json absent" false (Sys.file_exists path)

let test_repo_runtime_toml_loads () =
  let path = Filename.concat (repo_root ()) "config/runtime.toml" in
  check bool "repo runtime.toml present" true (Sys.file_exists path);
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok (runtimes, default, assignments) ->
    check bool "at least one runtime" true (List.length runtimes > 0);
    check string "default runtime" "ollama_cloud.deepseek-v4-flash"
      default.Runtime.id;
    check int "one local Gemma canary pin in seed" 1 (List.length assignments);
    check (option string) "nick0cave Gemma canary pin"
      (Some "ollama.gemma4-26b-a4b-qat")
      (List.assoc_opt "nick0cave" assignments);
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "ollama.gemma4-26b-a4b-qat")
         runtimes
     with
     | None -> fail "expected Gemma4 Ollama runtime in seed"
     | Some runtime ->
       check bool "Gemma4 thinking enabled" true runtime.model.thinking_support;
       check bool "Gemma4 thinking not preserved" false
         runtime.model.preserve_thinking;
       (match runtime.model.capabilities with
        | Some caps ->
          check bool "Gemma4 chat-template-token thinking control" true
            (Runtime_schema.equal_thinking_control_format
               caps.thinking_control_format
               Runtime_schema.Chat_template_token)
        | None -> fail "expected Gemma4 capabilities"));
    (match
       List.find_opt
         (fun (runtime : Runtime.t) ->
            String.equal runtime.id "glm-coding.glm-4-7-coding")
         runtimes
     with
     | None -> fail "expected GLM Coding Plan runtime in seed"
     | Some runtime ->
       check string "GLM Coding Plan model api name" "glm-4.7"
         runtime.model.api_name;
       check int "GLM Coding Plan context" 200000 runtime.model.max_context;
       check bool "GLM Coding Plan thinking enabled" true
         runtime.model.thinking_support;
       check bool "GLM Coding Plan preserves thinking" true
         runtime.model.preserve_thinking;
       (match runtime.model.capabilities with
        | Some caps ->
          check (option int) "GLM Coding Plan output cap" (Some 128000)
            caps.max_output_tokens;
          check bool "GLM Coding Plan forced tool_choice disabled" false
            caps.supports_tool_choice;
          check bool "GLM Coding Plan extended thinking" true
            caps.supports_extended_thinking
        | None -> fail "expected GLM Coding Plan capabilities"))

let test_toml_catalog_resolves_lifecycle_keys () =
  let doc =
    parse_or_fail
      "[lifecycle]\n\
       self_preservation_ratio = 0.4\n\
       self_preservation_min = 2\n\
       dead_ttl_sec = 86400\n\
       paused_cleanup_ttl_sec = 604800\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied lifecycle overrides" 4 count;
  check (option string) "self preservation ratio" (Some "0.4")
    (List.assoc_opt "MASC_KEEPER_SELF_PRESERVATION_RATIO" overrides);
  check (option string) "self preservation min" (Some "2")
    (List.assoc_opt "MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES" overrides);
  check (option string) "dead ttl" (Some "86400")
    (List.assoc_opt "MASC_KEEPER_DEAD_TTL_SEC" overrides);
  check (option string) "paused cleanup ttl" (Some "604800")
    (List.assoc_opt "MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC" overrides)

let () =
  run "runtime_config_validity"
    [ ( "runtime TOML gate",
        [ test_case "runtime.json is not a repo config source" `Quick
            test_runtime_json_not_in_repo_config;
          test_case "repo runtime.toml loads through runtime parser" `Quick
            test_repo_runtime_toml_loads;
          test_case
            "lifecycle TOML keys resolve through the declarative catalog"
            `Quick test_toml_catalog_resolves_lifecycle_keys ] )
    ]
