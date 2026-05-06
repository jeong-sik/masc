module Lib = Masc_mcp

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
  write_file (Filename.concat config "cascade.json") "{}";
  write_file (Filename.concat config "tool_policy.toml") "# test marker\n";
  config

let make_toml_only_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file
    (Filename.concat config "cascade.toml")
    {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|};
  write_file (Filename.concat config "tool_policy.toml") "# test marker\n";
  config

let make_inputs ?env_base_path ?env_config_dir ?env_personas_dir
    ?env_home ?(cwd = "/tmp/cwd") ?(executable_name = "/tmp/bin/masc-mcp") () =
  Lib.Config_dir_resolver.
    {
      cwd;
      executable_name;
      env_base_path;
      env_config_dir;
      env_personas_dir;
      env_home;
    }

let test_sanitize_inherited_test_env_opt_drops_captured_parent_shell_value () =
  let actual =
    Lib.Config_dir_resolver.sanitize_inherited_test_env_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/Users/dancer/me/workspace/yousleepwhen/masc-mcp/config")
      ~current:(Some "/Users/dancer/me/workspace/yousleepwhen/masc-mcp/config")
  in
  check (option string) "same captured parent-shell value ignored" None actual

let test_sanitize_inherited_test_env_opt_keeps_runtime_override () =
  let actual =
    Lib.Config_dir_resolver.sanitize_inherited_test_env_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/Users/dancer/me/workspace/yousleepwhen/masc-mcp/config")
      ~current:(Some "/tmp/test-config-root")
  in
  check (option string) "runtime override preserved"
    (Some "/tmp/test-config-root") actual

let test_sanitize_inherited_test_base_path_opt_drops_captured_home_path () =
  let actual =
    Lib.Config_dir_resolver.sanitize_inherited_test_base_path_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/Users/dancer/me")
      ~current:(Some "/Users/dancer/me")
      ~home:(Some "/Users/dancer/me")
  in
  check (option string) "same captured MASC_BASE_PATH ignored" None actual

let test_sanitize_inherited_test_base_path_opt_keeps_sibling_prefix_path () =
  let actual =
    Lib.Config_dir_resolver.sanitize_inherited_test_base_path_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/Users/dancer/me2")
      ~current:(Some "/Users/dancer/me2")
      ~home:(Some "/Users/dancer/me")
  in
  check (option string) "sibling path preserved"
    (Some "/Users/dancer/me2") actual

let test_sanitize_inherited_test_base_path_opt_keeps_process_temp_path () =
  let actual =
    Lib.Config_dir_resolver.sanitize_inherited_test_base_path_opt
      ~running_under_test_executable:true ~allow_inherited:false
      ~initial:(Some "/tmp/test-oas-worker-base")
      ~current:(Some "/tmp/test-oas-worker-base")
      ~home:(Some "/Users/dancer/me")
  in
  check (option string) "process temp base preserved"
    (Some "/tmp/test-oas-worker-base") actual

let test_sanitize_inherited_test_env_opt_keeps_value_with_opt_in () =
  let actual =
    Lib.Config_dir_resolver.sanitize_inherited_test_env_opt
      ~running_under_test_executable:true ~allow_inherited:true
      ~initial:(Some "/Users/dancer/me/workspace/yousleepwhen/masc-mcp/config")
      ~current:(Some "/Users/dancer/me/workspace/yousleepwhen/masc-mcp/config")
  in
  check (option string) "opt-in preserves config-path override"
    (Some "/Users/dancer/me/workspace/yousleepwhen/masc-mcp/config") actual

let test_normalize_masc_base_path_input_canonicalizes_explicit_path () =
  let actual =
    Env_config_core.normalize_masc_base_path_input
      "/Users/dancer/me/././/.masc//"
  in
  check string "canonical explicit base path" "/Users/dancer/me" actual

let test_env_override_valid () =
  with_temp_dir "config-dir-env" @@ fun root ->
  let config = make_config_root root in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~env_config_dir:config ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "env"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "cascade authoring missing" false resolution.cascade_authoring.exists;
  check bool "cascade exists" true resolution.cascade.exists;
  check bool "prompts exists" true resolution.prompts.exists

let test_env_override_valid_with_toml_only_root () =
  with_temp_dir "config-dir-env-toml" @@ fun root ->
  let config = make_toml_only_config_root root in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~env_config_dir:config ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "env"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "cascade authoring exists" true resolution.cascade_authoring.exists;
  check string "cascade authoring path targets toml"
    (Filename.concat config "cascade.toml")
    resolution.cascade_authoring.path;
  check bool "cascade exists via toml source" true resolution.cascade.exists;
  check string "cascade runtime path still targets json"
    (Filename.concat config "cascade.json")
    resolution.cascade.path

let test_env_override_invalid_no_fallback () =
  let invalid = "/tmp/definitely-missing-masc-config-dir" in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~env_config_dir:invalid ~cwd:"/tmp/other"
         ~executable_name:"/tmp/other/bin/masc-mcp" ())
  in
  check string "status" "invalid_env"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "invalid_env"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "cascade missing" false resolution.cascade.exists;
  check bool "warnings present" true (resolution.warnings <> [])

let test_cwd_fallback_disabled_by_default () =
  with_temp_dir "config-dir-cwd" @@ fun cwd ->
  let _config = make_config_root cwd in
  with_env "MASC_ALLOW_REPO_CONFIG_FALLBACK" None @@ fun () ->
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "missing"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "missing"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "cascade hidden when repo fallback disabled"
    false resolution.cascade.exists;
  check bool "warning mentions opt-in" true
    (List.exists
       (string_contains ~needle:"MASC_ALLOW_REPO_CONFIG_FALLBACK=true")
       resolution.warnings)

let test_cwd_fallback_opt_in () =
  with_temp_dir "config-dir-cwd-opt-in" @@ fun cwd ->
  let _config = make_config_root cwd in
  with_env "MASC_ALLOW_REPO_CONFIG_FALLBACK" (Some "true") @@ fun () ->
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "cwd"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "keepers exists" true resolution.keepers.exists

let test_executable_relative_fallback_opt_in () =
  with_temp_dir "config-dir-exe" @@ fun root ->
  let repo = Filename.concat root "repo" in
  let _config = make_config_root repo in
  let bin_dir = Filename.concat repo "bin" in
  mkdir_p bin_dir;
  let executable_name = Filename.concat bin_dir "masc-mcp" in
  write_file executable_name "#!/bin/sh\n";
  with_env "MASC_ALLOW_REPO_CONFIG_FALLBACK" (Some "true") @@ fun () ->
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd:"/tmp/nonexistent-cwd" ~executable_name ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "exe_relative"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "personas exists" true resolution.personas.exists

let test_home_masc_fallback () =
  with_temp_dir "config-dir-home" @@ fun home ->
  let home_masc_root = Filename.concat home Common.masc_dirname in
  let config = make_config_root home_masc_root in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~env_home:home ~cwd:"/tmp/missing-cwd"
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "home_masc"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check string "root path" config resolution.config_root.path;
  check bool "prompts exists" true resolution.prompts.exists

let test_local_masc_fallback_precedes_home_masc () =
  with_temp_dir "config-dir-local" @@ fun root ->
  let target = Filename.concat root "target" in
  let local_config = make_config_root (Filename.concat target Common.masc_dirname) in
  let home = Filename.concat root "home" in
  ignore (make_config_root (Filename.concat home Common.masc_dirname));
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd:root ~env_base_path:target ~env_home:home
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "local_masc"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check string "root path" local_config resolution.config_root.path

let test_local_masc_fallback_collapses_explicit_masc_dir () =
  with_temp_dir "config-dir-local-masc" @@ fun root ->
  let target = Filename.concat root "target" in
  let local_config = make_config_root (Filename.concat target Common.masc_dirname) in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd:root
         ~env_base_path:(Filename.concat target Common.masc_dirname)
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "local_masc"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check string "root path" local_config resolution.config_root.path

let test_no_legacy_me_root_fallback () =
  with_temp_dir "config-dir-no-legacy" @@ fun me_root ->
  let _repo_root =
    Filename.concat me_root "workspace/yousleepwhen/masc-mcp"
  in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd:"/tmp/missing-cwd"
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "missing"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "missing"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "warning present" true (resolution.warnings <> [])

(* ================================================================ *)
(* personas_dirs tests                                              *)
(* ================================================================ *)

let test_personas_dirs_default_repo_only () =
  with_temp_dir "pd-default" @@ fun root ->
  let config = make_config_root root in
  let inputs = make_inputs ~env_config_dir:config () in
  let resolution = Lib.Config_dir_resolver.resolve_with inputs in
  let dirs = Lib.Config_dir_resolver.personas_dirs_with inputs resolution in
  check (list string) "repo personas only"
    [ Filename.concat config "personas" ] dirs

let test_personas_dirs_ignores_home_fallback () =
  with_temp_dir "pd-home" @@ fun root ->
  let config = make_config_root root in
  let home = Filename.concat root "home" in
  let home_personas = Filename.concat home ".masc/personas" in
  mkdir_p home_personas;
  let inputs = make_inputs ~env_config_dir:config ~env_home:home () in
  let resolution = Lib.Config_dir_resolver.resolve_with inputs in
  let dirs = Lib.Config_dir_resolver.personas_dirs_with inputs resolution in
  check (list string) "repo personas only despite HOME fallback"
    [ Filename.concat config "personas" ] dirs

let test_personas_dirs_env_override_is_sole_source () =
  with_temp_dir "pd-env" @@ fun root ->
  let env_personas = Filename.concat root "env-personas" in
  mkdir_p env_personas;
  let home = Filename.concat root "home" in
  let home_personas = Filename.concat home ".masc/personas" in
  mkdir_p home_personas;
  let inputs = make_inputs ~env_personas_dir:env_personas ~env_home:home () in
  let resolution = Lib.Config_dir_resolver.resolve_with inputs in
  let dirs = Lib.Config_dir_resolver.personas_dirs_with inputs resolution in
  (* MASC_PERSONAS_DIR overrides: only the env dir, no home dir *)
  check (list string) "env override only" [ env_personas ] dirs

let test_personas_dirs_ignores_base_path_fallback () =
  with_temp_dir "pd-base" @@ fun root ->
  let config_root = Filename.concat root "config" in
  mkdir_p (Filename.concat config_root "prompts");
  mkdir_p (Filename.concat config_root "keepers");
  mkdir_p (Filename.concat config_root "personas");
  write_file (Filename.concat config_root "cascade.json") "{}";
  write_file (Filename.concat config_root "tool_policy.toml") "# test marker\n";
  let base = Filename.dirname config_root in
  let base_personas = Filename.concat (Filename.concat base Common.masc_dirname) "personas" in
  mkdir_p base_personas;
  let config_personas = Filename.concat config_root "personas" in
  let inputs = make_inputs ~env_config_dir:config_root ~env_base_path:base
      ~cwd:root () in
  let resolution = Lib.Config_dir_resolver.resolve_with inputs in
  let dirs = Lib.Config_dir_resolver.personas_dirs_with inputs resolution in
  check (list string) "base path fallback ignored"
    [ config_personas ] dirs

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
          test_case "cwd fallback disabled by default" `Quick
            test_cwd_fallback_disabled_by_default;
          test_case "cwd fallback opt-in" `Quick
            test_cwd_fallback_opt_in;
          test_case "exe-relative fallback opt-in" `Quick
            test_executable_relative_fallback_opt_in;
          test_case "local masc fallback precedes home masc" `Quick
            test_local_masc_fallback_precedes_home_masc;
          test_case "local masc fallback collapses explicit .masc dir"
            `Quick test_local_masc_fallback_collapses_explicit_masc_dir;
          test_case "home masc fallback" `Quick test_home_masc_fallback;
          test_case "does not fallback to legacy me_root repo path" `Quick
            test_no_legacy_me_root_fallback;
        ] );
      ( "personas_dirs",
        [
          test_case "default returns repo personas only" `Quick
            test_personas_dirs_default_repo_only;
          test_case "ignores HOME .masc/personas fallback" `Quick
            test_personas_dirs_ignores_home_fallback;
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
          test_case "canonicalizes explicit base path" `Quick
            test_normalize_masc_base_path_input_canonicalizes_explicit_path;
        ] );
    ]
