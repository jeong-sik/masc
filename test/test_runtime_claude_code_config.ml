open Alcotest

let contains_substring value needle =
  let value_length = String.length value in
  let needle_length = String.length needle in
  let rec scan index =
    index + needle_length <= value_length
    && (String.equal (String.sub value index needle_length) needle || scan (index + 1))
  in
  needle_length = 0 || scan 0
;;

let runtime_toml ?credential () =
  let credential = Option.value credential ~default:"" in
  Printf.sprintf
    "[providers.claude]\n\
     protocol = \"claude-code\"\n\
     command = \"claude\"\n\
     is-non-interactive = true\n\
     %s\n\
     [models.opus]\n\
     api-name = \"claude-opus-5\"\n\
     max-context = 128000\n\
     \n\
     [claude.opus]\n\
     \n\
     [runtime]\n\
     default = \"claude.opus\"\n"
    credential
;;

let with_runtime_toml content f =
  let path = Filename.temp_file "masc-claude-code-config-" ".toml" in
  let channel = open_out_bin path in
  output_string channel content;
  close_out channel;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let test_materializes_as_official_client_runtime () =
  with_runtime_toml (runtime_toml ()) (fun path ->
    match Runtime.load_list ~config_path:path with
    | Error error -> failf "claude-code runtime should load: %s" error
    | Ok (runtimes, default, _, _, _, _) ->
      check int "one runtime" 1 (List.length runtimes);
      check string "default id" "claude.opus" default.id;
      (match default.execution with
       | Runtime_execution.Claude_code config ->
         check string "cli path" "claude" config.cli_path;
         check (option string) "model" (Some "claude-opus-5") config.model;
         check int "default client turns" 12 config.max_turns;
         check string "typed owner label" "claude_code"
           (Runtime_execution.label default.execution);
         check bool "agent_core config absent" true
           (Option.is_none
              (Runtime_execution.agent_core_provider_config default.execution))
       | Runtime_execution.Agent_core _
       | Runtime_execution.Codex_app_server _
       | Runtime_execution.Antigravity_cli _ ->
         fail "claude-code was materialized through the wrong execution owner"))
;;

let test_rejects_declared_credentials () =
  let credential =
    "[providers.claude.credentials]\n\
     type = \"env\"\n\
     key = \"ANTHROPIC_API_KEY\""
  in
  with_runtime_toml (runtime_toml ~credential ()) (fun path ->
    match Runtime.load_list ~config_path:path with
    | Ok _ -> fail "claude-code incorrectly admitted declared credentials"
    | Error error ->
      check bool "official login owns authentication" true
        (contains_substring
           error
           "official Claude Code client owns subscription login"))
;;

let () =
  run
    "runtime Claude Code config"
    [ ( "typed config boundary"
      , [ test_case
            "official-client materialization"
            `Quick
            test_materializes_as_official_client_runtime
        ; test_case "credentials rejected" `Quick test_rejects_declared_credentials
        ] )
    ]
;;
