open Alcotest

type client = Claude | Codex

let with_env values run =
  let saved = List.map (fun (name, _) -> name, Sys.getenv_opt name) values in
  let set (name, value) = match value with
    | Some value -> Unix.putenv name value | None -> Unix.unsetenv name in
  Fun.protect ~finally:(fun () -> List.iter set saved) (fun () ->
    List.iter set values;
    run ())

let with_directory run =
  let path = Filename.temp_file "masc-native-account-selection-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir path) (fun () -> run path)

let env_value name environment =
  let prefix = name ^ "=" in
  environment |> Array.to_list |> List.find_map (fun entry ->
    if String.starts_with ~prefix entry
    then Some (String.sub entry (String.length prefix)
      (String.length entry - String.length prefix))
    else None)

let environment =
  ["CLAUDE_CONFIG_DIR"; "CODEX_HOME";
   "ANTHROPIC_API_KEY"; "ANTHROPIC_AUTH_TOKEN"; "CLAUDE_CODE_OAUTH_TOKEN";
   "CLAUDE_CODE_USE_BEDROCK"; "CLAUDE_CODE_USE_VERTEX";
   "CLAUDE_CODE_USE_FOUNDRY"; "CLAUDE_CODE_USE_MANTLE";
   "OPENAI_API_KEY"; "OPENAI_BASE_URL"; "CODEX_API_KEY"; "CODEX_ACCESS_TOKEN"]
  |> List.map (fun name -> name, None)

let materialize ?account_home client =
  let protocol = match client with Claude -> "claude-code" | Codex -> "codex-app-server" in
  let account = Option.fold ~none:"" ~some:(fun home ->
    Printf.sprintf "account-home = %S\n" home) account_home in
  let source = Printf.sprintf {|
[providers.native]
protocol = %S
command = "masc-native-account-fixture-client"
is-non-interactive = true
%s
[models.selected]
api-name = "native-account-fixture-model"
max-context = 8192
[native.selected]
[runtime]
default = "native.selected"
|} protocol account in
  let config = match Runtime_toml.parse_string source with
    | Ok config -> config | Error _ -> fail "native fixture must parse" in
  let binding = match config.Runtime_schema.bindings with
    | [binding] -> binding | _ -> fail "expected one native binding" in
  match Runtime_instance.of_binding config binding with
  | Ok runtime -> runtime
  | Error reason -> fail (Runtime_config_error.string_of_drop_reason reason)

let child_environment runtime =
  match runtime.Runtime_instance.execution with
  | Runtime_execution.Claude_code execution ->
    Runtime_claude_code.client_environment execution.account_home
  | Codex_app_server execution ->
    (match Runtime_codex_app_server.client_environment execution.account_home with
     | Ok environment -> environment
     | Error error -> fail (Runtime_codex_app_server.error_to_string error))
  | Agent_core _ | Antigravity_cli _ | Muse_serve _ -> fail "expected an official client"

let test_inherited_home client () =
  with_directory (fun first -> with_directory (fun second ->
    with_env (("HOME", Some first) :: environment) (fun () ->
      let runtime = materialize client in
      let home, expected_scope = match client with
        | Claude -> Filename.concat first ".claude",
          Runtime_quota_window.scope_of_claude_code_home
        | Codex -> Filename.concat first ".codex",
          Runtime_quota_window.scope_of_codex_home in
      check string "quota was admitted under the original client store"
        (Runtime_quota_window.scope_to_string (expected_scope (Some home)))
        (Runtime_quota_window.scope_to_string runtime.quota_scope);
      with_env ["HOME", Some second] (fun () ->
        let child = child_environment runtime in
        check (option string) "child retains the admitted user home" (Some first)
          (env_value "HOME" child);
        match client with
        | Claude ->
          check (option string) "ordinary HOME does not become a config-dir override"
            None (env_value "CLAUDE_CONFIG_DIR" child);
          (match runtime.execution with
           | Claude_code execution ->
             check (option string) "ordinary account file remains in admitted HOME"
               (Some (Filename.concat first ".claude.json"))
               (Runtime_claude_code.account_file execution.account_home)
           | Agent_core _ | Codex_app_server _ | Antigravity_cli _ | Muse_serve _ ->
             fail "expected Claude execution")
        | Codex -> check (option string) "Codex store remains the admitted directory"
            (Some home) (env_value "CODEX_HOME" child)))))

let test_inherited_directory client () =
  with_directory (fun first -> with_directory (fun second ->
    let variable = match client with Claude -> "CLAUDE_CONFIG_DIR" | Codex -> "CODEX_HOME" in
    with_env (("HOME", Some first) :: environment) (fun () ->
      with_env [variable, Some first] (fun () ->
        let runtime = materialize client in
        with_env [variable, Some second] (fun () ->
          check (option string) "child retains the inherited directory selected at admission"
            (Some first) (env_value variable (child_environment runtime));
          match runtime.execution with
          | Claude_code execution -> check (option string)
              "config-dir account file retains its original namespace"
              (Some (Filename.concat first ".claude.json"))
              (Runtime_claude_code.account_file execution.account_home)
          | Codex_app_server _ -> ()
          | Agent_core _ | Antigravity_cli _ | Muse_serve _ -> fail "expected native execution")))))

let test_inherited_credential client () =
  with_directory (fun home ->
    let key = match client with Claude -> "ANTHROPIC_API_KEY" | Codex -> "OPENAI_API_KEY" in
    with_env (("HOME", Some home) :: environment) (fun () ->
      with_env [key, Some "admitted-fixture-key"] (fun () ->
        let runtime = materialize client in
        with_env [key, Some "replacement-fixture-key"] (fun () ->
          check (option string) "credential environment belongs to the admitted selection"
            (Some "admitted-fixture-key") (env_value key (child_environment runtime))))))

let test_explicit_directory client () =
  with_directory (fun home -> with_directory (fun replacement ->
    let variable, key = match client with
      | Claude -> "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY"
      | Codex -> "CODEX_HOME", "OPENAI_API_KEY" in
    with_env (("HOME", Some home) :: environment) (fun () ->
      with_env [key, Some "unselected-fixture-key"] (fun () ->
        let runtime = materialize ~account_home:home client in
        with_env [variable, Some replacement] (fun () ->
          let child = child_environment runtime in
          check (option string) "explicit directory remains selected" (Some home)
            (env_value variable child);
          check (option string) "explicit directory keeps credential isolation" None
            (env_value key child))))))

let () = run "native account selection"
  ["admission to execution",
    [test_case "Claude inherited user home is captured" `Quick (test_inherited_home Claude);
     test_case "Codex inherited user home is captured" `Quick (test_inherited_home Codex);
     test_case "Claude inherited config directory is captured" `Quick (test_inherited_directory Claude);
     test_case "Codex inherited config directory is captured" `Quick (test_inherited_directory Codex);
     test_case "Claude inherited credential environment is captured" `Quick (test_inherited_credential Claude);
     test_case "Codex inherited credential environment is captured" `Quick (test_inherited_credential Codex);
     test_case "Claude explicit directory preserves isolation" `Quick (test_explicit_directory Claude);
     test_case "Codex explicit directory preserves isolation" `Quick (test_explicit_directory Codex)]]
