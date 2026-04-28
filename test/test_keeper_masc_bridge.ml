(** Test keeper masc_* tool bridge under preset/custom tool policy. *)

module Coord = Masc_mcp.Coord
module KET = Masc_mcp.Keeper_exec_tools

let init_keeper_tool_registry () =
  Masc_test_deps.init_keeper_tool_registry ()

let prime_keeper_bridge () =
  init_keeper_tool_registry ();
  ignore (Masc_mcp.Mcp_server_eio.get_clock_opt ());
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas

let temp_dir () =
  let path = Filename.temp_file "keeper_meta_bridge_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let write_text_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let run_shell_ok ~cwd cmd =
  let quoted_cwd = Filename.quote cwd in
  let rc = Sys.command (Printf.sprintf "cd %s && %s" quoted_cwd cmd) in
  Alcotest.(check int) ("shell command: " ^ cmd) 0 rc

let run_with_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let write_json_file path json =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (Yojson.Safe.pretty_to_string json))

let read_json_file path = Yojson.Safe.from_file path


let make_meta ?(name = "keeper-bridge-test") ?tool_access ?(tool_denylist = [])
    ?(sandbox_profile = Masc_mcp.Keeper_types.Local) () =
  let tool_access =
    match tool_access with
    | Some access -> access
    | None ->
        Masc_mcp.Keeper_types.Preset
          { preset = Masc_mcp.Keeper_types.Full; also_allow = [] }
  in
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String name);
        ("agent_name", `String name);
        ("trace_id", `String (name ^ "-trace"));
        ( "sandbox_profile",
          `String
            (Masc_mcp.Keeper_types.sandbox_profile_to_string sandbox_profile)
        );
        ("tool_access", Masc_mcp.Keeper_types.tool_access_to_json tool_access);
        ("tool_denylist", `List (List.map (fun s -> `String s) tool_denylist));
      ])
  with
  | Ok meta -> meta
  | Error e -> failwith e

let allowed_names_of_json json =
  prime_keeper_bridge ();
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> KET.keeper_allowed_tool_names meta
  | Error e -> failwith e

let test_inject_stores_filtered_masc () =
  init_keeper_tool_registry ();
  let schemas : Types.tool_schema list =
    [
      { name = "masc_status"; description = ""; input_schema = `Assoc [] };
      { name = "masc_broadcast"; description = ""; input_schema = `Assoc [] };
      { name = "masc_messages"; description = ""; input_schema = `Assoc [] };
      { name = "keeper_time_now"; description = ""; input_schema = `Assoc [] };
    ]
  in
  ignore (Masc_mcp.Mcp_server_eio.get_clock_opt ());
  KET.inject_masc_schemas schemas;
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Custom
           [ "masc_status"; "masc_broadcast"; "masc_messages" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "only keeper-compatible masc tools remain" 1
    (List.length names);
  Alcotest.(check bool) "keeps masc_status" true
    (List.mem "masc_status" names);
  Alcotest.(check bool) "filters masc_broadcast" false
    (List.mem "masc_broadcast" names);
  Alcotest.(check bool) "filters masc_messages" false
    (List.mem "masc_messages" names);
  Alcotest.(check bool) "no keeper_time_now" false
    (List.mem "keeper_time_now" names)

let test_full_preset_exposes_masc () =
  prime_keeper_bridge ();
  let meta = make_meta () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  (* Governance tools are no longer in raw_all_tool_schemas *)
  Alcotest.(check bool) "no masc_governance_status" false
    (List.mem "masc_governance_status" names);
  Alcotest.(check bool) "has masc_autoresearch_cycle" true
    (List.mem "masc_autoresearch_cycle" names);
  Alcotest.(check bool) "filters unsupported inline tool" false
    (List.mem "masc_who" names)

let test_messaging_preset_exposes_board () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Preset
           { preset = Masc_mcp.Keeper_types.Messaging; also_allow = [] })
      ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "has keeper_board_post" true
    (List.mem "keeper_board_post" names);
  (* Governance tools are no longer available *)
  Alcotest.(check bool) "no masc_governance_status" false
    (List.mem "masc_governance_status" names);
  Alcotest.(check bool) "has keeper_shell" true
    (List.mem "keeper_shell" names);
  (* keeper_github tool was removed in #7306 (use keeper_shell op=gh). *)
  Alcotest.(check bool) "no keeper_github (removed)" false
    (List.mem "keeper_github" names);
  Alcotest.(check bool) "has keeper_fs_read" true
    (List.mem "keeper_fs_read" names)

let test_custom_opens_specific_tools_only () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Custom
           [ "masc_status"; "masc_tasks"; "masc_join" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "only keeper-compatible tools allowed" 2
    (List.length names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_tasks" true
    (List.mem "masc_tasks" names);
  Alcotest.(check bool) "filters masc_join" false
    (List.mem "masc_join" names);
  Alcotest.(check bool) "no masc_board_post" false
    (List.mem "masc_board_post" names)

let test_deny_overrides_allow () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Custom
           [ "masc_status"; "masc_tasks"; "masc_join" ])
      ~tool_denylist:[ "masc_tasks" ] ()
  in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "1 after deny" 1 (List.length names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "no masc_tasks (denied)" false
    (List.mem "masc_tasks" names)

let test_custom_empty_blocks_all () =
  prime_keeper_bridge ();
  let meta =
    make_meta ~tool_access:(Masc_mcp.Keeper_types.Custom []) ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check int) "no tools" 0 (List.length names)

let test_preset_with_also_allow_opens_extra_tool () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Preset
           {
             preset = Masc_mcp.Keeper_types.Minimal;
             also_allow = [ "masc_tasks" ];
           })
      ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "minimal keeps base tool" true
    (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "also_allow adds tasks" true
    (List.mem "masc_tasks" names);
  Alcotest.(check bool) "minimal omits board post" false
    (List.mem "keeper_board_post" names)

let test_custom_keeps_registered_inline_board_tool () =
  init_keeper_tool_registry ();
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Custom
           [ "keeper_board_post"; "masc_who" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  (* keeper_board_post is a keeper-internal tool, not a masc_ schema;
     it won't appear in masc tool names but will be in the full allowed set *)
  Alcotest.(check bool) "raw masc_board_post filtered out" false
    (List.mem "masc_board_post" names);
  Alcotest.(check bool) "drops unsupported inline tool" false
    (List.mem "masc_who" names)

let with_masc_schema_ref schemas f =
  let previous = !(KET.masc_schemas_ref) in
  Fun.protect
    ~finally:(fun () -> KET.masc_schemas_ref := previous)
    (fun () ->
      KET.masc_schemas_ref := schemas;
      f ())

let test_dashboard_tool_count_uses_schema_ssot () =
  let bridge_name = "mcp__masc__masc_status" in
  let schema : Types.tool_schema =
    { name = bridge_name; description = ""; input_schema = `Assoc [] }
  in
  with_masc_schema_ref [ schema ] (fun () ->
      let meta =
        make_meta
          ~tool_access:
            (Masc_mcp.Keeper_types.Custom [ bridge_name ])
          ()
      in
      let allowed = KET.keeper_allowed_tool_names meta in
      Alcotest.(check bool) "schema bridge is allowed" true
        (List.mem bridge_name allowed);
      let json =
        Masc_mcp.Server_dashboard_http_keeper_api.keeper_tools_response_json meta
      in
      let count =
        Yojson.Safe.Util.(json |> member "active_masc_tool_count" |> to_int)
      in
      Alcotest.(check int) "dashboard counts schema-derived masc tools" 1 count)

let test_tool_access_missing_migrates_legacy_standard_policy () =
  let names =
    allowed_names_of_json
      (`Assoc
        [
          ("name", `String "legacy-standard");
          ("agent_name", `String "legacy-standard");
          ("trace_id", `String "legacy-standard-trace");
        ])
  in
  let legacy_masc_names =
    names
    |> List.filter (fun name -> String.starts_with ~prefix:"masc_" name)
    |> List.sort_uniq String.compare
  in
  let expected_legacy_masc_names =
    [
      "masc_status";
      "masc_tasks";
      "masc_claim_next";
      "masc_plan_set_task";
      "masc_transition";
      "masc_add_task";
    ]
    |> List.sort_uniq String.compare
  in
  Alcotest.(check bool) "keeps keeper internal tool" true
    (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "keeps legacy standard masc tool" true
    (List.mem "masc_status" names);
  Alcotest.(check (list string)) "legacy migration keeps expected masc set"
    expected_legacy_masc_names legacy_masc_names;
  Alcotest.(check bool) "does not silently expand to full" false
    (List.mem "masc_autoresearch_cycle" names)

let test_read_meta_file_scrubs_compat_tool_keys () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let path = Filename.concat dir "compat-preset.json" in
      write_json_file path
        (`Assoc
          [
            ("name", `String "compat-preset");
            ("agent_name", `String "compat-preset");
            ("trace_id", `String "compat-preset-trace");
            ("tool_preset", `String "coding");
            ("tool_also_allow", `List [ `String "masc_governance_status" ]);
            ("allowed_providers", `List [ `String "glm" ]);
          ]);
      match Masc_mcp.Keeper_types.read_meta_file_path path with
      | Error e -> Alcotest.fail e
      | Ok None -> Alcotest.fail "expected keeper meta"
      | Ok (Some meta) ->
          (match meta.Masc_mcp.Keeper_types.tool_access with
           | Masc_mcp.Keeper_types.Preset
               { preset = Masc_mcp.Keeper_types.Coding; also_allow } ->
               Alcotest.(check (list string))
                 "compat preset scrub keeps also_allow"
                 [ "masc_governance_status" ] also_allow
           | _ -> Alcotest.fail "expected coding preset after scrub");
          let scrubbed = read_json_file path in
          Alcotest.(check bool) "tool_access persisted" true
            (Yojson.Safe.Util.member "tool_access" scrubbed <> `Null);
          Alcotest.(check bool) "tool_preset removed" true
            (Yojson.Safe.Util.member "tool_preset" scrubbed = `Null);
          Alcotest.(check bool) "tool_also_allow removed" true
            (Yojson.Safe.Util.member "tool_also_allow" scrubbed = `Null);
          Alcotest.(check bool) "allowed_providers removed" true
            (Yojson.Safe.Util.member "allowed_providers" scrubbed = `Null))

let test_read_meta_file_scrubs_legacy_tool_access_kind () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let path = Filename.concat dir "legacy-unrestricted.json" in
      write_json_file path
        (`Assoc
          [
            ("name", `String "legacy-unrestricted");
            ("agent_name", `String "legacy-unrestricted");
            ("trace_id", `String "legacy-unrestricted-trace");
            ("tool_access", `Assoc [ ("kind", `String "unrestricted") ]);
          ]);
      match Masc_mcp.Keeper_types.read_meta_file_path path with
      | Error e -> Alcotest.fail e
      | Ok None -> Alcotest.fail "expected keeper meta"
      | Ok (Some meta) ->
          let names = KET.keeper_allowed_tool_names meta in
          Alcotest.(check bool) "full keeps keeper internal tool" true
            (List.mem "keeper_fs_edit" names);
          Alcotest.(check bool) "full keeps autoresearch tool" true
            (List.mem "masc_autoresearch_cycle" names);
          let scrubbed = read_json_file path in
          Alcotest.(check string) "legacy kind rewritten"
            "preset"
            (Yojson.Safe.Util.member "tool_access" scrubbed
             |> Yojson.Safe.Util.member "kind"
             |> Yojson.Safe.Util.to_string))

let test_read_meta_file_scrubs_missing_tool_access_default () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let path = Filename.concat dir "legacy-standard.json" in
      write_json_file path
        (`Assoc
          [
            ("name", `String "legacy-standard");
            ("agent_name", `String "legacy-standard");
            ("trace_id", `String "legacy-standard-trace");
          ]);
      match Masc_mcp.Keeper_types.read_meta_file_path path with
      | Error e -> Alcotest.fail e
      | Ok None -> Alcotest.fail "expected keeper meta"
      | Ok (Some _meta) ->
          let scrubbed = read_json_file path in
          Alcotest.(check bool) "default tool_access persisted" true
            (Yojson.Safe.Util.member "tool_access" scrubbed <> `Null))

let test_meta_of_json_rejects_legacy_tool_policy_keys () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "compat-preset");
        ("agent_name", `String "compat-preset");
        ("trace_id", `String "compat-preset-trace");
        ("tool_preset", `String "coding");
      ])
  with
  | Ok _ -> Alcotest.fail "expected legacy tool policy key rejection"
  | Error e ->
      Alcotest.(check string)
        "legacy direct parse rejected"
        "legacy keeper meta fields require scrub via read_meta_file_path: tool_preset"
        e

let test_tool_access_preset_empty_json_preserved () =
  let meta =
    match Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "preset-json");
          ("agent_name", `String "preset-json");
          ("trace_id", `String "preset-json-trace");
          ( "tool_access",
            `Assoc
              [
                ("kind", `String "preset");
                ("preset", `String "coding");
                ("also_allow", `List []);
              ] );
        ])
    with
    | Ok meta -> meta
    | Error e -> failwith e
  in
  match meta.Masc_mcp.Keeper_types.tool_access with
  | Masc_mcp.Keeper_types.Preset
      { preset = Masc_mcp.Keeper_types.Coding; also_allow } ->
      Alcotest.(check int) "preset empty preserved" 0 (List.length also_allow)
  | _ -> Alcotest.fail "expected coding preset with empty also_allow"

let test_tool_access_custom_empty_json_preserved () =
  let meta =
    match Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "custom-json");
          ("agent_name", `String "custom-json");
          ("trace_id", `String "custom-json-trace");
          ( "tool_access",
            `Assoc
              [
                ("kind", `String "custom");
                ("tools", `List []);
              ] );
        ])
    with
    | Ok meta -> meta
    | Error e -> failwith e
  in
  match meta.Masc_mcp.Keeper_types.tool_access with
  | Masc_mcp.Keeper_types.Custom names ->
      Alcotest.(check int) "custom empty preserved" 0 (List.length names)
  | _ -> Alcotest.fail "expected Custom []"

let test_tool_access_invalid_kind_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "invalid-kind");
        ("agent_name", `String "invalid-kind");
        ("trace_id", `String "invalid-kind-trace");
        ("tool_access", `Assoc [ ("kind", `String "bogus") ]);
      ])
  with
  | Ok _ -> Alcotest.fail "expected invalid kind to fail"
  | Error e ->
      Alcotest.(check string)
        "invalid kind error"
        "meta parse error: invalid keeper tool_access.kind: bogus"
        e

let test_tool_access_missing_kind_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "missing-kind");
        ("agent_name", `String "missing-kind");
        ("trace_id", `String "missing-kind-trace");
        ("tool_access", `Assoc [ ("tools", `List []) ]);
      ])
  with
  | Ok _ -> Alcotest.fail "expected missing kind to fail"
  | Error e ->
      Alcotest.(check string)
        "missing kind error"
        "meta parse error: keeper tool_access.kind required"
        e

let test_tool_access_missing_preset_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "missing-preset");
        ("agent_name", `String "missing-preset");
        ("trace_id", `String "missing-preset-trace");
        ("tool_access", `Assoc [ ("kind", `String "preset") ]);
      ])
  with
  | Ok _ -> Alcotest.fail "expected missing preset to fail"
  | Error e ->
      Alcotest.(check string)
        "missing preset error"
        "meta parse error: keeper tool_access.preset required"
        e

let test_tool_access_invalid_preset_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "invalid-preset");
        ("agent_name", `String "invalid-preset");
        ("trace_id", `String "invalid-preset-trace");
        ( "tool_access",
          `Assoc
            [
              ("kind", `String "preset");
              ("preset", `String "bogus");
            ] );
      ])
  with
  | Ok _ -> Alcotest.fail "expected invalid preset to fail"
  | Error e ->
      Alcotest.(check string)
        "invalid preset error"
        "meta parse error: invalid keeper tool_access.preset: bogus"
        e

let test_tool_access_missing_tools_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "missing-tools");
        ("agent_name", `String "missing-tools");
        ("trace_id", `String "missing-tools-trace");
        ("tool_access", `Assoc [ ("kind", `String "custom") ]);
      ])
  with
  | Ok _ -> Alcotest.fail "expected missing tools to fail"
  | Error e ->
      Alcotest.(check string)
        "missing tools error"
        "meta parse error: keeper tool_access.tools must be an array of strings"
        e

let test_tool_access_invalid_tool_member_rejected () =
  match Masc_test_deps.meta_of_json_fixture
    (`Assoc
      [
        ("name", `String "invalid-tool-member");
        ("agent_name", `String "invalid-tool-member");
        ("trace_id", `String "invalid-tool-member-trace");
        ( "tool_access",
          `Assoc
            [
              ("kind", `String "custom");
              ("tools", `List [ `String "masc_status"; `Int 1 ]);
            ] );
      ])
  with
  | Ok _ -> Alcotest.fail "expected invalid tool member to fail"
  | Error e ->
      Alcotest.(check string)
        "invalid tool member error"
        "meta parse error: keeper tool_access.tools[1] must be a string"
        e

let test_allowlist_gates_shard_tools () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Custom
           [ "masc_status"; "masc_tasks" ])
      ()
  in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_tasks" true
    (List.mem "masc_tasks" names);
  Alcotest.(check bool) "masc_autoresearch_cycle blocked by custom policy" false
    (List.mem "masc_autoresearch_cycle" names)

let test_dispatch_unregistered () =
  let result =
    Masc_mcp.Tool_dispatch.mint_token ~name:"masc_nonexistent_xyz"
  in
  Alcotest.(check bool) "unregistered mint_token returns Error" true (Result.is_error result)

let test_read_only_preflight_accepts_sandbox_relative_repo_path () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      run_shell_ok ~cwd:dir "git init --quiet";
      let file_path =
        Filename.concat dir
          ".masc/playground/docker/masc-improver/repos/masc-mcp/lib/thompson_sampling.ml"
      in
      ensure_dir (Filename.dirname file_path);
      write_text_file file_path "let alpha = 0.1\nlet beta = 0.2\n";
      run_with_fs (fun () ->
        let config = Coord.default_config dir in
        ignore (Coord.init config ~agent_name:(Some "masc-improver"));
        let meta =
          make_meta
            ~name:"masc-improver"
            ~sandbox_profile:Masc_mcp.Keeper_types.Docker
            ~tool_access:(Masc_mcp.Keeper_types.Custom [ "masc_code_read" ])
            ()
        in
        let raw =
          Masc_mcp.Keeper_exec_masc.handle_keeper_masc_tool
            ~config
            ~meta
            ~name:"masc_code_read"
            ~args:
              (`Assoc
                [
                  ("path", `String "repos/masc-mcp/lib/thompson_sampling.ml");
                  ("offset", `Int 0);
                  ("limit", `Int 2);
                ])
        in
        let json = Yojson.Safe.from_string raw in
        let path =
          Yojson.Safe.Util.member "path" json |> Yojson.Safe.Util.to_string
        in
        let lines =
          Yojson.Safe.Util.member "lines" json
          |> Yojson.Safe.Util.to_list
          |> List.map Yojson.Safe.Util.to_string
        in
        Alcotest.(check string) "path preserved"
          "repos/masc-mcp/lib/thompson_sampling.ml"
          path;
        Alcotest.(check (list string)) "reads expected lines"
          [ "let alpha = 0.1"; "let beta = 0.2" ]
          lines))

let test_schemas_match_names () =
  prime_keeper_bridge ();
  let meta =
    make_meta
      ~tool_access:
        (Masc_mcp.Keeper_types.Custom
           [ "masc_status"; "masc_join"; "masc_tasks" ])
      ()
  in
  let names = KET.keeper_masc_tool_names meta in
  let schemas = KET.keeper_masc_tool_schemas meta in
  Alcotest.(check int) "count matches"
    (List.length names) (List.length schemas);
  List.iter
    (fun (s : Types.tool_schema) ->
      Alcotest.(check bool) (s.name ^ " in names") true
        (List.mem s.name names))
    schemas

let test_denied_tools_excluded_from_injection () =
  prime_keeper_bridge ();
  let meta = make_meta () in
  let names = KET.keeper_masc_tool_names meta in
  let denied =
    Masc_mcp.Tool_catalog.tools_for_surface Masc_mcp.Tool_catalog.Keeper_denied
  in
  List.iter
    (fun denied_name ->
      Alcotest.(check bool)
        (denied_name ^ " must not appear")
        false (List.mem denied_name names))
    denied

let test_is_keeper_denied () =
  (* Post-pruning: keeper_denied surface is [masc_reset; masc_spawn]. *)
  Alcotest.(check bool) "masc_reset is denied" true
    (KET.is_keeper_denied "masc_reset");
  Alcotest.(check bool) "masc_spawn is denied" true
    (KET.is_keeper_denied "masc_spawn");
  Alcotest.(check bool) "masc_status is not denied" false
    (KET.is_keeper_denied "masc_status");
  Alcotest.(check bool) "keeper_time_now is not denied" false
    (KET.is_keeper_denied "keeper_time_now")

let test_denied_excluded_from_allowed_names () =
  prime_keeper_bridge ();
  let meta = make_meta () in
  let names = KET.keeper_allowed_tool_names meta in
  let denied =
    Masc_mcp.Tool_catalog.tools_for_surface Masc_mcp.Tool_catalog.Keeper_denied
  in
  List.iter
    (fun denied_name ->
      Alcotest.(check bool)
        (denied_name ^ " must not appear in allowed_names")
        false (List.mem denied_name names))
    denied;
  Alcotest.(check bool) "keeper_time_now still present" true
    (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "masc_status still present" true
    (List.mem "masc_status" names)

let () =
  let base_path = Masc_test_deps.find_project_root () in
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  ignore (Result.get_ok (KET.init_policy_config ~base_path));
  Alcotest.run "Keeper masc bridge"
    [
      ( "injection",
        [
          Alcotest.test_case "stores filtered masc_* schemas" `Quick
            test_inject_stores_filtered_masc;
        ] );
      ( "preset_policy",
        [
          Alcotest.test_case "full preset exposes masc tools" `Quick
            test_full_preset_exposes_masc;
          Alcotest.test_case "messaging preset exposes board" `Quick
            test_messaging_preset_exposes_board;
          Alcotest.test_case "preset also_allow opens extra tool" `Quick
            test_preset_with_also_allow_opens_extra_tool;
          Alcotest.test_case "custom filters board tools with keeper wrappers" `Quick
            test_custom_keeps_registered_inline_board_tool;
          Alcotest.test_case "dashboard count uses schema SSOT" `Quick
            test_dashboard_tool_count_uses_schema_ssot;
        ] );
      ( "custom_policy",
        [
          Alcotest.test_case "opens specific tools" `Quick
            test_custom_opens_specific_tools_only;
          Alcotest.test_case "deny overrides allow" `Quick
            test_deny_overrides_allow;
          Alcotest.test_case "custom empty blocks all" `Quick
            test_custom_empty_blocks_all;
          Alcotest.test_case "gates shard tools too" `Quick
            test_allowlist_gates_shard_tools;
        ] );
      ( "meta_json",
        [
          Alcotest.test_case "missing tool_access defaults standard policy" `Quick
            test_tool_access_missing_migrates_legacy_standard_policy;
          Alcotest.test_case "read_meta scrub compat keys to tool_access" `Quick
            test_read_meta_file_scrubs_compat_tool_keys;
          Alcotest.test_case "read_meta scrub legacy tool_access kind" `Quick
            test_read_meta_file_scrubs_legacy_tool_access_kind;
          Alcotest.test_case "read_meta scrub missing tool_access" `Quick
            test_read_meta_file_scrubs_missing_tool_access_default;
          Alcotest.test_case "direct meta_of_json rejects legacy tool keys" `Quick
            test_meta_of_json_rejects_legacy_tool_policy_keys;
          Alcotest.test_case "preset empty json preserved" `Quick
            test_tool_access_preset_empty_json_preserved;
          Alcotest.test_case "custom empty json preserved" `Quick
            test_tool_access_custom_empty_json_preserved;
          Alcotest.test_case "invalid kind rejected" `Quick
            test_tool_access_invalid_kind_rejected;
          Alcotest.test_case "missing kind rejected" `Quick
            test_tool_access_missing_kind_rejected;
          Alcotest.test_case "missing preset rejected" `Quick
            test_tool_access_missing_preset_rejected;
          Alcotest.test_case "invalid preset rejected" `Quick
            test_tool_access_invalid_preset_rejected;
          Alcotest.test_case "missing tools rejected" `Quick
            test_tool_access_missing_tools_rejected;
          Alcotest.test_case "invalid tool member rejected" `Quick
            test_tool_access_invalid_tool_member_rejected;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "unregistered returns None" `Quick
            test_dispatch_unregistered;
          Alcotest.test_case
            "read preflight accepts sandbox-relative repo path" `Quick
            test_read_only_preflight_accepts_sandbox_relative_repo_path;
        ] );
      ( "consistency",
        [
          Alcotest.test_case "schemas match names" `Quick test_schemas_match_names;
        ] );
      ( "keeper_denied",
        [
          Alcotest.test_case "denied tools excluded from injection" `Quick
            test_denied_tools_excluded_from_injection;
          Alcotest.test_case "is_keeper_denied correctness" `Quick
            test_is_keeper_denied;
          Alcotest.test_case "denied excluded from allowed_names" `Quick
            test_denied_excluded_from_allowed_names;
        ] );
    ]
