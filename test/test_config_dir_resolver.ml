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
  config

let make_inputs ?env_base_path ?env_config_dir ?env_personas_dir ?env_me_root ?env_workspace_root
    ?env_dune_sourceroot ?env_home ?(cwd = "/tmp/cwd") ?(executable_name = "/tmp/bin/masc-mcp") () =
  Lib.Config_dir_resolver.
    {
      cwd;
      executable_name;
      env_base_path;
      env_config_dir;
      env_personas_dir;
      env_home;
      env_me_root;
      env_workspace_root;
      env_dune_sourceroot;
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
  let home_root = Filename.concat home ".masc" in
  let config = make_config_root home_root in
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

let test_legacy_me_root_fallback () =
  with_temp_dir "config-dir-legacy" @@ fun me_root ->
  let repo_root =
    Filename.concat me_root "workspace/yousleepwhen/masc-mcp"
  in
  let _config = make_config_root repo_root in
  let resolution =
    Lib.Config_dir_resolver.resolve_with
      (make_inputs ~cwd:"/tmp/missing-cwd"
         ~executable_name:"/tmp/nonexistent-masc"
         ~env_me_root:me_root ())
  in
  check string "status" "warn"
    (Lib.Config_dir_resolver.status_to_string resolution.status);
  check string "root source" "legacy_me_root"
    (Lib.Config_dir_resolver.source_to_string resolution.config_root.source);
  check bool "warning present" true (resolution.warnings <> [])

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
          test_case "home masc fallback" `Quick test_home_masc_fallback;
          test_case "legacy me_root fallback" `Quick
            test_legacy_me_root_fallback;
        ] );
    ]
