(** Test keeper masc_* tool bridge under preset/custom tool policy. *)

module KET = Masc_mcp.Keeper_exec_tools

let init_keeper_tool_registry () =
  Masc_test_deps.init_keeper_tool_registry ()

let prime_keeper_bridge () =
  init_keeper_tool_registry ();
  ignore (Masc_mcp.Mcp_server_eio.get_clock_opt ());
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas


let make_meta ?tool_access ?(tool_denylist = []) () =
  let tool_access =
    match tool_access with
    | Some access -> access
    | None ->
        Masc_mcp.Keeper_types.Preset
          { preset = Masc_mcp.Keeper_types.Full; also_allow = [] }
  in
  match Masc_mcp.Keeper_types.meta_of_json
    (`Assoc
      [
        ("name", `String "keeper-bridge-test");
        ("agent_name", `String "keeper-bridge-test");
        ("trace_id", `String "keeper-bridge-trace");
        ("tool_access", Masc_mcp.Keeper_types.tool_access_to_json tool_access);
        ("tool_denylist", `List (List.map (fun s -> `String s) tool_denylist));
      ])
  with
  | Ok meta -> meta
  | Error e -> failwith e

let allowed_names_of_json json =
  prime_keeper_bridge ();
  match Masc_mcp.Keeper_types.meta_of_json json with
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
  (* github moved out of messaging to reduce surface; available in coding/delivery *)
  Alcotest.(check bool) "no keeper_github in messaging" false
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

let test_tool_access_legacy_unrestricted_maps_to_full () =
  let names =
    allowed_names_of_json
      (`Assoc
        [
          ("name", `String "legacy-unrestricted");
          ("agent_name", `String "legacy-unrestricted");
          ("trace_id", `String "legacy-unrestricted-trace");
          ("tool_access", `Assoc [ ("kind", `String "unrestricted") ]);
        ])
  in
  Alcotest.(check bool) "full keeps keeper internal tool" true
    (List.mem "keeper_fs_edit" names);
  Alcotest.(check bool) "full keeps autoresearch tool" true
    (List.mem "masc_autoresearch_cycle" names)

let test_tool_access_legacy_restricted_keeps_internal_and_listed_tools () =
  let names =
    allowed_names_of_json
      (`Assoc
        [
          ("name", `String "legacy-restricted");
          ("agent_name", `String "legacy-restricted");
          ("trace_id", `String "legacy-restricted-trace");
          ( "tool_access",
            `Assoc
              [
                ("kind", `String "restricted");
                ("tools", `List [ `String "masc_status" ]);
              ] );
        ])
  in
  Alcotest.(check bool) "restricted keeps keeper internal tool" true
    (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "restricted keeps listed masc tool" true
    (List.mem "masc_status" names);
  Alcotest.(check bool) "restricted does not unlock unrelated masc tool" false
    (List.mem "masc_autoresearch_cycle" names)

let test_tool_access_projection_preset_keys_loaded () =
  let meta =
    match Masc_mcp.Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String "compat-preset");
          ("agent_name", `String "compat-preset");
          ("trace_id", `String "compat-preset-trace");
          ("tool_preset", `String "coding");
          ("tool_also_allow", `List [ `String "masc_governance_status" ]);
        ])
    with
    | Ok meta -> meta
    | Error e -> failwith e
  in
  match meta.Masc_mcp.Keeper_types.tool_access with
  | Masc_mcp.Keeper_types.Preset
      { preset = Masc_mcp.Keeper_types.Coding; also_allow } ->
      Alcotest.(check (list string))
        "compat preset keeps also_allow"
        [ "masc_governance_status" ] also_allow
  | _ -> Alcotest.fail "expected coding preset from compatibility keys"

let test_tool_access_projection_custom_allowlist_loaded () =
  let meta =
    match Masc_mcp.Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String "compat-custom");
          ("agent_name", `String "compat-custom");
          ("trace_id", `String "compat-custom-trace");
          ("tool_custom_allowlist", `List [ `String "masc_status" ]);
        ])
    with
    | Ok meta -> meta
    | Error e -> failwith e
  in
  match meta.Masc_mcp.Keeper_types.tool_access with
  | Masc_mcp.Keeper_types.Custom names ->
      Alcotest.(check (list string))
        "compat custom allowlist preserved"
        [ "masc_status" ] names
  | _ -> Alcotest.fail "expected Custom allowlist from compatibility keys"

let test_tool_access_projection_invalid_preset_rejected () =
  match Masc_mcp.Keeper_types.meta_of_json
    (`Assoc
      [
        ("name", `String "compat-invalid-preset");
        ("agent_name", `String "compat-invalid-preset");
        ("trace_id", `String "compat-invalid-preset-trace");
        ("tool_preset", `String "bogus");
      ])
  with
  | Ok _ -> Alcotest.fail "expected invalid compatibility preset to fail"
  | Error e ->
      Alcotest.(check string)
        "invalid compatibility preset error"
        "meta parse error: invalid keeper tool_preset: bogus"
        e

let test_tool_access_preset_empty_json_preserved () =
  let meta =
    match Masc_mcp.Keeper_types.meta_of_json
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
    match Masc_mcp.Keeper_types.meta_of_json
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
  match Masc_mcp.Keeper_types.meta_of_json
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
  match Masc_mcp.Keeper_types.meta_of_json
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
  match Masc_mcp.Keeper_types.meta_of_json
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
  match Masc_mcp.Keeper_types.meta_of_json
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
  match Masc_mcp.Keeper_types.meta_of_json
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
  match Masc_mcp.Keeper_types.meta_of_json
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
  Alcotest.(check bool) "masc_room_delete is denied" true
    (KET.is_keeper_denied "masc_room_delete");
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
          Alcotest.test_case "missing tool_access migrates legacy standard policy" `Quick
            test_tool_access_missing_migrates_legacy_standard_policy;
          Alcotest.test_case "legacy unrestricted maps to full" `Quick
            test_tool_access_legacy_unrestricted_maps_to_full;
          Alcotest.test_case "legacy restricted keeps internal tools" `Quick
            test_tool_access_legacy_restricted_keeps_internal_and_listed_tools;
          Alcotest.test_case "compat preset keys load preset policy" `Quick
            test_tool_access_projection_preset_keys_loaded;
          Alcotest.test_case "compat custom allowlist loads custom policy" `Quick
            test_tool_access_projection_custom_allowlist_loaded;
          Alcotest.test_case "compat invalid preset rejected" `Quick
            test_tool_access_projection_invalid_preset_rejected;
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
