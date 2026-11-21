open Alcotest

(* These tests assert on the operator-facing wording, so the typed failure is
   rendered once here instead of at every call below. *)
let load_list_text ~config_path =
  Runtime.load_list ~config_path
  |> Result.map_error (Runtime_config_error.to_diagnostic_text ~config_path)
;;


let runtime_toml ?credential ?(transport = "command = \"claude\"")
    ?(non_interactive = true) ?(max_context = 200000) () =
  let credential = Option.value credential ~default:"" in
  Printf.sprintf
    "[providers.claude_code]\n\
     protocol = \"claude-code\"\n\
     %s\n\
     is-non-interactive = %b\n\
     %s\n\
     [models.claude-code-sonnet]\n\
     api-name = \"claude-sonnet-4-5\"\n\
     max-context = %d\n\
     \n\
     [claude_code.claude-code-sonnet]\n\
     \n\
     [runtime]\n\
     default = \"claude_code.claude-code-sonnet\"\n"
    transport
    non_interactive
    credential
    max_context
;;

let with_runtime_toml content f =
  let path = Filename.temp_file "masc-claude-code-config-" ".toml" in
  let channel = open_out_bin path in
  output_string channel content;
  close_out channel;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

(* No official client anywhere, so a configured command stays as configured
   ({!Runtime_official_cli_install.locate}); these cases are about the
   configuration, not about where a client is installed. A blank
   CODEX_INSTALL_DIR reads as unset, which is what the lookup asks. *)
let without_an_installed_client f =
  let home = Filename.temp_dir "masc-no-client-" "" in
  let restore = List.map (fun name -> name, Sys.getenv_opt name) [ "PATH"; "HOME"; "CODEX_INSTALL_DIR" ] in
  List.iter (fun (name, value) -> Unix.putenv name value)
    [ "PATH", ""; "HOME", home; "CODEX_INSTALL_DIR", "" ];
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, value) -> Unix.putenv name (Option.value value ~default:"")) restore;
      Unix.rmdir home)
    f
;;

let load content =
  without_an_installed_client (fun () ->
    with_runtime_toml content (fun path -> load_list_text ~config_path:path))
;;

let load_typed content =
  without_an_installed_client (fun () ->
    with_runtime_toml content (fun path ->
      path, Runtime.load_list ~config_path:path))
;;

let init_default_isolated content =
  let saved = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore saved)
    (fun () ->
       without_an_installed_client (fun () ->
         with_runtime_toml content (fun path ->
           let before_ids = Runtime.get_runtime_ids () in
           let result = Runtime.init_default ~config_path:path in
           before_ids, result, Runtime.get_runtime_ids (), Runtime.get_default_runtime ())))
;;

let assert_below_floor ~expected_id ~expected_window content =
  let floor = Runtime_claude_code.autocompact_window_floor_tokens in
  let path, loaded = load_typed content in
  match loaded with
  | Error
      (Runtime_config_error.Client_compact_window_below_floor
         { runtime_id; declared_window; client_floor }) ->
    check string "rejected runtime id" expected_id runtime_id;
    check int "declared window" expected_window declared_window;
    check int "client floor matches constant" floor client_floor
  | Error failure ->
    failf
      "expected Client_compact_window_below_floor, got: %s"
      (Runtime_config_error.to_diagnostic_text ~config_path:path failure)
  | Ok (runtimes, _, _, _, _) ->
    failf
      "below-floor claude_code window (%d) must reject the whole file, but loaded %d binding(s)"
      expected_window
      (List.length runtimes)
;;

let test_materializes_official_client_owner () =
  match load (runtime_toml ()) with
  | Error error -> failf "claude-code runtime should load: %s" error
  | Ok (runtimes, default, _, _, _) ->
    check int "one runtime" 1 (List.length runtimes);
    check string "default" "claude_code.claude-code-sonnet" default.id;
    (match default.execution with
     | Runtime_execution.Claude_code config ->
       check string "CLI, as configured when no client is installed" "claude" config.cli_path;
       check (option string)
         "model"
         (Some "claude-sonnet-4-5")
         config.model;
       check (float 0.001) "timeout" 300.0 config.timeout_s
     | Runtime_execution.Agent_core _
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Antigravity_cli _
     | Runtime_execution.Muse_serve _ | Runtime_execution.Vibe_cli _ ->
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

(* A file with one claude_code binding below the autocompact floor (8192, the
   window test_install_runtime_setup.py used to emit) is refused as a whole:
   even a valid default sibling in the same file must not load. *)
let test_below_floor_window_rejects_the_whole_file () =
  let floor = Runtime_claude_code.autocompact_window_floor_tokens in
  let multi_binding_toml sonnet_window =
    Printf.sprintf
      "[providers.claude_code]\n\
       protocol = \"claude-code\"\n\
       command = \"claude\"\n\
       is-non-interactive = true\n\
       \n\
       [models.claude-code-valid]\n\
       api-name = \"claude-opus-4-5\"\n\
       max-context = %d\n\
       \n\
       [models.claude-code-sonnet]\n\
       api-name = \"claude-sonnet-4-5\"\n\
       max-context = %d\n\
       \n\
       [claude_code.claude-code-valid]\n\
       \n\
       [claude_code.claude-code-sonnet]\n\
       \n\
       [runtime]\n\
       default = \"claude_code.claude-code-valid\"\n"
      floor
      sonnet_window
  in
  (let path, loaded = load_typed (multi_binding_toml floor) in
   match loaded with
   | Error failure ->
     failf
       "multi-binding config at the floor must load: %s"
       (Runtime_config_error.to_diagnostic_text ~config_path:path failure)
   | Ok (runtimes, default, _, _, _) ->
     check int "both bindings load at the floor" 2 (List.length runtimes);
     check string "default is the valid sibling" "claude_code.claude-code-valid" default.id);
  let below_floor_toml = multi_binding_toml 8192 in
  assert_below_floor
    ~expected_id:"claude_code.claude-code-sonnet"
    ~expected_window:8192
    below_floor_toml;
  let before_ids, init_result, after_ids, after_default =
    init_default_isolated below_floor_toml
  in
  check (list string) "initial state has no bindings" [] before_ids;
  check bool "init_default refuses the whole file" true (Result.is_error init_result);
  check (list string) "no bindings are loaded after refusal" [] after_ids;
  check bool "no default runtime is published" true (Option.is_none after_default)
;;

let test_window_floor_boundary_accepts_floor_and_rejects_one_below () =
  let floor = Runtime_claude_code.autocompact_window_floor_tokens in
  (let path, loaded = load_typed (runtime_toml ~max_context:floor ()) in
   match loaded with
   | Error failure ->
     failf
       "window equal to autocompact_window_floor_tokens (%d) must load: %s"
       floor
       (Runtime_config_error.to_diagnostic_text ~config_path:path failure)
   | Ok (runtimes, default, _, _, _) ->
     check int "one runtime loads at the exact floor" 1 (List.length runtimes);
     check string "default runtime" "claude_code.claude-code-sonnet" default.id);
  assert_below_floor
    ~expected_id:"claude_code.claude-code-sonnet"
    ~expected_window:(floor - 1)
    (runtime_toml ~max_context:(floor - 1) ())
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
        ; test_case
            "below-floor window (8192) rejects the whole file"
            `Quick
            test_below_floor_window_rejects_the_whole_file
        ; test_case
            "window floor boundary accepts floor and rejects floor - 1"
            `Quick
            test_window_floor_boundary_accepts_floor_and_rejects_one_below
        ] )
    ]
;;
