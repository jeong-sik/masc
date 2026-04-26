open Alcotest
open Masc_mcp

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_file path content =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

let with_fake_docker script f =
  with_temp_dir "config-doctor-docker"
  @@ fun dir ->
  let docker_path = Filename.concat dir "docker" in
  Out_channel.with_open_bin docker_path (fun oc -> output_string oc script);
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  with_env "PATH" path f
;;

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.clear_fs ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run
  @@ fun sw ->
  f
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~fs:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
;;

let canonical_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ | Sys_error _ -> path
;;

let init_state = function
  | Config_doctor.Initialized -> "initialized"
  | Config_doctor.Missing_init -> "missing_init"
  | Config_doctor.Invalid_env -> "invalid_env"
  | Config_doctor.Shadowed -> "shadowed"
;;

let status = function
  | Config_doctor.Ok -> "ok"
  | Config_doctor.Warn -> "warn"
  | Config_doctor.Error -> "error"
;;

let contains_substring ~needle s =
  let nl = String.length needle in
  let sl = String.length s in
  if nl = 0 || nl > sl
  then false
  else (
    let limit = sl - nl in
    let rec loop i =
      if i > limit
      then false
      else if String.sub s i nl = needle
      then true
      else loop (i + 1)
    in
    loop 0)
;;

let list_contains_substring ~needle values =
  List.exists (contains_substring ~needle) values
;;

let make_inputs ?env_config_dir ?env_personas_dir ~cwd ~base_path_input () =
  Config_doctor.
    { cwd
    ; executable_name = Filename.concat cwd "test_config_doctor.exe"
    ; base_path_input
    ; env_masc_base_path = None
    ; env_config_dir
    ; env_personas_dir
    ; resolution_source = Some "explicit_cli"
    ; repo_config_fallback_enabled = false
    }
;;

let initialize_config_root ?(cascade_json = "{}") root =
  write_file (Filename.concat root "cascade.json") cascade_json;
  mkdir_p (Filename.concat root "personas")
;;

let test_invalid_explicit_config_dir () =
  with_temp_dir "config-doctor-invalid"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  mkdir_p base_path;
  let report =
    Config_doctor.analyze_with
      (make_inputs
         ~cwd:dir
         ~base_path_input:base_path
         ~env_config_dir:(Filename.concat dir "missing-config")
         ())
  in
  check string "init_state" "invalid_env" (init_state report.init_state);
  check string "status" "error" (status report.status);
  check bool "has warning" true (report.warnings <> [])
;;

let test_missing_init_without_explicit_config () =
  with_temp_dir "config-doctor-missing"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  mkdir_p base_path;
  let report =
    Config_doctor.analyze_with (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "init_state" "missing_init" (init_state report.init_state);
  check string "status" "error" (status report.status);
  check
    string
    "active root is local base config"
    (Filename.concat (canonical_path base_path) ".masc/config")
    report.active_config_root;
  check bool "local base not initialized" false report.local_base_config_initialized
;;

let test_initialized_local_base_config () =
  with_temp_dir "config-doctor-local"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root config_root;
  let report =
    Config_doctor.analyze_with (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "init_state" "initialized" (init_state report.init_state);
  check string "status" "ok" (status report.status);
  check string "source" "local_masc" report.config_root_source;
  check bool "keeper runtime optional" false report.keeper_runtime_toml_present;
  check (list string) "no warnings" [] report.warnings
;;

let test_persona_tool_preset_conflict_warns () =
  with_temp_dir "config-doctor-persona-conflict"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root config_root;
  write_file
    (Filename.concat config_root "keepers/sangsu.toml")
    {|
[keeper]
name = "sangsu"
persona_name = "sangsu"
tool_preset = "delivery"
|};
  write_file
    (Filename.concat config_root "personas/sangsu/profile.json")
    {|{"keeper":{"tool_preset":"coding"}}|};
  let report =
    Config_doctor.analyze_with (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "status warns" "warn" (status report.status);
  check int "one conflict" 1 (List.length report.persona_tool_preset_conflicts);
  check
    bool
    "warning names keeper"
    true
    (list_contains_substring
       ~needle:
         "Keeper sangsu TOML tool_preset \"delivery\" overrides persona sangsu \
          tool_preset \"coding\""
       report.warnings);
  check
    bool
    "next action tells operator to remove override"
    true
    (list_contains_substring ~needle:"Remove tool_preset from" report.next_actions);
  let json = Config_doctor.to_yojson report in
  let conflicts =
    Yojson.Safe.Util.(json |> member "persona_tool_preset_conflicts" |> to_list)
  in
  check int "json conflict count" 1 (List.length conflicts)
;;

let test_shadowed_explicit_config_dir () =
  with_temp_dir "config-doctor-shadowed"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let local_root = Filename.concat base_path ".masc/config" in
  let explicit_root = Filename.concat dir "active-config" in
  initialize_config_root local_root;
  initialize_config_root explicit_root;
  let report =
    Config_doctor.analyze_with
      (make_inputs ~cwd:dir ~base_path_input:base_path ~env_config_dir:explicit_root ())
  in
  check string "init_state" "shadowed" (init_state report.init_state);
  check string "status" "warn" (status report.status);
  check string "active root" (canonical_path explicit_root) report.active_config_root;
  check bool "local base initialized" true report.local_base_config_initialized
;;

let test_broken_cascade_catalog_surfaces_errors () =
  with_temp_dir "config-doctor-cascade-bad"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root
    ~cascade_json:
      {|{
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
    Config_doctor.analyze_with (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "status escalates to error" "error" (status report.status);
  check
    bool
    "catalog summary warning present"
    true
    (list_contains_substring
       ~needle:"Cascade catalog check scanned 2 preset(s): 2 error, 0 warn."
       report.warnings);
  check
    bool
    "invalid provider warning present"
    true
    (list_contains_substring
       ~needle:"Cascade preset bad_provider has 1 hard-invalid model spec"
       report.warnings);
  check
    bool
    "priority_tier collapse warning present"
    true
    (list_contains_substring
       ~needle:
         "Cascade preset bad_strategy uses priority_tier, but every tier collapses after \
          model-id normalization"
       report.warnings);
  check
    bool
    "next action mentions doctor rerun"
    true
    (list_contains_substring
       ~needle:"Rerun `masc-mcp doctor config` after editing cascade.json."
       report.next_actions)
;;

let test_non_runtime_required_cascade_catalog_warns () =
  with_temp_dir "config-doctor-cascade-warn"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root
    ~cascade_json:
      {|{
  "default_models": [
    "claude_code:claude-haiku-4-5-20251001"
  ],
  "default_strategy": "priority_tier",
  "default_tiers": [
    ["claude_code:claude-haiku-4-5-20251001"],
    ["gemini_cli:not-configured-here"]
  ],
  "manual_trial_models": [
    "claude_code:claude-haiku-4-5-20251001"
  ]
}|}
    config_root;
  let report =
    Config_doctor.analyze_with (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "status downgrades to warn" "warn" (status report.status);
  check
    bool
    "catalog summary warning present"
    true
    (list_contains_substring
       ~needle:"Cascade catalog check scanned 2 preset(s): 0 error, 1 warn."
       report.warnings);
  check
    bool
    "priority_tier degradation detail surfaced"
    true
    (list_contains_substring
       ~needle:"uses priority_tier, but 1/2 tier(s) collapse after model-id normalization"
       report.warnings)
;;

let fake_docker_missing_image_script =
  "#!/bin/sh\n\
   case \"$1\" in\n\
   info)\n\
   printf '[]\\n'\n\
   exit 0\n\
   ;;\n\
   image)\n\
   printf 'Error: No such image: %s\\n' \"$3\" >&2\n\
   exit 1\n\
   ;;\n\
   run)\n\
   printf 'run should not execute when image inspect fails\\n' >&2\n\
   exit 2\n\
   ;;\n\
   esac\n\
   printf 'unexpected docker invocation\\n' >&2\n\
   exit 2\n"
;;

let test_analyze_live_surfaces_sandbox_preflight_failure () =
  with_temp_dir "config-doctor-sandbox-preflight"
  @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root config_root;
  with_fake_docker fake_docker_missing_image_script
  @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true"
  @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test"
  @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" ""
  @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false"
  @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false"
  @@ fun () ->
  with_eio
  @@ fun ~sw ~net ~clock ~fs ~proc_mgr ->
  let report =
    Config_doctor.analyze_live
      ~sw
      ~net
      ~clock
      ~fs
      ~proc_mgr
      ~base_path_input:base_path
      ~default_base_path:base_path
      ()
  in
  check string "status downgrades to warn" "warn" (status report.status);
  check
    bool
    "warning mentions docker sandbox preflight"
    true
    (list_contains_substring ~needle:"Docker sandbox preflight failed" report.warnings);
  check
    bool
    "next action mentions build script"
    true
    (list_contains_substring
       ~needle:"scripts/build-keeper-sandbox-image.sh"
       report.next_actions);
  match report.sandbox_preflight with
  | None -> fail "expected sandbox_preflight output from analyze_live"
  | Some json ->
    check
      string
      "sandbox preflight status"
      "error"
      (Yojson.Safe.Util.member "status" json |> Yojson.Safe.Util.to_string);
    check
      string
      "sandbox preflight image"
      "missing:test"
      (Yojson.Safe.Util.member "image" json |> Yojson.Safe.Util.to_string);
    check
      bool
      "doctor json includes sandbox_preflight"
      true
      (match
         Yojson.Safe.Util.member "sandbox_preflight" (Config_doctor.to_yojson report)
       with
       | `Null -> false
       | _ -> true)
;;

let () =
  run
    "config_doctor"
    [ ( "doctor"
      , [ test_case "invalid explicit config dir" `Quick test_invalid_explicit_config_dir
        ; test_case
            "missing init without explicit config"
            `Quick
            test_missing_init_without_explicit_config
        ; test_case
            "initialized local base config"
            `Quick
            test_initialized_local_base_config
        ; test_case
            "persona/TOML tool_preset conflict warns"
            `Quick
            test_persona_tool_preset_conflict_warns
        ; test_case
            "shadowed explicit config dir"
            `Quick
            test_shadowed_explicit_config_dir
        ; test_case
            "broken cascade catalog surfaces errors"
            `Quick
            test_broken_cascade_catalog_surfaces_errors
        ; test_case
            "non-runtime-required cascade catalog warns"
            `Quick
            test_non_runtime_required_cascade_catalog_warns
        ; test_case
            "analyze_live surfaces sandbox preflight failure"
            `Quick
            test_analyze_live_surfaces_sandbox_preflight_failure
        ] )
    ]
;;
