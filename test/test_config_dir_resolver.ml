module Lib = Masc

open Alcotest

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f

let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  let rec loop idx =
    if idx + needle_len > hay_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  if needle_len = 0 then true else loop 0

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file (Filename.concat config "runtime.toml") "";
  config

let make_toml_only_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p config;
  write_file
    (Filename.concat config "runtime.toml")
    {|
[providers.ollama]
display-name = "Ollama Local"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen]
api-name = "qwen3.5:35b-a3b-nvfp4"
max-context = 128000
tools-support = true
streaming = true

[ollama.qwen]
is-default = true
max-concurrent = 1

[runtime.primary]
members = ["ollama.qwen"]
strategy = "failover"

[runtime.primary]
tiers = ["primary"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "runtime.primary"
|};
  config

let make_inputs ?env_base_path ?env_config_dir ?env_personas_dir
    ?(cwd = "/tmp/cwd") ?(executable_name = "/tmp/bin/masc") () =
  Config_dir_resolver.
    {
      cwd;
      executable_name;
      env_base_path;
      env_config_dir;
      env_personas_dir;
    }

let test_sanitize_inherited_test_env_opt_drops_captured_parent_shell_value () =
  let actual =
    Config_dir_resolver.sanitize_inherited_test_env_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/tmp/captured-shell/masc/config")
      ~current:(Some "/tmp/captured-shell/masc/config")
  in
  check (option string) "same captured parent-shell value ignored" None actual

let test_sanitize_inherited_test_env_opt_keeps_runtime_override () =
  let actual =
    Config_dir_resolver.sanitize_inherited_test_env_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/tmp/captured-shell/masc/config")
      ~current:(Some "/tmp/test-config-root")
  in
  check (option string) "runtime override preserved"
    (Some "/tmp/test-config-root") actual

let test_sanitize_inherited_test_base_path_opt_drops_captured_home_path () =
  let actual =
    Config_dir_resolver.sanitize_inherited_test_base_path_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/tmp/captured-home/me")
      ~current:(Some "/tmp/captured-home/me")
      ~home:(Some "/tmp/captured-home/me")
  in
  check (option string) "same captured MASC_BASE_PATH ignored" None actual

let test_sanitize_inherited_test_base_path_opt_keeps_sibling_prefix_path () =
  let actual =
    Config_dir_resolver.sanitize_inherited_test_base_path_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/tmp/captured-home/me2")
      ~current:(Some "/tmp/captured-home/me2")
      ~home:(Some "/tmp/captured-home/me")
  in
  check (option string) "sibling path preserved"
    (Some "/tmp/captured-home/me2") actual

let test_sanitize_inherited_test_base_path_opt_keeps_process_temp_path () =
  let actual =
    Config_dir_resolver.sanitize_inherited_test_base_path_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/tmp/test-oas-worker-base")
      ~current:(Some "/tmp/test-oas-worker-base")
      ~home:(Some "/tmp/captured-home/me")
  in
  check (option string) "process temp base preserved"
    (Some "/tmp/test-oas-worker-base") actual

let test_sanitize_inherited_test_env_opt_keeps_value_with_opt_in () =
  let actual =
    Config_dir_resolver.sanitize_inherited_test_env_opt
      ~running_under_test_executable:true ~allow_inherited:true
      ~initial:(Some "/tmp/captured-shell/masc/config")
      ~current:(Some "/tmp/captured-shell/masc/config")
  in
  check (option string) "opt-in preserves config-path override"
    (Some "/tmp/captured-shell/masc/config") actual

let test_inputs_from_env_honors_config_path_override_opt_in () =
  with_temp_dir "config-dir-inputs-env-config" @@ fun root ->
  let config = make_config_root root in
  let personas = Filename.concat config "personas" in
  with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" (Some "true") @@ fun () ->
  with_env "MASC_CONFIG_DIR" (Some config) @@ fun () ->
  with_env "MASC_PERSONAS_DIR" (Some personas) @@ fun () ->
  let inputs = Config_dir_resolver.inputs_from_env () in
  check (option string) "inputs preserve config env" (Some config)
    inputs.env_config_dir;
  check (option string) "inputs preserve personas env" (Some personas)
    inputs.env_personas_dir;
  let resolution = Config_dir_resolver.resolve_with inputs in
  check string "root source" "env"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "personas env exists" true resolution.personas.exists

let test_inputs_from_env_honors_base_path_override_opt_in () =
  with_temp_dir "config-dir-inputs-env-base" @@ fun root ->
  let base = Filename.concat root "base" in
  let _config = make_config_root (Filename.concat base Common.masc_dirname) in
  with_env "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE" (Some "true") @@ fun () ->
  with_env "MASC_CONFIG_DIR" None @@ fun () ->
  with_env "MASC_PERSONAS_DIR" None @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base) @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" (Some base) @@ fun () ->
  let inputs = Config_dir_resolver.inputs_from_env () in
  check (option string) "inputs preserve base env" (Some base)
    inputs.env_base_path;
  let resolution = Config_dir_resolver.resolve_with inputs in
  check string "root source" "local_masc"
    (Config_dir_resolver.source_to_string resolution.config_root.source)

let test_inputs_from_env_survives_deleted_cwd () =
  with_temp_dir "config-dir-deleted-cwd" @@ fun root ->
  let parent = Filename.concat root "parent" in
  let doomed = Filename.concat parent "doomed" in
  let base = Filename.concat root "base" in
  Unix.mkdir parent 0o755;
  Unix.mkdir doomed 0o755;
  let _config = make_config_root (Filename.concat base Common.masc_dirname) in
  with_env "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE" (Some "true") @@ fun () ->
  with_env "MASC_CONFIG_DIR" None @@ fun () ->
  with_env "MASC_PERSONAS_DIR" None @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base) @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" (Some base) @@ fun () ->
  let saved_cwd = Sys.getcwd () in
  Unix.chdir doomed;
  Fun.protect
    ~finally:(fun () ->
      Unix.chdir saved_cwd;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.rmdir doomed;
      let inputs = Config_dir_resolver.inputs_from_env () in
      check string "deleted cwd falls back to base path" base inputs.cwd;
      let resolution = Config_dir_resolver.resolve_with inputs in
      check string "root source" "local_masc"
        (Config_dir_resolver.source_to_string resolution.config_root.source))

let test_normalize_masc_base_path_input_canonicalizes_explicit_path () =
  let actual =
    Env_config_core.normalize_masc_base_path_input
      "/tmp/synthetic-masc-base/././/.masc//"
  in
  check string "canonical explicit base path" "/tmp/synthetic-masc-base" actual

let test_env_override_valid () =
  with_temp_dir "config-dir-env" @@ fun root ->
  let config = make_config_root root in
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~env_config_dir:config ())
  in
  check string "status" "ready"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "env"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "prompts exists" true resolution.prompts.exists

let test_env_override_valid_with_toml_only_root () =
  with_temp_dir "config-dir-env-toml" @@ fun root ->
  let config = make_toml_only_config_root root in
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~env_config_dir:config ())
  in
  check string "status" "warn"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "env"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "prompts absent in toml-only root" false resolution.prompts.exists

let test_env_override_invalid_no_fallback () =
  let invalid = "/tmp/definitely-missing-masc-config-dir" in
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~env_config_dir:invalid ~cwd:"/tmp/other"
         ~executable_name:"/tmp/other/bin/masc" ())
  in
  check string "status" "invalid_env"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "invalid_env"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "warnings present" true (resolution.warnings <> [])

let test_cwd_config_is_seed_only_not_fallback () =
  with_temp_dir "config-dir-cwd" @@ fun cwd ->
  let _config = make_config_root cwd in
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~cwd ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "missing"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "missing"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "warnings present" true (resolution.warnings <> [])

let test_cwd_config_remains_seed_only () =
  with_temp_dir "config-dir-cwd-seed-only" @@ fun cwd ->
  let _config = make_config_root cwd in
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~cwd ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "missing"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "missing"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "keepers hidden because repo config is not active"
    false resolution.keepers.exists

let test_executable_relative_config_is_seed_only_not_fallback () =
  with_temp_dir "config-dir-exe" @@ fun root ->
  let repo = Filename.concat root "repo" in
  let _config = make_config_root repo in
  let bin_dir = Filename.concat repo "bin" in
  mkdir_p bin_dir;
  let executable_name = Filename.concat bin_dir "masc" in
  write_file executable_name "#!/bin/sh\n";
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~cwd:"/tmp/nonexistent-cwd" ~executable_name ())
  in
  check string "status" "missing"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "missing"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "personas hidden because repo config is not active"
    false resolution.personas.exists

let test_external_config_is_not_a_fallback () =
  with_temp_dir "config-dir-external" @@ fun external_root ->
  let external_config_root = Filename.concat external_root Common.masc_dirname in
  ignore (make_config_root external_config_root);
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~cwd:"/tmp/missing-cwd"
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "missing"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "missing"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "prompts hidden" false resolution.prompts.exists

let test_local_masc_fallback_ignores_external_config () =
  with_temp_dir "config-dir-local" @@ fun root ->
  let target = Filename.concat root "target" in
  let local_config = make_config_root (Filename.concat target Common.masc_dirname) in
  let external_root = Filename.concat root "external" in
  ignore (make_config_root (Filename.concat external_root Common.masc_dirname));
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~cwd:root ~env_base_path:target
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "local_masc"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check string "root path" local_config resolution.config_root.path

let test_local_masc_fallback_collapses_explicit_masc_dir () =
  with_temp_dir "config-dir-local-masc" @@ fun root ->
  let target = Filename.concat root "target" in
  let local_config = make_config_root (Filename.concat target Common.masc_dirname) in
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~cwd:root
         ~env_base_path:(Filename.concat target Common.masc_dirname)
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "local_masc"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check string "root path" local_config resolution.config_root.path

let test_no_legacy_me_root_fallback () =
  with_temp_dir "config-dir-no-legacy" @@ fun me_root ->
  let _repo_root =
    Filename.concat me_root "workspace/yousleepwhen/masc"
  in
  let resolution =
    Config_dir_resolver.resolve_with
      (make_inputs ~cwd:"/tmp/missing-cwd"
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "missing"
    (Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "missing"
    (Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "warning present" true (resolution.warnings <> [])

(* ================================================================ *)
(* personas_dirs tests                                              *)
(* ================================================================ *)

let test_personas_dirs_default_repo_only () =
  with_temp_dir "pd-default" @@ fun root ->
  let config = make_config_root root in
  let inputs = make_inputs ~env_config_dir:config () in
  let resolution = Config_dir_resolver.resolve_with inputs in
  let dirs = Config_dir_resolver.personas_dirs_with inputs resolution in
  check (list string) "repo personas only"
    [ Filename.concat config "personas" ] dirs

let test_personas_dirs_ignores_external_personas () =
  with_temp_dir "pd-external" @@ fun root ->
  let config = make_config_root root in
  let external_root = Filename.concat root "external" in
  let external_personas = Filename.concat external_root ".masc/personas" in
  mkdir_p external_personas;
  let inputs = make_inputs ~env_config_dir:config () in
  let resolution = Config_dir_resolver.resolve_with inputs in
  let dirs = Config_dir_resolver.personas_dirs_with inputs resolution in
  check (list string) "repo personas only despite external personas"
    [ Filename.concat config "personas" ] dirs

let test_personas_dirs_env_override_is_sole_source () =
  with_temp_dir "pd-env" @@ fun root ->
  let env_personas = Filename.concat root "env-personas" in
  mkdir_p env_personas;
  let external_root = Filename.concat root "external" in
  let external_personas = Filename.concat external_root ".masc/personas" in
  mkdir_p external_personas;
  let inputs = make_inputs ~env_personas_dir:env_personas () in
  let resolution = Config_dir_resolver.resolve_with inputs in
  let dirs = Config_dir_resolver.personas_dirs_with inputs resolution in
  (* MASC_PERSONAS_DIR overrides: only the env dir, no secondary dir *)
  check (list string) "env override only" [ env_personas ] dirs

let test_personas_dirs_ignores_base_path_fallback () =
  with_temp_dir "pd-base" @@ fun root ->
  let config_root = Filename.concat root "config" in
  mkdir_p (Filename.concat config_root "prompts");
  mkdir_p (Filename.concat config_root "keepers");
  mkdir_p (Filename.concat config_root "personas");
  write_file (Filename.concat config_root "runtime.toml") "";
  let base = Filename.dirname config_root in
  let base_personas = Filename.concat (Filename.concat base Common.masc_dirname) "personas" in
  mkdir_p base_personas;
  let config_personas = Filename.concat config_root "personas" in
  let inputs = make_inputs ~env_config_dir:config_root ~env_base_path:base
      ~cwd:root () in
  let resolution = Config_dir_resolver.resolve_with inputs in
  let dirs = Config_dir_resolver.personas_dirs_with inputs resolution in
  check (list string) "base path fallback ignored"
    [ config_personas ] dirs

(* RFC-0121 — .masc/<sub> sub-directory accessors. The accessors derive
   layout from [base_path] without filesystem access, so we only check
   the constructed paths. *)

let test_rfc0121_masc_root () =
  check string "masc_root concats .masc"
    "/x/.masc"
    (Config_dir_resolver.masc_root ~base_path:"/x")

let test_rfc0121_auth_dir () =
  check string "auth_dir under .masc"
    "/x/.masc/auth"
    (Config_dir_resolver.auth_dir ~base_path:"/x")

let test_rfc0121_credentials_dir () =
  check string "credentials_dir under .masc"
    "/x/.masc/credentials"
    (Config_dir_resolver.credentials_dir ~base_path:"/x")

let test_rfc0121_agent_runtime_dir () =
  check string "agent_runtime under .masc/runtime/agent"
    "/x/.masc/runtime/agent"
    (Config_dir_resolver.agent_runtime_dir ~base_path:"/x")

let test_rfc0121_repos_dir () =
  check string "repos under .masc"
    "/x/.masc/repos"
    (Config_dir_resolver.repos_dir ~base_path:"/x")

let test_rfc0121_tmp_dir () =
  check string "tmp under .masc"
    "/x/.masc/tmp"
    (Config_dir_resolver.tmp_dir ~base_path:"/x")

let test_rfc0121_locks_dir () =
  check string "locks under .masc"
    "/x/.masc/locks"
    (Config_dir_resolver.locks_dir ~base_path:"/x")

let test_rfc0121_data_dir () =
  check string "data is sibling of .masc"
    "/x/data"
    (Config_dir_resolver.data_dir ~base_path:"/x")

let test_rfc0121_repositories_toml () =
  check string "repositories.toml under .masc/config"
    "/x/.masc/config/repositories.toml"
    (Config_dir_resolver.repositories_toml_path ~base_path:"/x")

let test_rfc0121_keeper_repo_mappings_toml () =
  check string "keeper_repo_mappings.toml under .masc/config"
    "/x/.masc/config/keeper_repo_mappings.toml"
    (Config_dir_resolver.keeper_repo_mappings_toml_path ~base_path:"/x")

let test_rfc0121_masc_root_agrees_with_common () =
  (* SSOT bridge — resolver helper must produce the same path as the
     pre-existing [Common] helper that callers historically used. *)
  let bp = "/some/where" in
  check string "resolver == Common"
    (Common.masc_dir_from_base_path ~base_path:bp)
    (Config_dir_resolver.masc_root ~base_path:bp)

let test_current_working_dir_returns_absolute () =
  let cwd = Config_dir_resolver.current_working_dir () in
  check bool "cwd is absolute" true (not (Filename.is_relative cwd))

let test_current_working_dir_survives_deleted_cwd () =
  with_temp_dir "config-dir-current-cwd-deleted" @@ fun root ->
  let home = Filename.concat root "home" in
  let doomed = Filename.concat root "doomed" in
  Unix.mkdir home 0o755;
  Unix.mkdir doomed 0o755;
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_env "HOME" (Some home) @@ fun () ->
  Config_dir_resolver.reset ();
  let saved_cwd = Sys.getcwd () in
  Unix.chdir doomed;
  Fun.protect
    ~finally:(fun () ->
      Unix.chdir saved_cwd;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.rmdir doomed;
      check string "deleted cwd falls back to HOME" home
        (Config_dir_resolver.current_working_dir ()))

let test_base_path_or_cwd_honors_env () =
  with_env "MASC_BASE_PATH" (Some "/tmp/masc-base-from-env") (fun () ->
    Config_dir_resolver.reset ();
    check string "base_path_or_cwd uses env" "/tmp/masc-base-from-env"
      (Config_dir_resolver.base_path_or_cwd ()))

let test_base_path_or_cwd_anchors_relative_env_to_cwd () =
  with_temp_dir "config-dir-relative-base" @@ fun root ->
  let cwd = Filename.concat root "cwd" in
  Unix.mkdir cwd 0o755;
  with_env "MASC_BASE_PATH" (Some "relative-root") (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None (fun () ->
      Config_dir_resolver.reset ();
      let saved_cwd = Sys.getcwd () in
      Unix.chdir cwd;
      Fun.protect
        ~finally:(fun () ->
          Unix.chdir saved_cwd;
          Config_dir_resolver.reset ())
        (fun () ->
          (* The resolver anchors relative base_path to [Sys.getcwd ()],
             which returns the symlink-canonical cwd (on macOS the temp dir
             [/var/…] resolves to [/private/var/…]). Canonicalize the known
             cwd so the expected value matches the resolver's real anchor. *)
          check string "base_path_or_cwd anchors relative env under cwd"
            (Filename.concat (Unix.realpath cwd) "relative-root")
            (Config_dir_resolver.base_path_or_cwd ()))))

let test_base_path_or_cwd_falls_back_to_cwd () =
  with_env "MASC_BASE_PATH" None (fun () ->
    Config_dir_resolver.reset ();
    check string "base_path_or_cwd falls back to cwd"
      (Config_dir_resolver.current_working_dir ())
      (Config_dir_resolver.base_path_or_cwd ()))

let () =
  run "config_dir_resolver"
    [
      ( "resolution",
        [
          test_case "env override valid" `Quick test_env_override_valid;
          test_case "env override valid with toml-only root" `Quick
            test_env_override_valid_with_toml_only_root;
          test_case "env override invalid does not fallback" `Quick
            test_env_override_invalid_no_fallback;
          test_case "cwd config is seed-only, not fallback" `Quick
            test_cwd_config_is_seed_only_not_fallback;
          test_case "cwd config remains seed-only" `Quick
            test_cwd_config_remains_seed_only;
          test_case "exe-relative config is seed-only, not fallback" `Quick
            test_executable_relative_config_is_seed_only_not_fallback;
          test_case "local masc fallback ignores external config" `Quick
            test_local_masc_fallback_ignores_external_config;
          test_case "local masc fallback collapses explicit .masc dir"
            `Quick test_local_masc_fallback_collapses_explicit_masc_dir;
          test_case "external config is not a fallback" `Quick
            test_external_config_is_not_a_fallback;
          test_case "does not fallback to legacy me_root repo path" `Quick
            test_no_legacy_me_root_fallback;
        ] );
      ( "personas_dirs",
        [
          test_case "default returns repo personas only" `Quick
            test_personas_dirs_default_repo_only;
          test_case "ignores secondary personas dir" `Quick
            test_personas_dirs_ignores_external_personas;
          test_case "MASC_PERSONAS_DIR overrides as sole source" `Quick
            test_personas_dirs_env_override_is_sole_source;
          test_case "ignores base_path .masc/personas fallback" `Quick
            test_personas_dirs_ignores_base_path_fallback;
        ] );
      ( "test_env_sanitization",
        [
          test_case "drops captured parent-shell config env by default" `Quick
            test_sanitize_inherited_test_env_opt_drops_captured_parent_shell_value;
          test_case "keeps runtime override" `Quick
            test_sanitize_inherited_test_env_opt_keeps_runtime_override;
          test_case "drops captured parent-shell base path by default" `Quick
            test_sanitize_inherited_test_base_path_opt_drops_captured_home_path;
          test_case "keeps sibling prefix base path" `Quick
            test_sanitize_inherited_test_base_path_opt_keeps_sibling_prefix_path;
          test_case "keeps process temp base path" `Quick
            test_sanitize_inherited_test_base_path_opt_keeps_process_temp_path;
          test_case "opt-in preserves config-path override" `Quick
            test_sanitize_inherited_test_env_opt_keeps_value_with_opt_in;
          test_case "inputs_from_env honors config-path override opt-in" `Quick
            test_inputs_from_env_honors_config_path_override_opt_in;
          test_case "inputs_from_env honors base-path override opt-in" `Quick
            test_inputs_from_env_honors_base_path_override_opt_in;
          test_case "inputs_from_env survives deleted cwd" `Quick
            test_inputs_from_env_survives_deleted_cwd;
          test_case "canonicalizes explicit base path" `Quick
            test_normalize_masc_base_path_input_canonicalizes_explicit_path;
        ] );
      ( "rfc_0121_accessors",
        [
          test_case "masc_root" `Quick test_rfc0121_masc_root;
          test_case "auth_dir" `Quick test_rfc0121_auth_dir;
          test_case "credentials_dir" `Quick test_rfc0121_credentials_dir;
          test_case "agent_runtime_dir" `Quick test_rfc0121_agent_runtime_dir;
          test_case "repos_dir" `Quick test_rfc0121_repos_dir;
          test_case "tmp_dir" `Quick test_rfc0121_tmp_dir;
          test_case "locks_dir" `Quick test_rfc0121_locks_dir;
          test_case "data_dir sibling of .masc" `Quick test_rfc0121_data_dir;
          test_case "repositories_toml under config" `Quick
            test_rfc0121_repositories_toml;
          test_case "keeper_repo_mappings_toml under config" `Quick
            test_rfc0121_keeper_repo_mappings_toml;
          test_case "masc_root agrees with Common" `Quick
            test_rfc0121_masc_root_agrees_with_common;
        ] );
      ( "path_ssot_helpers",
        [
          test_case "current_working_dir returns an absolute path" `Quick
            test_current_working_dir_returns_absolute;
          test_case "current_working_dir survives deleted cwd" `Quick
            test_current_working_dir_survives_deleted_cwd;
          test_case "base_path_or_cwd honors MASC_BASE_PATH" `Quick
            test_base_path_or_cwd_honors_env;
          test_case "base_path_or_cwd anchors relative MASC_BASE_PATH"
            `Quick test_base_path_or_cwd_anchors_relative_env_to_cwd;
          test_case "base_path_or_cwd falls back to cwd" `Quick
            test_base_path_or_cwd_falls_back_to_cwd;
        ] );
    ]
