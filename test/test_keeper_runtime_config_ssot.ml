(** Test ensure_keeper_meta TOML→JSON SSOT reconciliation.
    Verifies that ALL declarative fields from config/keepers/<name>.toml
    overwrite stale runtime JSON on bootstrap, and that unspecified fields
    (None in TOML) preserve their runtime values. *)

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

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let with_config_dir f =
  with_temp_dir "keeper-config-ssot" @@ fun config_dir ->
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match original with
      | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
      | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      f config_dir)

(** Test: TOML personality fields overwrite stale runtime JSON values. *)
let test_personality_resync () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "personality-resync-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "TOML goal"
short_goal = "TOML short goal"
mid_goal = "TOML mid goal"
long_goal = "TOML long goal"
will = "TOML will"
needs = "TOML needs"
desires = "TOML desires"
instructions = "TOML instructions"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-personality-resync");
            ("goal", `String "stale goal");
            ("short_goal", `String "stale short");
            ("mid_goal", `String "stale mid");
            ("long_goal", `String "stale long");
            ("will", `String "stale will");
            ("needs", `String "stale needs");
            ("desires", `String "stale desires");
            ("instructions", `String "stale instructions");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "goal" "TOML goal" updated.Keeper_types.goal;
      check string "short_goal" "TOML short goal" updated.short_goal;
      check string "mid_goal" "TOML mid goal" updated.mid_goal;
      check string "long_goal" "TOML long goal" updated.long_goal;
      check string "will" "TOML will" updated.will;
      check string "needs" "TOML needs" updated.needs;
      check string "desires" "TOML desires" updated.desires;
      check string "instructions" "TOML instructions" updated.instructions

(** Test: TOML policy fields overwrite stale runtime JSON values. *)
let test_policy_resync () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "policy-resync-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
{|[keeper]
goal = "test"
execution_scope = "observe_only"
policy_voice_enabled = false
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-policy-resync");
            ("execution_scope", `String "local");
            ("policy_voice_enabled", `Bool true);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  let execution_scope_testable =
    Alcotest.testable
      (fun fmt v -> Format.pp_print_string fmt (Keeper_execution_scope.to_string v))
      Keeper_execution_scope.equal
  in
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check execution_scope_testable "execution_scope" Keeper_execution_scope.Observe_only updated.Keeper_types.execution_scope;
      check bool "policy_voice_enabled" false updated.policy_voice_enabled

let test_sandbox_policy_resync () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "sandbox-policy-resync-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
{|[keeper]
goal = "test"
sandbox_profile = "docker_hardened"
network_mode = "none"
shared_memory_scope = "room"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-sandbox-policy-resync");
            ("sandbox_profile", `String "legacy_local");
            ("network_mode", `String "inherit");
            ("shared_memory_scope", `String "disabled");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "sandbox_profile" "docker_hardened"
        (Keeper_types.sandbox_profile_to_string updated.sandbox_profile);
      check string "network_mode" "none"
        (Keeper_types.network_mode_to_string updated.network_mode);
      check string "shared_memory_scope" "room"
        (Keeper_types.shared_memory_scope_to_string updated.shared_memory_scope)

(** Test: TOML tool policy and allowed_paths overwrite stale runtime JSON values. *)
let test_tool_policy_resync () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "tool-policy-resync-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "test"
execution_scope = "workspace"
allowed_paths = ["workspace/example/project"]
tool_preset = "social"
also_allow = ["keeper_bash", "keeper_shell"]
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-tool-policy-resync");
            ("execution_scope", `String "workspace");
            ("allowed_paths", `List [ `String ".masc/playground/old" ]);
            ( "tool_access",
              `Assoc
                [
                  ("kind", `String "preset");
                  ("preset", `String "delivery");
                  ("also_allow", `List [ `String "masc_board_post" ]);
                ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      let preset =
        match Keeper_types.tool_access_preset updated.Keeper_types.tool_access with
        | Some preset -> Keeper_types.tool_preset_to_string preset
        | None -> fail "expected preset-based tool_access"
      in
      check string "tool_preset" "social" preset;
      check
        (list string)
        "tool_also_allow"
        [ "keeper_bash"; "keeper_shell" ]
        (Keeper_types.tool_access_also_allowlist updated.tool_access);
      check
        (list string)
        "allowed_paths"
        [ "workspace/example/project" ]
        updated.allowed_paths

(** Test: explicit empty allowed_paths in TOML clears stale runtime JSON values. *)
let test_allowed_paths_explicit_empty_clears_runtime () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "allowed-paths-explicit-empty-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "test"
execution_scope = "workspace"
allowed_paths = []
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-allowed-paths-explicit-empty");
            ("execution_scope", `String "workspace");
            ("allowed_paths", `List [ `String "workspace/example/project" ]);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check (list string) "allowed_paths cleared" [] updated.allowed_paths

(** Test: persona allowed_paths is ignored and cannot inject authored allowlists. *)
let test_persona_allowed_paths_is_ignored () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "persona-allowed-paths-clear-test" in
  let personas_dir = Filename.concat config_dir "personas" in
  let persona_dir = Filename.concat personas_dir keeper_name in
  Unix.mkdir personas_dir 0o755;
  Unix.mkdir persona_dir 0o755;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|{
  "name": "persona clear",
  "keeper": {
    "goal": "test",
    "execution_scope": "workspace",
    "allowed_paths": ["workspace/example/project"]
  }
}|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-persona-allowed-paths-ignored");
            ("execution_scope", `String "workspace");
            ("allowed_paths", `List []);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check (list string) "persona allowed_paths ignored" [] updated.allowed_paths

(** Test: custom tool_access stays custom when TOML omits tool_preset. *)
let test_custom_tool_access_preserved_without_preset () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "tool-policy-custom-preserve-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "test"
execution_scope = "workspace"
allowed_paths = ["workspace/example/project"]
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-tool-policy-custom-preserve");
            ("execution_scope", `String "workspace");
            ("allowed_paths", `List [ `String ".masc/playground/old" ]);
            ( "tool_access",
              `Assoc
                [
                  ("kind", `String "custom");
                  ("tools", `List [ `String "keeper_board_get"; `String "masc_status" ]);
                ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check
        (option string)
        "custom access keeps no preset"
        None
        (Keeper_types.tool_access_preset updated.Keeper_types.tool_access
         |> Option.map Keeper_types.tool_preset_to_string);
      check
        (option (list string))
        "custom allowlist preserved"
        (Some [ "keeper_board_get"; "masc_status" ])
        (Keeper_types.tool_access_custom_allowlist updated.tool_access);
      check
        (list string)
        "allowed_paths"
        [ "workspace/example/project" ]
        updated.allowed_paths

(** Test: TOML can reference a persona and only override selected fields. *)
let test_persona_overlay_resync () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "overlay-keeper-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  let personas_dir = Filename.concat config_dir "personas" in
  let persona_name = "scholar" in
  let persona_dir = Filename.concat personas_dir persona_name in
  Unix.mkdir keepers_toml_dir 0o755;
  Unix.mkdir personas_dir 0o755;
  Unix.mkdir persona_dir 0o755;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|{
  "name": "학자",
  "role": "근거와 문맥을 압축하는 연구형 페르소나",
  "trait": "차분하고 체계적인 정리자",
  "keeper": {
    "goal": "자료를 읽고 핵심 쟁점을 구조화한다.",
    "needs": "원문 자료, 논문, 긴 문맥",
    "instructions": "먼저 읽고 구조를 잡은 뒤 요약한다.",
    "mention_targets": ["scholar", "학자"],
    "tool_preset": "research",
    "proactive_enabled": true
  }
}|};
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
persona_name = "scholar"
goal = "대화에 바로 쓸 수 있는 연구 브리프를 만든다."
execution_scope = "workspace"
tool_preset = "delivery"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-persona-overlay-resync");
            ("goal", `String "stale goal");
            ("needs", `String "stale needs");
            ("instructions", `String "stale instructions");
            ("mention_targets", `List [ `String "old-target" ]);
            ("execution_scope", `String "observe_only");
            ( "tool_access",
              `Assoc
                [
                  ("kind", `String "preset");
                  ("preset", `String "messaging");
                  ("also_allow", `List []);
                ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "toml goal overrides persona"
        "대화에 바로 쓸 수 있는 연구 브리프를 만든다."
        updated.goal;
      check string "persona needs inherited"
        "원문 자료, 논문, 긴 문맥"
        updated.needs;
      check string "persona instructions inherited"
        "먼저 읽고 구조를 잡은 뒤 요약한다."
        updated.instructions;
      check (list string) "persona mention_targets inherited"
        [ "scholar"; "학자" ]
        updated.mention_targets;
      check string "execution_scope from toml"
        "workspace"
        (Keeper_execution_scope.to_string updated.execution_scope);
      check
        (option string)
        "tool_preset from toml overlay"
        (Some "delivery")
        (Keeper_types.tool_access_preset updated.tool_access
         |> Option.map Keeper_types.tool_preset_to_string)

(** Test: fields absent from TOML (None) preserve runtime JSON values. *)
let test_none_preserves_runtime () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "none-preserve-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  (* TOML only specifies goal; everything else is None *)
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "minimal TOML"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-none-preserve");
            ("goal", `String "old goal");
            ("will", `String "runtime will");
            ("instructions", `String "runtime instructions");
            ("execution_scope", `String "local");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  let execution_scope_testable =
    Alcotest.testable
      (fun fmt v -> Format.pp_print_string fmt (Keeper_execution_scope.to_string v))
      Keeper_execution_scope.equal
  in
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      (* goal was in TOML → overwritten *)
      check string "goal overwritten" "minimal TOML" updated.Keeper_types.goal;
      (* will was NOT in TOML → preserved from runtime *)
      check string "will preserved" "runtime will" updated.will;
      (* instructions was NOT in TOML → preserved from runtime *)
      check string "instructions preserved" "runtime instructions" updated.instructions;
      (* execution_scope was NOT in TOML → preserved from runtime *)
      check execution_scope_testable "execution_scope preserved" Keeper_execution_scope.Local updated.execution_scope

(** Test: TOML work_discovery fields overwrite stale option-typed meta fields. *)
let test_discovery_resync () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "discovery-resync-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "test"
work_discovery_enabled = true
work_discovery_interval_sec = 120
work_discovery_guidance = "TOML guidance"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-discovery-resync");
            ("work_discovery_enabled", `Bool false);
            ("work_discovery_interval_sec", `Int 60);
            ("work_discovery_guidance", `String "old guidance");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check (option bool) "work_discovery_enabled"
        (Some true) updated.Keeper_types.work_discovery_enabled;
      check (option int) "work_discovery_interval_sec"
        (Some 120) updated.work_discovery_interval_sec;
      check (option string) "work_discovery_guidance"
        (Some "TOML guidance") updated.work_discovery_guidance

(** Test: declarative keepers reset stale live cascade_name to the default
    keeper cascade when the authored config omits cascade_name. *)
let test_cascade_defaults_resync () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "cascade-default-resync-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "TOML goal"
tool_preset = "social"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-cascade-default-resync");
            ("goal", `String "stale goal");
            ("cascade_name", `String "local_only");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "goal" "TOML goal" updated.Keeper_types.goal;
      check string "cascade_name reset to keeper default"
        Keeper_config.default_cascade_name updated.cascade_name

let test_social_model_not_resynced_from_declarative_defaults () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "social-model-owner-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
goal = "TOML goal"
social_model = "magentic_ledger_v1"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-social-model-owner");
            ("goal", `String "stale goal");
            ("social_model", `String "bdi_speech_v1");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "goal resynced from TOML" "TOML goal" updated.Keeper_types.goal;
      check string "social_model remains keeper-owned" "bdi_speech_v1"
        updated.social_model

(** Test: room presence sync updates stale agent capabilities from live keeper meta. *)
let test_room_presence_syncs_capabilities () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "room-presence-sync-test" in
  let agent_name = Keeper_types.keeper_agent_name keeper_name in
  let config = Coord.default_config room_dir in
  let _ = Coord.init config ~agent_name:None in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String agent_name);
            ("trace_id", `String "trace-room-presence-sync");
            ( "tool_access",
              `Assoc
                [
                  ("kind", `String "preset");
                  ("preset", `String "social");
                ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  (match Keeper_types.write_meta ~force:true config initial_meta with
  | Error e -> fail ("write_meta failed: " ^ e)
  | Ok () -> ());
  ignore
    (Coord.join config ~agent_name ~capabilities:[ "keeper"; "preset:minimal" ] ());
  let _synced = Keeper_exec_context.ensure_keeper_room_presence config initial_meta in
  let agent =
    Coord.get_agents_raw config
    |> List.find_opt (fun (agent : Types.agent) -> String.equal agent.name agent_name)
  in
  match agent with
  | None -> fail "expected keeper agent after room presence sync"
  | Some agent ->
      check
        (list string)
        "capabilities synced from live meta"
        [ "keeper"; "preset:social" ]
        agent.capabilities

(* Test: update_field_in_content replaces existing field *)
let test_toml_update_existing () =
  let input = {|[keeper]
goal = "old goal"
cascade_name = "default"
instructions = "keep this"
|} in
  match Keeper_toml_loader.update_field_in_content
          ~table:"keeper" ~key:"cascade_name" ~value:"local_only" input with
  | Error e -> fail ("update failed: " ^ e)
  | Ok result ->
      check bool "contains new value"
        true (String.length result > 0);
      (* Parse the result to verify *)
      (match Keeper_toml_loader.parse_toml result with
       | Error e -> fail ("re-parse failed: " ^ e)
       | Ok doc ->
         check (option string) "cascade_name updated"
           (Some "local_only")
           (Keeper_toml_loader.toml_string_opt doc "keeper.cascade_name");
         check (option string) "goal preserved"
           (Some "old goal")
           (Keeper_toml_loader.toml_string_opt doc "keeper.goal");
         check (option string) "instructions preserved"
           (Some "keep this")
           (Keeper_toml_loader.toml_string_opt doc "keeper.instructions"))

(** Test: update_field_in_content inserts new field *)
let test_toml_update_insert () =
  let input = {|[keeper]
goal = "test"
|} in
  match Keeper_toml_loader.update_field_in_content
          ~table:"keeper" ~key:"cascade_name" ~value:"local_only" input with
  | Error e -> fail ("update failed: " ^ e)
  | Ok result ->
      (match Keeper_toml_loader.parse_toml result with
       | Error e -> fail ("re-parse failed: " ^ e)
       | Ok doc ->
         check (option string) "cascade_name inserted"
           (Some "local_only")
           (Keeper_toml_loader.toml_string_opt doc "keeper.cascade_name");
         check (option string) "goal preserved"
           (Some "test")
           (Keeper_toml_loader.toml_string_opt doc "keeper.goal"))

(** Test: update_field_in_content returns Error for missing table *)
let test_toml_update_no_table () =
  let input = {|# no [keeper] table here
goal = "orphan"
|} in
  match Keeper_toml_loader.update_field_in_content
          ~table:"keeper" ~key:"cascade_name" ~value:"x" input with
  | Ok _ -> fail "should have returned Error for missing table"
  | Error _ -> ()

let () =
  run "Keeper_runtime config SSOT resync"
    [
      ( "personality",
        [
          test_case
            "TOML personality fields overwrite stale runtime JSON"
            `Quick
            test_personality_resync;
        ] );
      ( "policy",
        [
          test_case
            "TOML policy fields overwrite stale runtime JSON"
            `Quick
            test_policy_resync;
          test_case
            "TOML sandbox policy fields overwrite stale runtime JSON"
            `Quick
            test_sandbox_policy_resync;
          test_case
            "TOML tool policy fields overwrite stale runtime JSON"
            `Quick
            test_tool_policy_resync;
          test_case
            "custom tool_access is preserved when TOML omits preset"
            `Quick
            test_custom_tool_access_preserved_without_preset;
          test_case
            "explicit empty allowed_paths in TOML clears stale runtime JSON"
            `Quick
            test_allowed_paths_explicit_empty_clears_runtime;
          test_case
            "persona allowed_paths is ignored"
            `Quick
            test_persona_allowed_paths_is_ignored;
          test_case
            "persona defaults can be overlaid by keeper TOML"
            `Quick
            test_persona_overlay_resync;
        ] );
      ( "none_preserve",
        [
          test_case
            "absent TOML fields preserve runtime JSON values"
            `Quick
            test_none_preserves_runtime;
        ] );
      ( "discovery",
        [
          test_case
            "TOML work_discovery fields overwrite stale meta"
            `Quick
            test_discovery_resync;
          test_case
            "declarative keepers reset stale live cascade_name to default"
            `Quick
            test_cascade_defaults_resync;
          test_case
            "declarative defaults do not resync social_model"
            `Quick
            test_social_model_not_resynced_from_declarative_defaults;
          test_case
            "room presence sync overwrites stale agent capabilities"
            `Quick
            test_room_presence_syncs_capabilities;
        ] );
      ( "toml_writer",
        [
          test_case
            "replaces existing field in TOML"
            `Quick
            test_toml_update_existing;
          test_case
            "inserts new field into TOML table"
            `Quick
            test_toml_update_insert;
          test_case
            "returns Error when table is missing"
            `Quick
            test_toml_update_no_table;
        ] );
    ]
