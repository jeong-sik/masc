open Alcotest

let runtime_toml ?credential ?(transport = "command = \"claude\"")
    ?(non_interactive = true) () =
  let credential = Option.value credential ~default:"" in
  Printf.sprintf
    "[providers.claude_code]\n\
     protocol = \"claude-code\"\n\
     %s\n\
     is-non-interactive = %b\n\
     %s\n\
     [models.claude-code-sonnet]\n\
     api-name = \"claude-sonnet-4-5\"\n\
     max-context = 200000\n\
     \n\
     [claude_code.claude-code-sonnet]\n\
     \n\
     [runtime]\n\
     default = \"claude_code.claude-code-sonnet\"\n"
    transport
    non_interactive
    credential
;;

let with_runtime_toml content f =
  let path = Filename.temp_file "masc-claude-code-config-" ".toml" in
  let channel = open_out_bin path in
  output_string channel content;
  close_out channel;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let load content =
  with_runtime_toml content (fun path -> Runtime.load_list ~config_path:path)
;;

let test_materializes_official_client_owner () =
  match load (runtime_toml ()) with
  | Error error -> failf "claude-code runtime should load: %s" error
  | Ok (runtimes, default, _, _, _) ->
    check int "one runtime" 1 (List.length runtimes);
    check string "default" "claude_code.claude-code-sonnet" default.id;
    (match default.execution with
     | Runtime_execution.Claude_code config ->
       check string "CLI" "claude" config.cli_path;
       check (option string)
         "model"
         (Some "claude-sonnet-4-5")
         config.model;
       check (float 0.001) "timeout" 300.0 config.timeout_s
     | Runtime_execution.Agent_core _
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Antigravity_cli _ ->
       fail "claude-code was materialized as the wrong execution owner")
;;

let test_declared_credentials_are_rejected () =
  let credential =
    "[providers.claude_code.credentials]\n\
     type = \"env\"\n\
     key = \"ANTHROPIC_API_KEY\"\n"
  in
  match load (runtime_toml ~credential ()) with
  | Error _ -> ()
  | Ok _ -> fail "claude-code admitted a declared API credential"
;;

let test_http_transport_is_rejected () =
  match load (runtime_toml ~transport:"endpoint = \"https://api.anthropic.com\"" ()) with
  | Error _ -> ()
  | Ok _ -> fail "claude-code admitted an HTTP transport"
;;

let test_interactive_provider_is_rejected () =
  match load (runtime_toml ~non_interactive:false ()) with
  | Error _ -> ()
  | Ok _ -> fail "claude-code admitted an interactive provider declaration"
;;

let test_protocol_name_is_exact () =
  match Runtime_toml.api_format_of_protocol "claude_code" with
  | Error _ -> ()
  | Ok _ -> fail "underscore protocol alias was silently accepted"
;;

let () =
  run
    "runtime_claude_code_config"
    [ ( "typed config"
      , [ test_case
            "materializes official-client owner"
            `Quick
            test_materializes_official_client_owner
        ; test_case
            "declared credentials rejected"
            `Quick
            test_declared_credentials_are_rejected
        ; test_case "HTTP transport rejected" `Quick test_http_transport_is_rejected
        ; test_case
            "interactive provider rejected"
            `Quick
            test_interactive_provider_is_rejected
        ; test_case "protocol name exact" `Quick test_protocol_name_is_exact
        ] )
    ]
;;
