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
  let config = Room.default_config room_dir in
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
execution_scope = "playground"
scope_kind = "global"
room_scope = "current"
policy_voice_enabled = false
|};
  let config = Room.default_config room_dir in
  let initial_meta =
    match
      Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String keeper_name);
            ("trace_id", `String "trace-policy-resync");
            ("execution_scope", `String "standard");
            ("scope_kind", `String "local");
            ("room_scope", `String "all");
            ("policy_voice_enabled", `Bool true);
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
      check string "execution_scope" "playground" updated.Keeper_types.execution_scope;
      check string "scope_kind" "global" updated.scope_kind;
      check string "room_scope" "current" updated.room_scope;
      check bool "policy_voice_enabled" false updated.policy_voice_enabled

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
allowed_paths = ["workspace/yousleepwhen/masc-mcp"]
tool_preset = "social"
also_allow = ["keeper_github", "keeper_shell"]
|};
  let config = Room.default_config room_dir in
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
        [ "keeper_github"; "keeper_shell" ]
        (Keeper_types.tool_access_also_allowlist updated.tool_access);
      check
        (list string)
        "allowed_paths"
        [ "workspace/yousleepwhen/masc-mcp" ]
        updated.allowed_paths

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
  let config = Room.default_config room_dir in
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
            ("execution_scope", `String "playground");
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
      (* goal was in TOML → overwritten *)
      check string "goal overwritten" "minimal TOML" updated.Keeper_types.goal;
      (* will was NOT in TOML → preserved from runtime *)
      check string "will preserved" "runtime will" updated.will;
      (* instructions was NOT in TOML → preserved from runtime *)
      check string "instructions preserved" "runtime instructions" updated.instructions;
      (* execution_scope was NOT in TOML → preserved from runtime *)
      check string "execution_scope preserved" "playground" updated.execution_scope

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
  let config = Room.default_config room_dir in
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

(** Test: update_field_in_content replaces existing field *)
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
            "TOML tool policy fields overwrite stale runtime JSON"
            `Quick
            test_tool_policy_resync;
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
