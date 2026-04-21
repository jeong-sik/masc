open Alcotest
open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let canonical_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ | Sys_error _ -> path

let init_state = function
  | Config_doctor.Initialized -> "initialized"
  | Config_doctor.Missing_init -> "missing_init"
  | Config_doctor.Invalid_env -> "invalid_env"
  | Config_doctor.Shadowed -> "shadowed"

let status = function
  | Config_doctor.Ok -> "ok"
  | Config_doctor.Warn -> "warn"
  | Config_doctor.Error -> "error"

let contains_substring ~needle s =
  let nl = String.length needle in
  let sl = String.length s in
  if nl = 0 || nl > sl then false
  else
    let limit = sl - nl in
    let rec loop i =
      if i > limit then false
      else if String.sub s i nl = needle then true
      else loop (i + 1)
    in
    loop 0

let list_contains_substring ~needle values =
  List.exists (contains_substring ~needle) values

let make_inputs ?env_config_dir ?env_personas_dir ~cwd ~base_path_input () =
  Config_doctor.
    {
      cwd;
      executable_name = Filename.concat cwd "test_config_doctor.exe";
      base_path_input;
      env_masc_base_path = None;
      env_config_dir;
      env_personas_dir;
      resolution_source = Some "explicit_cli";
      repo_config_fallback_enabled = false;
    }

let initialize_config_root ?(cascade_json="{}") root =
  write_file (Filename.concat root "cascade.json") cascade_json;
  mkdir_p (Filename.concat root "personas")

let test_invalid_explicit_config_dir () =
  with_temp_dir "config-doctor-invalid" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  mkdir_p base_path;
  let report =
    Config_doctor.analyze_with
      (make_inputs ~cwd:dir ~base_path_input:base_path
         ~env_config_dir:(Filename.concat dir "missing-config") ())
  in
  check string "init_state" "invalid_env"
    (init_state report.init_state);
  check string "status" "error" (status report.status);
  check bool "has warning" true (report.warnings <> [])

let test_missing_init_without_explicit_config () =
  with_temp_dir "config-doctor-missing" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  mkdir_p base_path;
  let report =
    Config_doctor.analyze_with
      (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "init_state" "missing_init"
    (init_state report.init_state);
  check string "status" "error" (status report.status);
  check string "active root is local base config"
    (Filename.concat (canonical_path base_path) ".masc/config")
    report.active_config_root;
  check bool "local base not initialized" false
    report.local_base_config_initialized

let test_initialized_local_base_config () =
  with_temp_dir "config-doctor-local" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root config_root;
  let report =
    Config_doctor.analyze_with
      (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "init_state" "initialized"
    (init_state report.init_state);
  check string "status" "ok" (status report.status);
  check string "source" "local_masc" report.config_root_source;
  check bool "keeper runtime optional" false report.keeper_runtime_toml_present;
  check (list string) "no warnings" [] report.warnings

let test_shadowed_explicit_config_dir () =
  with_temp_dir "config-doctor-shadowed" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let local_root = Filename.concat base_path ".masc/config" in
  let explicit_root = Filename.concat dir "active-config" in
  initialize_config_root local_root;
  initialize_config_root explicit_root;
  let report =
    Config_doctor.analyze_with
      (make_inputs ~cwd:dir ~base_path_input:base_path
         ~env_config_dir:explicit_root ())
  in
  check string "init_state" "shadowed"
    (init_state report.init_state);
  check string "status" "warn" (status report.status);
  check string "active root" (canonical_path explicit_root) report.active_config_root;
  check bool "local base initialized" true report.local_base_config_initialized

let test_broken_cascade_catalog_surfaces_errors () =
  with_temp_dir "config-doctor-cascade-bad" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root
    ~cascade_json:{|{
  "bad_provider_models": [
    "__nonexistent_provider_sentinel__:fake-model"
  ],
  "bad_strategy_models": [
    "claude_code:claude-haiku-4-5-20251001"
  ],
  "bad_strategy_strategy": "priority_tier",
  "bad_strategy_tiers": [
    ["codex_cli:auto"]
  ]
}|}
    config_root;
  let report =
    Config_doctor.analyze_with
      (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "status escalates to error" "error" (status report.status);
  check bool "catalog summary warning present" true
    (list_contains_substring
       ~needle:"Cascade catalog check scanned 2 preset(s): 2 error, 0 warn."
       report.warnings);
  check bool "invalid provider warning present" true
    (list_contains_substring
       ~needle:"Cascade preset bad_provider has 1 hard-invalid model spec"
       report.warnings);
  check bool "priority_tier collapse warning present" true
    (list_contains_substring
       ~needle:
         "Cascade preset bad_strategy uses priority_tier, but every tier collapses after model-id normalization"
       report.warnings);
  check bool "next action mentions doctor rerun" true
    (list_contains_substring
       ~needle:"Rerun `masc-mcp doctor config` after editing cascade.json."
       report.next_actions)

let () =
  run "config_doctor"
    [
      ("doctor", [
           test_case "invalid explicit config dir" `Quick
             test_invalid_explicit_config_dir;
           test_case "missing init without explicit config" `Quick
             test_missing_init_without_explicit_config;
           test_case "initialized local base config" `Quick
             test_initialized_local_base_config;
           test_case "shadowed explicit config dir" `Quick
             test_shadowed_explicit_config_dir;
           test_case "broken cascade catalog surfaces errors" `Quick
             test_broken_cascade_catalog_surfaces_errors;
         ]);
    ]
