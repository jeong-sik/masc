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
  ["CLAUDE_CONFIG_DIR"; "CODEX_HOME"; "ANTHROPIC_CONFIG_DIR";
   "ANTHROPIC_API_KEY"; "ANTHROPIC_AUTH_TOKEN"; "CLAUDE_CODE_OAUTH_TOKEN";
   "CLAUDE_CODE_USE_BEDROCK"; "CLAUDE_CODE_USE_VERTEX";
   "CLAUDE_CODE_USE_FOUNDRY"; "CLAUDE_CODE_USE_MANTLE";
   "OPENAI_API_KEY"; "OPENAI_BASE_URL"; "CODEX_API_KEY"; "CODEX_ACCESS_TOKEN"]
  |> List.map (fun name -> name, None)

let configuration ?account_home client =
  let protocol = match client with Claude -> "claude-code" | Codex -> "codex-app-server" in
  let account = Option.fold ~none:"" ~some:(fun home ->
    Printf.sprintf "account-home = %S\n" home) account_home in
  Printf.sprintf {|
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
|} protocol account

let materialization ?account_home client =
  let source = configuration ?account_home client in
  let config = match Runtime_toml.parse_string source with
    | Ok config -> config | Error _ -> fail "native fixture must parse" in
  let binding = match config.Runtime_schema.bindings with
    | [binding] -> binding | _ -> fail "expected one native binding" in
  Runtime_instance.of_binding config binding

let materialize ?account_home client =
  match materialization ?account_home client with
  | Ok runtime -> runtime
  | Error reason -> fail (Runtime_config_error.string_of_drop_reason reason)

let child_environment runtime =
  match runtime.Runtime_instance.execution with
  (* Both clients start their CLI with the environment of the account they
     are authorized on, unchanged (plan D2-5 and D2-6). The table holds the
     account sealed, so the environment is read from the authorized account
     (plan D2-7). *)
  | Runtime_execution.Claude_code execution ->
    Runtime_official_account.environment
      (Runtime_account_access.account (Masc_test_deps.authorized_account execution.account_home))
  | Codex_app_server execution ->
    Runtime_official_account.environment
      (Runtime_account_access.account (Masc_test_deps.authorized_account execution.account_home))
  | Agent_core _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ -> fail "expected an official client"

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
          check (option string) "an undeclared account gets no profile directory"
            None (env_value "ANTHROPIC_CONFIG_DIR" child);
          (match runtime.execution with
           | Claude_code execution ->
             check (option string) "ordinary account file remains in admitted HOME"
               (Some (Filename.concat first ".claude.json"))
               (Runtime_claude_code.account_file (Runtime_official_account.Captured
                  (Runtime_account_access.account (Masc_test_deps.authorized_account execution.account_home))))
           | Agent_core _ | Codex_app_server _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
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
              (Runtime_claude_code.account_file (Runtime_official_account.Captured
                  (Runtime_account_access.account (Masc_test_deps.authorized_account execution.account_home))))
          | Codex_app_server _ -> ()
          | Agent_core _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ -> fail "expected native execution")))))

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
            (env_value key child);
          match client with
          | Codex -> ()
          | Claude ->
            with_env ["ANTHROPIC_CONFIG_DIR", Some replacement] (fun () ->
              check (option string)
                "the Anthropic profile directory is inside the declared directory"
                (Some (Filename.concat home "anthropic"))
                (env_value "ANTHROPIC_CONFIG_DIR" (child_environment runtime))))))))

let test_environment_copy client () =
  with_directory (fun home ->
    with_env (("HOME", Some home) :: environment) (fun () ->
      let runtime = materialize client in
      let first = child_environment runtime in
      Array.iteri (fun index entry ->
        if String.starts_with ~prefix:"HOME=" entry then
          first.(index) <- "HOME=/mutated-child-copy") first;
      check (option string) "spawn-array mutation cannot alter the admitted context"
        (Some home) (env_value "HOME" (child_environment runtime))))

let test_claude_credential_diagnosis () =
  with_directory (fun home ->
    with_env (("HOME", Some home) :: environment) (fun () ->
      with_env ["ANTHROPIC_API_KEY", Some "admitted-fixture-key"] (fun () ->
        let runtime = materialize Claude in
        with_env ["ANTHROPIC_API_KEY", None] (fun () ->
          match runtime.execution with
          | Runtime_execution.Claude_code execution ->
            check bool "refusal diagnosis uses the credential actually passed to this child"
              true (Runtime_claude_code.runs_on_environment_credential
                (Runtime_official_account.Captured
                  (Runtime_account_access.account (Masc_test_deps.authorized_account execution.account_home))))
          | Agent_core _ | Codex_app_server _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
            fail "expected Claude execution"))))

let test_private_codex_environment configured () =
  with_directory (fun home -> with_directory (fun private_home ->
    with_env (("HOME", Some home) :: environment) (fun () ->
      with_env ["OPENAI_API_KEY", Some "admitted-fixture-key"] (fun () ->
        let runtime = materialize Codex in
        let path = Filename.concat private_home "config.toml" in
        if configured then Out_channel.with_open_bin path (fun out ->
          output_string out {|model_provider = "fixture"
[model_providers.fixture]
name = "fixture"
base_url = "https://fixture.invalid"
wire_api = "responses"
env_key = "OPENAI_API_KEY"
|});
        Fun.protect ~finally:(fun () -> if configured then Unix.unlink path) (fun () ->
          with_env ["HOME", Some private_home; "OPENAI_API_KEY", Some "replacement-fixture-key"]
            (fun () -> match runtime.execution with
             | Runtime_execution.Codex_app_server execution ->
               let child = match Runtime_official_account.private_codex_environment
                 ~home:private_home
                 (Runtime_account_access.account (Masc_test_deps.authorized_account execution.account_home)) with
                 | Ok child -> child
                 | Error detail -> fail detail in
               check (option string) "private process uses the caller-owned verification store"
                 (Some private_home) (env_value "CODEX_HOME" child);
               check (option string) "private view retains the captured user environment"
                 (Some home) (env_value "HOME" child);
               check (option string) "private auth filter uses its declared keys and captured values"
                 (if configured then Some "admitted-fixture-key" else None)
                 (env_value "OPENAI_API_KEY" child);
               check string "private projection cannot change the original account scope"
                 (Filename.concat home ".codex")
                 (Runtime_account_access.home execution.account_home)
             | Agent_core _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
               fail "expected Codex execution"))))))

let with_cwd directory run =
  let previous = Sys.getcwd () in
  Fun.protect ~finally:(fun () -> Unix.chdir previous) (fun () ->
    Unix.chdir directory;
    run ())

let test_relative_cli_directory client () =
  with_directory (fun first -> with_directory (fun second ->
    let variable = match client with Claude -> "CLAUDE_CONFIG_DIR" | Codex -> "CODEX_HOME" in
    with_env (("HOME", Some first) :: environment) (fun () ->
      with_env [variable, Some "relative-cli-home"] (fun () ->
        with_cwd first (fun () ->
          let runtime = materialize client in
          with_cwd second (fun () ->
            check (option string) "relative CLI directory retains its admission cwd"
              (Some (Filename.concat first "relative-cli-home"))
              (env_value variable (child_environment runtime))))))))

let test_relative_user_home () =
  with_directory (fun directory ->
    with_cwd directory (fun () ->
      with_env (("HOME", Some "relative-user-home") :: environment) (fun () ->
        check bool "Claude keeps its rejection of a relative user HOME" true
          (Result.is_error (materialization Claude));
        let runtime = materialize Codex in
        check (option string) "Codex keeps its cwd-anchored relative HOME contract"
          (Some (Filename.concat directory "relative-user-home/.codex"))
          (env_value "CODEX_HOME" (child_environment runtime)))))

let test_reload_identity client credential_change () =
  with_directory (fun first -> with_directory (fun second ->
    let key = match client with Claude -> "ANTHROPIC_API_KEY" | Codex -> "OPENAI_API_KEY" in
    with_env (("HOME", Some first) :: environment) (fun () ->
      with_env [key, Some "admitted-fixture-key"] (fun () ->
        let previous = Runtime.For_testing.snapshot () in
        let path = Filename.temp_file "masc-native-account-reload-" ".toml" in
        Fun.protect ~finally:(fun () -> Runtime.For_testing.restore previous; Unix.unlink path)
          (fun () ->
            Out_channel.with_open_bin path (fun out -> output_string out (configuration client));
            let load () = match Runtime.init_default ~config_path:path with
              | Ok () -> () | Error detail -> fail detail in
            let snapshot () = Runtime.keeper_dispatch_snapshot ~keeper_name:"account-selection-fixture" in
            load ();
            let original = snapshot () in
            load ();
            check bool "unchanged effective selection preserves dispatch observations" true
              (Runtime.same_keeper_dispatch original (snapshot ()));
            let changed = if credential_change then [key, Some "replacement-fixture-key"]
              else ["HOME", Some second] in
            with_env changed (fun () ->
              load ();
              check bool "changed captured selection invalidates the old dispatch identity" false
                (Runtime.same_keeper_dispatch original (snapshot ()))))))))

let test_carrier_invariants () =
  with_directory (fun home ->
    with_env ["TMPDIR", Some home; "OPENAI_API_KEY", Some "unselected-fixture-key"] (fun () ->
      let capture declaration = Runtime_official_account.capture ~client:Codex ~declaration in
      let first = match capture (Some home) with
        | Ok selected -> selected | Error detail -> fail detail in
      check (option string) "public construction enforces explicit credential isolation"
        None (Runtime_official_account.environment_value first "OPENAI_API_KEY");
      check bool "the factory derives declaration provenance" true
        (Runtime_official_account.source first = Declared_directory);
      Unix.unsetenv "TMPDIR";
      Unix.putenv "TMPDIR" home;
      let equivalent = match capture (Some home) with
        | Ok selected -> selected | Error detail -> fail detail in
      check bool "environment order is not dispatch identity" true
        (Runtime_official_account.same first equivalent);
      List.iter (fun home -> check bool "invalid declared home is rejected at construction"
        true (Result.is_error (capture (Some home))))
        [""; "relative"; " /synthetic/padded "; "/synthetic/bad\000home"]))

let with_file path body run =
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path) (fun () ->
    Out_channel.with_open_bin path (fun out -> output_string out body);
    run ())

let test_declared_codex_credentials () =
  with_directory (fun source -> with_directory (fun private_home ->
    let body = {|model_provider = "custom"
[model_providers.custom]
name = "fixture"
base_url = "https://fixture.invalid"
wire_api = "responses"
env_key = "CUSTOM_GATEWAY_KEY"
env_http_headers = { "X-Fixture" = "CUSTOM_GATEWAY_HEADER" }
|} in
    with_file (Filename.concat source "config.toml") body (fun () ->
      let projected = match Runtime_verification_codex_home.project_config body with
        | Ok body -> body | Error detail -> fail detail in
      with_file (Filename.concat private_home "config.toml") projected (fun () ->
        with_env (("HOME", Some source) :: environment) (fun () ->
          with_env ["CUSTOM_GATEWAY_KEY", Some "declared-key-a";
            "CUSTOM_GATEWAY_HEADER", Some "declared-header-a";
            "UNDECLARED_GATEWAY_KEY", Some "undeclared-key"] (fun () ->
            let runtime = materialize ~account_home:source Codex in
            with_env ["CUSTOM_GATEWAY_KEY", Some "declared-key-b";
              "CUSTOM_GATEWAY_HEADER", Some "declared-header-b"] (fun () ->
              match runtime.execution with
              | Runtime_execution.Codex_app_server execution ->
                let child = match Runtime_official_account.private_codex_environment
                  ~home:private_home
                  (Runtime_account_access.account (Masc_test_deps.authorized_account execution.account_home)) with
                  | Ok child -> child | Error detail -> fail detail in
                check (option string) "declared env_key retains the admitted value"
                  (Some "declared-key-a") (env_value "CUSTOM_GATEWAY_KEY" child);
                check (option string) "declared header retains the admitted value"
                  (Some "declared-header-a") (env_value "CUSTOM_GATEWAY_HEADER" child);
                check (option string) "undeclared custom key cannot enter the child"
                  None (env_value "UNDECLARED_GATEWAY_KEY" child)
              | Agent_core _ | Claude_code _ | Antigravity_cli _ | Muse_serve _ | Vibe_cli _ ->
                fail "expected Codex execution")))))))

let test_retired_codex_profiles () =
  with_directory (fun home ->
    List.iter (fun body ->
      with_file (Filename.concat home "config.toml") body (fun () ->
        check bool "unsupported profile selection fails during materialization" true
          (Result.is_error (materialization ~account_home:home Codex))))
      ["profile = \"gateway\""; "profile = 42";
       "[profiles.gateway]\nmodel_provider = \"custom\""])

let test_missing_codex_home () =
  with_directory (fun directory ->
    with_cwd directory (fun () ->
    with_env environment (fun () ->
      List.iter (fun home -> List.iter (fun codex_home ->
        with_env ["HOME", home; "CODEX_HOME", codex_home] (fun () ->
          check bool "an absent or empty HOME cannot select a cwd credential store" true
            (Result.is_error (materialization Codex)))) [None; Some ""])
        [None; Some ""];
      with_env ["HOME", Some ""; "CODEX_HOME", Some directory] (fun () ->
        check (option string) "a valid inherited CLI directory does not require HOME"
          (Some directory) (env_value "CODEX_HOME" (child_environment (materialize Codex)))))))

let () =
  run "native account selection"
  ["admission to execution",
    [test_case "Claude inherited user home is captured" `Quick (test_inherited_home Claude);
     test_case "Codex inherited user home is captured" `Quick (test_inherited_home Codex);
     test_case "Claude inherited config directory is captured" `Quick (test_inherited_directory Claude);
     test_case "Codex inherited config directory is captured" `Quick (test_inherited_directory Codex);
     test_case "Claude inherited credential environment is captured" `Quick (test_inherited_credential Claude);
     test_case "Codex inherited credential environment is captured" `Quick (test_inherited_credential Codex);
     test_case "Claude explicit directory preserves isolation" `Quick (test_explicit_directory Claude);
     test_case "Codex explicit directory preserves isolation" `Quick (test_explicit_directory Codex)];
   "captured context boundaries",
    [test_case "Claude spawn environment is a copy" `Quick (test_environment_copy Claude);
     test_case "Codex spawn environment is a copy" `Quick (test_environment_copy Codex);
     test_case "Claude refusal diagnosis retains admitted credentials" `Quick test_claude_credential_diagnosis;
     test_case "Codex private home blocks unconfigured credentials" `Quick (test_private_codex_environment false);
     test_case "Codex private home retains declared captured credentials" `Quick (test_private_codex_environment true);
     test_case "Codex declared provider retains captured credential keys" `Quick test_declared_codex_credentials;
     test_case "Codex retired profiles fail before dispatch" `Quick test_retired_codex_profiles;
     test_case "Codex empty or missing HOME cannot select a cwd store" `Quick test_missing_codex_home;
     test_case "Claude relative CLI directory is captured" `Quick (test_relative_cli_directory Claude);
     test_case "Codex relative CLI directory is captured" `Quick (test_relative_cli_directory Codex);
     test_case "relative user HOME keeps client-specific admission" `Quick test_relative_user_home;
     test_case "Claude reload notices an inherited home change" `Quick (test_reload_identity Claude false);
     test_case "Codex reload notices an inherited home change" `Quick (test_reload_identity Codex false);
     test_case "Claude reload notices captured credential changes" `Quick (test_reload_identity Claude true);
     test_case "Codex reload notices captured credential changes" `Quick (test_reload_identity Codex true);
     test_case "private carrier preserves its invariants" `Quick test_carrier_invariants]]
