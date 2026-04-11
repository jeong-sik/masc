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

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file (Filename.concat config "cascade.json") "{}";
  write_file (Filename.concat config "tool_policy.toml") "# test marker\n";
  config

(* A partial config dir that mimics dune's [_build/default/config/]
   materialisation: cascade.json is promoted but tool_policy.toml is
   absent. The resolver must NOT pick this as the config root; it
   should keep walking up. *)
let make_partial_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p config;
  write_file (Filename.concat config "cascade.json") "{}";
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
  check bool "cascade exists" true resolution.cascade.exists;
  check bool "prompts exists" true resolution.prompts.exists

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

let test_cwd_fallback () =
  with_temp_dir "config-dir-cwd" @@ fun cwd ->
  let _config = make_config_root cwd in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "cwd"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "keepers exists" true resolution.keepers.exists

let test_home_masc_fallback () =
  with_temp_dir "config-dir-home" @@ fun home ->
  let home_masc_root = Filename.concat home ".masc" in
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
  let local_config = make_config_root (Filename.concat target ".masc") in
  let home = Filename.concat root "home" in
  ignore (make_config_root (Filename.concat home ".masc"));
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
  let local_config = make_config_root (Filename.concat target ".masc") in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd:root
         ~env_base_path:(Filename.concat target ".masc")
         ~executable_name:"/tmp/nonexistent-masc" ())
  in
  check string "status" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "local_masc"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check string "root path" local_config resolution.config_root.path

(* Regression: dune materialises [config/cascade.json] into
   [_build/default/config/cascade.json] when a test declares it as a
   [(deps %{workspace_root}/config/cascade.json)] rule. Before the
   config_signature_exists tightening, the executable-relative lookup
   matched [_build/default/config/] on that lone file and reported a
   broken config root. With tool_policy.toml required, the lookup
   walks past _build and picks the real source config. *)
let test_build_dir_partial_config_is_skipped () =
  with_temp_dir "config-dir-build-partial" @@ fun root ->
  let real_config = make_config_root root in
  let build_config_parent = Filename.concat root "_build/default/test" in
  mkdir_p build_config_parent;
  let exe = Filename.concat build_config_parent "test_runner.exe" in
  write_file exe "#!/bin/sh\n";
  Unix.chmod exe 0o755;
  (* Partial config mimicking _build/default/config materialisation:
     cascade.json is promoted but tool_policy.toml is absent. *)
  let _partial =
    make_partial_config_root (Filename.concat root "_build/default")
  in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd:build_config_parent ~executable_name:exe ())
  in
  check string "status ready" "ready"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "skipped partial _build config" real_config
    resolution.config_root.path;
  check string "source is exe_relative" "exe_relative"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source)

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
  let base_personas = Filename.concat (Filename.concat base ".masc") "personas" in
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
          test_case "env override invalid does not fallback" `Quick
            test_env_override_invalid_no_fallback;
          test_case "cwd fallback" `Quick test_cwd_fallback;
          test_case "local masc fallback precedes home masc" `Quick
            test_local_masc_fallback_precedes_home_masc;
          test_case "local masc fallback collapses explicit .masc dir"
            `Quick test_local_masc_fallback_collapses_explicit_masc_dir;
          test_case "home masc fallback" `Quick test_home_masc_fallback;
          test_case "build dir partial config is skipped (cascade-only)"
            `Quick test_build_dir_partial_config_is_skipped;
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
    ]
