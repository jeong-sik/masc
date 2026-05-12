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

let minimal_live_cascade_toml =
  {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
api-name = "qwen3:8b"
max-context = 32768
tools-support = true

[ollama.qwen3]
is-default = true
max-concurrent = 1

[tier.big_three]
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.big_three]
tiers = ["big_three"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "tier-group.big_three"
|}

let with_fake_docker script f =
  with_temp_dir "config-doctor-docker" @@ fun dir ->
  let docker_path = Filename.concat dir "docker" in
  Out_channel.with_open_bin docker_path (fun oc -> output_string oc script);
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  with_env "PATH" path f

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.clear_fs ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  f
    ~sw
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~fs:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)

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

let with_config_dir config_root f =
  let reset () =
    Config_dir_resolver.reset ();
    Cascade_catalog_runtime.reset_cache_for_tests ()
  in
  with_env "MASC_BASE_PATH" "" @@ fun () ->
  with_env "MASC_CONFIG_DIR" config_root @@ fun () ->
  reset ();
  Fun.protect ~finally:reset f

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

(* RFC-0058 §9: cascade.toml is the only on-disk cascade source.  The
   default [""] is the smallest valid TOML document — a document with
   no tables or keys — which the materializer renders to an empty
   catalog ("no presets configured" baseline). *)
let initialize_config_root ?(cascade_toml="") root =
  write_file (Filename.concat root "cascade.toml") cascade_toml;
  mkdir_p (Filename.concat root "personas")

let initialize_legacy_json_only_config_root root =
  write_file (Filename.concat root "cascade.json") "{}";
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

let test_legacy_json_without_toml_next_action_migrates () =
  with_temp_dir "config-doctor-legacy-json" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_legacy_json_only_config_root config_root;
  let report =
    Config_doctor.analyze_with
      (make_inputs ~cwd:dir ~base_path_input:base_path ())
  in
  check string "status downgrades to warn" "warn" (status report.status);
  check bool "legacy json warning present" true
    (list_contains_substring
       ~needle:"cascade.json but no cascade.toml"
       report.warnings);
  check bool "next action points at migration" true
    (list_contains_substring
       ~needle:"Migrate or rename"
       report.next_actions);
  check bool "next action names cascade.toml" true
    (list_contains_substring
       ~needle:"cascade.toml"
       report.next_actions)

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

let test_analyze_live_surfaces_sandbox_preflight_failure () =
  with_temp_dir "config-doctor-sandbox-preflight" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root
    ~cascade_toml:{|[providers.codex_cli]
display-name = "OpenAI Codex CLI"
protocol = "openai-http"
command = "codex"
is-non-interactive = true

[providers.codex_cli.credentials]
type = "env"
key = "OPENAI_API_KEY"

[models.codex-spark]
api-name = "gpt-5.3-codex-spark"
max-context = 128000
tools-support = true
streaming = true

[models.codex-spark.capabilities]
supports-native-streaming = true
supports-response-format-json = true

[codex_cli.codex-spark]
is-default = true
max-concurrent = 1

[tier.coding_plan_primary]
members = ["codex_cli.codex-spark"]
strategy = "failover"

[tier-group.coding_plan]
tiers = ["coding_plan_primary"]
strategy = "priority_tier"
fallback = false

[routes.keeper_turn]
target = "tier-group.coding_plan"

[routes.tool_required]
target = "tier-group.coding_plan"
|}
    config_root;
  with_config_dir config_root @@ fun () ->
  with_env "OPENAI_API_KEY" "test" @@ fun () ->
  with_fake_docker fake_docker_missing_image_script @@ fun () ->
  with_env "MASC_CONFIG_DIR" config_root @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "missing:test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE" "" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_REQUIRE_USERNS" "false" @@ fun () ->
  with_eio @@ fun ~sw ~net ~clock ~fs ~proc_mgr ->
  let report =
    Config_doctor.analyze_live
      ~sw ~net ~clock ~fs ~proc_mgr
      ~base_path_input:base_path
      ~default_base_path:base_path
      ()
  in
  check string "status downgrades to warn" "warn" (status report.status);
  check bool "warning mentions docker sandbox preflight" true
    (list_contains_substring
       ~needle:"Docker sandbox preflight failed"
       report.warnings);
  check bool "next action mentions build script" true
    (list_contains_substring
       ~needle:"scripts/build-keeper-sandbox-image.sh"
       report.next_actions);
  match report.sandbox_preflight with
  | None -> fail "expected sandbox_preflight output from analyze_live"
  | Some json ->
      check string "sandbox preflight status" "error"
        (Yojson.Safe.Util.member "status" json |> Yojson.Safe.Util.to_string);
      check string "sandbox preflight image" "missing:test"
        (Yojson.Safe.Util.member "image" json |> Yojson.Safe.Util.to_string);
      check bool "doctor json includes sandbox_preflight" true
        (match Yojson.Safe.Util.member "sandbox_preflight"
                 (Config_doctor.to_yojson report) with
         | `Null -> false
         | _ -> true)

let test_analyze_live_errors_on_tool_required_route_without_forced_tool_provider () =
  with_temp_dir "config-doctor-tool-route" @@ fun dir ->
  let base_path = Filename.concat dir "base" in
  let config_root = Filename.concat base_path ".masc/config" in
  initialize_config_root
    ~cascade_toml:{|[providers.glm-coding]
display-name = "Zhipu GLM Coding"
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[models.glm-5-1]
api-name = "glm-5.1"
max-context = 128000
tools-support = true
streaming = true

[models.glm-5-1.capabilities]
supports-native-streaming = true
supports-response-format-json = true

[glm-coding.glm-5-1]
is-default = true
max-concurrent = 1

[tier.coding_plan_primary]
members = ["glm-coding.glm-5-1"]
strategy = "failover"

[tier-group.coding_plan]
tiers = ["coding_plan_primary"]
strategy = "priority_tier"
fallback = false

[routes.keeper_turn]
target = "tier-group.coding_plan"

[routes.tool_required]
target = "tier-group.coding_plan"
|}
    config_root;
  with_config_dir config_root @@ fun () ->
  with_env "ZAI_API_KEY" "test" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" @@ fun () ->
  with_eio @@ fun ~sw ~net ~clock ~fs ~proc_mgr ->
  let report =
    Config_doctor.analyze_live
      ~sw ~net ~clock ~fs ~proc_mgr
      ~base_path_input:base_path
      ~default_base_path:base_path
      ()
  in
  check string "status escalates to error" "error" (status report.status);
  check bool "keeper route tool warning present" true
    (list_contains_substring
       ~needle:"Tool-required cascade route keeper_turn targets tier-group.coding_plan"
       report.warnings);
  check bool "tool route tool warning present" true
    (list_contains_substring
       ~needle:"Tool-required cascade route tool_required targets tier-group.coding_plan"
       report.warnings);
  check bool "forced tool-use reason present" true
    (list_contains_substring
       ~needle:"needs inline tool_choice or runtime MCP"
       report.warnings);
  check bool "no-tool terminal hint present" true
    (list_contains_substring
       ~needle:"no_tool_capable_provider"
       report.warnings);
  check bool "next action points at tool-capable route" true
    (list_contains_substring
       ~needle:"Route keeper_turn/tool_required to at least one provider"
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
           test_case "legacy cascade.json without toml gets migration action"
             `Quick test_legacy_json_without_toml_next_action_migrates;
           test_case "analyze_live surfaces sandbox preflight failure"
             `Quick test_analyze_live_surfaces_sandbox_preflight_failure;
           test_case "analyze_live errors on tool-required route without forced tool provider"
             `Quick
             test_analyze_live_errors_on_tool_required_route_without_forced_tool_provider;
         ]);
    ]
