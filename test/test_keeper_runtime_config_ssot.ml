module Types = Masc_domain

(** Test ensure_keeper_meta TOML→JSON SSOT reconciliation.
    Verifies that ALL declarative fields from config/keepers/<name>.toml
    overwrite stale runtime JSON on bootstrap, and that unspecified fields
    (None in TOML) preserve their runtime values. *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

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

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_persisted_meta_file config meta =
  let dir = Filename.concat (Coord.masc_root_dir config) "keepers" in
  mkdir_p dir;
  let path = Filename.concat dir (meta.Keeper_types.name ^ ".json") in
  write_file path (Yojson.Safe.pretty_to_string (Keeper_types.meta_to_json meta));
  path

let seed_persisted_meta config meta =
  let path = write_persisted_meta_file config meta in
  Fs_compat.clear_fs ();
  match Keeper_types.read_meta_file_path path with
  | Ok (Some _) -> (
      match Keeper_types.read_meta config meta.Keeper_types.name with
      | Ok (Some _) -> ()
      | Ok None -> fail ("persisted meta fixture not found via read_meta: " ^ path)
      | Error e -> fail ("persisted meta fixture read_meta failed: " ^ e))
  | Ok None -> fail ("persisted meta fixture was not readable: " ^ path)
  | Error e -> fail ("persisted meta fixture read failed: " ^ e)

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  loop 0

let with_config_dir f =
  with_temp_dir "keeper-config-ssot" @@ fun config_dir ->
  let cascade_path = Filename.concat config_dir "cascade.json" in
  let original = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match original with
      | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
      | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Config_dir_resolver.reset ();
      Cascade_catalog_runtime.reset_cache_for_tests ())
    (fun () ->
      write_file
        cascade_path
        {|{
  "big_three_models": ["test-only:model"]
}|};
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      Cascade_catalog_runtime.install_snapshot_for_tests
        ~source_path:cascade_path
        ~profile_names:[ Keeper_config.default_cascade_name ];
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
sandbox_profile = "docker"
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
      Masc_test_deps.meta_of_json_fixture
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
  seed_persisted_meta config initial_meta;
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
sandbox_profile = "docker"
goal = "test"
policy_voice_enabled = false
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-policy-resync");
            ("policy_voice_enabled", `Bool true);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
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
sandbox_profile = "docker"
network_mode = "none"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-sandbox-policy-resync");
            ("sandbox_profile", `String "local");
            ("network_mode", `String "inherit");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "sandbox_profile" "docker"
        (Keeper_types.sandbox_profile_to_string updated.sandbox_profile);
      check string "network_mode" "none"
        (Keeper_types.network_mode_to_string updated.network_mode)

let test_keeper_up_create_uses_profile_default_sandbox_policy () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let keeper_name = "keeper-up-sandbox-defaults-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
{|[keeper]
goal = "test"
sandbox_profile = "docker"
network_mode = "inherit"
|};
  let config = Coord.default_config room_dir in
  ignore (Coord.init config ~agent_name:(Some "operator"));
  let keeper_ctx : _ Tool_keeper.context =
    {
      config;
      agent_name = "operator";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env);
      net = None;
    }
  in
  Fun.protect
    ~finally:(fun () -> Keeper_keepalive.stop_keepalive keeper_name)
    (fun () ->
      let () =
        match
          Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_up"
            ~args:
              (`Assoc
                [
                  ("name", `String keeper_name);
                  ("proactive_enabled", `Bool false);
                  ("autoboot_enabled", `Bool false);
                ])
        with
        | Some (true, _) -> ()
        | Some (false, err) -> fail ("keeper_up failed: " ^ err)
        | None -> fail "missing keeper_up dispatch"
      in
      match Keeper_types.read_meta config keeper_name with
      | Ok (Some meta) ->
          check string "sandbox_profile from defaults" "docker"
            (Keeper_types.sandbox_profile_to_string meta.sandbox_profile);
          check string "network_mode from defaults" "inherit"
            (Keeper_types.network_mode_to_string meta.network_mode)
      | Ok None -> fail "keeper meta missing after keeper_up"
      | Error e -> fail ("read_meta failed: " ^ e))

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
sandbox_profile = "docker"
goal = "test"
allowed_paths = ["workspace/example/project"]

[keeper.tool_access]
kind = "preset"
preset = "social"
also_allow = ["keeper_bash", "keeper_shell"]
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-tool-policy-resync");
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
  seed_persisted_meta config initial_meta;
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
        updated.allowed_paths;
      check
        (option string)
        "tool_preset_source"
        (Some "toml")
        updated.tool_preset_source

let test_tool_preset_source_resyncs_from_toml_without_policy_delta () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "tool_source_toml_resync" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
goal = "test"

[keeper.tool_access]
kind = "preset"
preset = "social"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-tool-source-toml-resync");
            ("goal", `String "test");
            ( "tool_access",
              `Assoc
                [
                  ("kind", `String "preset");
                  ("preset", `String "social");
                  ("also_allow", `List []);
                ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  let persisted_path = write_persisted_meta_file config initial_meta in
  Fs_compat.clear_fs ();
  check bool "persisted meta fixture exists" true (Sys.file_exists persisted_path);
  (match Keeper_types.read_meta_file_path persisted_path with
  | Ok (Some _) -> ()
  | Ok None -> fail "persisted meta fixture was not readable"
  | Error e -> fail ("persisted meta fixture read failed: " ^ e));
  (match Keeper_types.read_meta config keeper_name with
  | Ok (Some _) -> ()
  | Ok None -> fail ("persisted meta fixture not found via read_meta: " ^ persisted_path)
  | Error e -> fail ("persisted meta fixture read_meta failed: " ^ e));
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check
        (option string)
        "tool_preset_source resynced from TOML"
        (Some "toml")
        updated.Keeper_types.tool_preset_source

let test_persona_no_longer_drives_tool_preset_source () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "tool_source_persona_resync" in
  let personas_dir = Filename.concat config_dir "personas" in
  let persona_dir = Filename.concat personas_dir keeper_name in
  Unix.mkdir personas_dir 0o755;
  Unix.mkdir persona_dir 0o755;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|{
  "name": "source persona",
  "keeper": {
    "goal": "test"
  }
}|};
  (* Persona-only configs cannot satisfy the sandbox_profile required-field
     check (personas are not allowed to declare execution policy). Add a
     minimal TOML wrapper that only sets sandbox_profile + persona_name. *)
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    (Printf.sprintf
       {|[keeper]
sandbox_profile = "docker"
persona_name = "%s"
|}
       keeper_name);
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-tool-source-persona-resync");
            ("goal", `String "test");
            ( "tool_access",
              `Assoc
                [
                  ("kind", `String "preset");
                  ("preset", `String "research");
                  ("also_allow", `List []);
                ] );
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  let persisted_path = write_persisted_meta_file config initial_meta in
  Fs_compat.clear_fs ();
  check bool "persisted meta fixture exists" true (Sys.file_exists persisted_path);
  (match Keeper_types.read_meta_file_path persisted_path with
  | Ok (Some _) -> ()
  | Ok None -> fail "persisted meta fixture was not readable"
  | Error e -> fail ("persisted meta fixture read failed: " ^ e));
  (match Keeper_types.read_meta config keeper_name with
  | Ok (Some _) -> ()
  | Ok None -> fail ("persisted meta fixture not found via read_meta: " ^ persisted_path)
  | Error e -> fail ("persisted meta fixture read_meta failed: " ^ e));
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check
        (option string)
        "persona does not drive tool_preset_source"
        None
        updated.Keeper_types.tool_preset_source

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
sandbox_profile = "docker"
goal = "test"
allowed_paths = []
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-allowed-paths-explicit-empty");
            ("allowed_paths", `List [ `String "workspace/example/project" ]);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
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
    "allowed_paths": ["workspace/example/project"]
  }
}|};
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    (Printf.sprintf
       {|[keeper]
sandbox_profile = "docker"
persona_name = "%s"
|}
       keeper_name);
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-persona-allowed-paths-ignored");
            ("allowed_paths", `List []);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
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
sandbox_profile = "docker"
goal = "test"
allowed_paths = ["workspace/example/project"]
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-tool-policy-custom-preserve");
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
  seed_persisted_meta config initial_meta;
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
    "proactive_enabled": true
  }
}|};
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
persona_name = "scholar"
goal = "대화에 바로 쓸 수 있는 연구 브리프를 만든다."

[keeper.tool_access]
kind = "preset"
preset = "delivery"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-persona-overlay-resync");
            ("goal", `String "stale goal");
            ("needs", `String "stale needs");
            ("instructions", `String "stale instructions");
            ("mention_targets", `List [ `String "old-target" ]);
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
  seed_persisted_meta config initial_meta;
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
      check
        (option string)
        "tool_preset from toml overlay"
        (Some "delivery")
      (Keeper_types.tool_access_preset updated.tool_access
         |> Option.map Keeper_types.tool_preset_to_string);
      check
        (option string)
        "tool_preset_source from toml overlay"
        (Some "toml")
        updated.tool_preset_source

let test_toml_integer_per_provider_timeout_updates_runtime () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "timeout-int-toml-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
goal = "test"
per_provider_timeout = 45
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-timeout-int-toml");
            ("per_provider_timeout_s", `Float 12.5);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check
        (option (float 0.0001))
        "integer TOML timeout updates runtime"
        (Some 45.0)
        updated.Keeper_types.per_provider_timeout_s

let test_toml_invalid_per_provider_timeout_clears_stale_runtime () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "timeout-invalid-toml-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
goal = "test"
per_provider_timeout = 0
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-timeout-invalid-toml");
            ("per_provider_timeout_s", `Float 12.5);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check (option (float 0.0001)) "invalid TOML clears stale timeout"
        None updated.Keeper_types.per_provider_timeout_s

let test_persona_invalid_per_provider_timeout_clears_stale_runtime () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "timeout-invalid-persona-test" in
  let personas_dir = Filename.concat config_dir "personas" in
  let persona_dir = Filename.concat personas_dir keeper_name in
  Unix.mkdir personas_dir 0o755;
  Unix.mkdir persona_dir 0o755;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|{
  "name": "timeout invalid persona",
  "keeper": {
    "goal": "test",
    "per_provider_timeout": "oops"
  }
}|};
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    (Printf.sprintf
       {|[keeper]
sandbox_profile = "docker"
persona_name = "%s"
|}
       keeper_name);
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-timeout-invalid-persona");
            ("per_provider_timeout_s", `Float 8.0);
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check (option (float 0.0001)) "invalid persona clears stale timeout"
        None updated.Keeper_types.per_provider_timeout_s

let test_meta_of_json_invalid_per_provider_timeout_is_ignored () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "meta-timeout-invalid-test");
          ("agent_name", `String "meta-timeout-invalid-test");
          ("trace_id", `String "trace-meta-timeout-invalid");
          ("per_provider_timeout_s", `String "oops");
        ])
  with
  | Error e -> fail ("meta_of_json failed: " ^ e)
  | Ok meta ->
      check (option (float 0.0001)) "invalid persisted meta timeout ignored"
        None meta.Keeper_types.per_provider_timeout_s

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
sandbox_profile = "docker"
goal = "minimal TOML"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-none-preserve");
            ("goal", `String "old goal");
            ("will", `String "runtime will");
            ("instructions", `String "runtime instructions");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      (* goal was in TOML → overwritten *)
      check string "goal overwritten" "minimal TOML" updated.Keeper_types.goal;
      (* will was NOT in TOML → preserved from runtime *)
      check string "will preserved" "runtime will" updated.will;
      (* instructions was NOT in TOML → preserved from runtime *)
      check string "instructions preserved" "runtime instructions" updated.instructions

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
sandbox_profile = "docker"
goal = "test"
work_discovery_enabled = true
work_discovery_interval_sec = 120
work_discovery_guidance = "TOML guidance"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
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
  seed_persisted_meta config initial_meta;
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
sandbox_profile = "docker"
goal = "TOML goal"

[keeper.tool_access]
kind = "preset"
preset = "social"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
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
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "goal" "TOML goal" updated.Keeper_types.goal;
      check string "cascade_name reset to keeper default"
        Keeper_config.default_cascade_name updated.cascade_name

let test_social_model_resynced_from_declarative_defaults () =
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
sandbox_profile = "docker"
goal = "TOML goal"
social_model = "magentic_ledger_v1"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
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
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Error e -> fail ("ensure_keeper_meta failed: " ^ e)
  | Ok updated ->
      check string "goal resynced from TOML" "TOML goal" updated.Keeper_types.goal;
      check string "social_model resynced from TOML" "magentic_ledger_v1"
        updated.social_model

(** Test: authored nonblank unknown cascade_name is rejected. *)
let test_unknown_cascade_name_rejected () =
  with_temp_dir "keeper-config-ssot-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keeper_name = "unknown-cascade-name-test" in
  let keepers_toml_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_toml_dir 0o755;
  write_file
    (Filename.concat keepers_toml_dir (keeper_name ^ ".toml"))
    {|[keeper]
sandbox_profile = "docker"
goal = "TOML goal"
cascade_name = "missing_profile"
|};
  let config = Coord.default_config room_dir in
  let initial_meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-unknown-cascade-name");
            ("goal", `String "stale goal");
          ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json failed: " ^ e)
  in
  seed_persisted_meta config initial_meta;
  match Keeper_runtime.ensure_keeper_meta config keeper_name with
  | Ok updated ->
      failf "expected unknown cascade_name to be rejected, got %s"
        updated.cascade_name
  | Error detail ->
      check bool "points at profile.cascade_name" true
        (contains_substring detail "profile.cascade_name");
      check bool "mentions unknown cascade_name" true
        (contains_substring detail "unknown cascade_name")

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
      Masc_test_deps.meta_of_json_fixture
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
  seed_persisted_meta config initial_meta;
  ignore
    (Coord.join config ~agent_name ~capabilities:[ "keeper"; "preset:minimal" ] ());
  let _synced = Keeper_exec_context.ensure_keeper_room_presence config initial_meta in
  let agent =
    Coord.get_agents_raw config
    |> List.find_opt (fun (agent : Masc_domain.agent) -> String.equal agent.name agent_name)
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
sandbox_profile = "docker"
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
sandbox_profile = "docker"
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

(* PR-3b1: canonicalize_if_keeper redirects bare lookup names to
   their [keeper-<n>-agent] canonical form when the name belongs to
   a configured keeper, leaving non-keeper credentials (dashboard,
   admin, codex-mcp-client, ...) untouched. Spec: AuthIdentityFSM
   I1 IdentityBindsToken. *)
let test_canonicalize_if_keeper () =
  with_temp_dir "canonicalize-room" @@ fun room_dir ->
  with_config_dir @@ fun config_dir ->
  Fs_compat.clear_fs ();
  let keepers_dir = Filename.concat config_dir "keepers" in
  Unix.mkdir keepers_dir 0o755;
  write_file
    (Filename.concat keepers_dir "sangsu.toml")
    {|[keeper]
sandbox_profile = "docker"
goal = "test goal"
|};
  let config = Coord.default_config room_dir in
  check string "bare keeper name -> canonical"
    "keeper-sangsu-agent"
    (Keeper_runtime.canonicalize_if_keeper config "sangsu");
  check string "canonical keeper name -> canonical (idempotent)"
    "keeper-sangsu-agent"
    (Keeper_runtime.canonicalize_if_keeper config "keeper-sangsu-agent");
  check string "non-keeper name (dashboard) passes through untouched"
    "dashboard"
    (Keeper_runtime.canonicalize_if_keeper config "dashboard");
  check string "non-keeper name (admin) passes through untouched"
    "admin"
    (Keeper_runtime.canonicalize_if_keeper config "admin");
  check string "non-keeper name (codex-mcp-client) passes through untouched"
    "codex-mcp-client"
    (Keeper_runtime.canonicalize_if_keeper config "codex-mcp-client")

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
            "keeper_up create path uses TOML sandbox policy defaults"
            `Quick
            test_keeper_up_create_uses_profile_default_sandbox_policy;
          test_case
            "TOML tool policy fields overwrite stale runtime JSON"
            `Quick
            test_tool_policy_resync;
          test_case
            "TOML tool_preset_source resyncs without policy delta"
            `Quick
            test_tool_preset_source_resyncs_from_toml_without_policy_delta;
          test_case
            "persona no longer drives tool_preset_source"
            `Quick
            test_persona_no_longer_drives_tool_preset_source;
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
          test_case
            "integer TOML per_provider_timeout updates runtime JSON"
            `Quick
            test_toml_integer_per_provider_timeout_updates_runtime;
          test_case
            "invalid TOML per_provider_timeout clears stale runtime JSON"
            `Quick
            test_toml_invalid_per_provider_timeout_clears_stale_runtime;
          test_case
            "invalid persona per_provider_timeout clears stale runtime JSON"
            `Quick
            test_persona_invalid_per_provider_timeout_clears_stale_runtime;
          test_case
            "invalid persisted per_provider_timeout is ignored on parse"
            `Quick
            test_meta_of_json_invalid_per_provider_timeout_is_ignored;
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
            "declarative defaults resync social_model"
            `Quick
            test_social_model_resynced_from_declarative_defaults;
          test_case
            "unknown nonblank cascade_name is rejected"
            `Quick
            test_unknown_cascade_name_rejected;
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
      ( "canonicalize",
        [
          test_case
            "canonicalize_if_keeper bare->canonical, passthrough non-keeper"
            `Quick
            test_canonicalize_if_keeper;
        ] );
    ]
