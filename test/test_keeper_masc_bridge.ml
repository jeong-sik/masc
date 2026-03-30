(** Test keeper masc_* tool bridge — verifies allowlist/denylist gating
    and schema injection for keeper tool exposure. *)

module KET = Masc_mcp.Keeper_exec_tools

let make_meta ?tool_access ?tool_allowlist ?(tool_denylist = []) () =
  let tool_access =
    match tool_access, tool_allowlist with
    | Some access, _ -> access
    | None, Some names -> Masc_mcp.Keeper_types.Restricted names
    | None, None -> Masc_mcp.Keeper_types.Unrestricted
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

(** Verify inject_masc_schemas stores all masc_* schemas (no filtering). *)
let test_inject_stores_all_masc () =
  let schemas : Types.tool_schema list =
    [
      { name = "masc_status"; description = ""; input_schema = `Assoc [] };
      { name = "masc_broadcast"; description = ""; input_schema = `Assoc [] };
      { name = "masc_messages"; description = ""; input_schema = `Assoc [] };
      { name = "keeper_time_now"; description = ""; input_schema = `Assoc [] };
    ]
  in
  KET.inject_masc_schemas schemas;
  (* Full tier to verify storage — allowlist all 3 *)
  let meta = make_meta
    ~tool_allowlist:["masc_status"; "masc_broadcast"; "masc_messages"] () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "3 masc tools" 3 (List.length names);
  Alcotest.(check bool) "no keeper_time_now" false
    (List.mem "keeper_time_now" names)

(** Default: empty allowlist = unrestricted masc_* exposure. *)
let test_default_unrestricted () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_governance_status" true
    (List.mem "masc_governance_status" names);
  Alcotest.(check bool) "has masc_autoresearch_cycle" true
    (List.mem "masc_autoresearch_cycle" names)

(** Default: allowed_tool_names also exposes shard-sourced masc_* tools. *)
let test_default_exposes_shard_masc () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta () in
  let names = KET.keeper_allowed_tool_names meta in
  (* keeper_* should pass *)
  Alcotest.(check bool) "has keeper_time_now" true
    (List.mem "keeper_time_now" names);
  Alcotest.(check bool) "has keeper_board_post" true
    (List.mem "keeper_board_post" names);
  (* masc_* should also be available when no allowlist restriction is set *)
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_governance_status" true
    (List.mem "masc_governance_status" names);
  Alcotest.(check bool) "has masc_autoresearch_cycle" true
    (List.mem "masc_autoresearch_cycle" names)

(** Allowlist opens specific tools. *)
let test_allowlist_opens_tools () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta
    ~tool_allowlist:["masc_status"; "masc_broadcast"; "masc_join"] () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "3 allowed" 3 (List.length names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_broadcast" true (List.mem "masc_broadcast" names);
  Alcotest.(check bool) "has masc_join" true (List.mem "masc_join" names);
  Alcotest.(check bool) "no masc_board_post" false (List.mem "masc_board_post" names)

(** Denylist overrides allowlist. *)
let test_deny_overrides_allow () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta
    ~tool_allowlist:["masc_status"; "masc_broadcast"; "masc_join"]
    ~tool_denylist:["masc_broadcast"] () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "2 after deny" 2 (List.length names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "no masc_broadcast (denied)" false
    (List.mem "masc_broadcast" names)

(** Denylist also restricts the unrestricted empty-allowlist path. *)
let test_denylist_restricts_unrestricted_default () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta
    ~tool_denylist:["masc_status"; "masc_governance_status"] () in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "no masc_status (denied)" false
    (List.mem "masc_status" names);
  Alcotest.(check bool) "no masc_governance_status (denied)" false
    (List.mem "masc_governance_status" names);
  Alcotest.(check bool) "other masc tools remain" true
    (List.mem "masc_autoresearch_cycle" names)

(** Explicit empty allowlist is restricted, not unrestricted. *)
let test_restricted_empty_allowlist_blocks_masc () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta
    ~tool_access:(Masc_mcp.Keeper_types.Restricted []) () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "no masc tools" 0 (List.length names);
  Alcotest.(check bool) "masc_status blocked" false
    (List.mem "masc_status" names)

(** Legacy persisted empty tool_allowlist still maps to unrestricted. *)
let test_legacy_empty_allowlist_remains_unrestricted () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta =
    match Masc_mcp.Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String "legacy-keeper");
          ("agent_name", `String "legacy-keeper");
          ("trace_id", `String "legacy-trace");
          ("tool_allowlist", `List []);
        ])
    with
    | Ok meta -> meta
    | Error e -> failwith e
  in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check bool) "legacy empty allowlist still exposes masc tools" true
    (List.mem "masc_status" names)

(** Restricted JSON preserves an explicit empty tools list. *)
let test_tool_access_restricted_empty_json_preserved () =
  let meta =
    match Masc_mcp.Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String "restricted-json");
          ("agent_name", `String "restricted-json");
          ("trace_id", `String "restricted-json-trace");
          ( "tool_access",
            `Assoc
              [
                ("kind", `String "restricted");
                ("tools", `List []);
              ] );
        ])
    with
    | Ok meta -> meta
    | Error e -> failwith e
  in
  match meta.Masc_mcp.Keeper_types.tool_access with
  | Masc_mcp.Keeper_types.Restricted names ->
      Alcotest.(check int) "restricted empty preserved" 0 (List.length names)
  | Masc_mcp.Keeper_types.Unrestricted ->
      Alcotest.fail "expected Restricted []"

(** Malformed tool_access JSON is rejected. *)
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
        "invalid keeper tool_access.kind: bogus"
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
        "keeper tool_access.kind required"
        e

(** Allowlist also gates shard-sourced masc_* in allowed_tool_names. *)
let test_allowlist_gates_shard_tools () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta
    ~tool_allowlist:["masc_status"; "masc_governance_status"] () in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_governance_status" true
    (List.mem "masc_governance_status" names);
  (* Not in allowlist — blocked even though shard provides it *)
  Alcotest.(check bool) "no masc_cases" false (List.mem "masc_cases" names);
  Alcotest.(check bool) "no masc_autoresearch_cycle" false
    (List.mem "masc_autoresearch_cycle" names)

(** Verify dispatch passthrough returns None for unregistered tools. *)
let test_dispatch_unregistered () =
  let result =
    Masc_mcp.Tool_dispatch.dispatch ~name:"masc_nonexistent_xyz" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "unregistered returns None" true (result = None)

(** Verify schemas and names are consistent. *)
let test_schemas_match_names () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta
    ~tool_allowlist:["masc_status"; "masc_join"; "masc_broadcast"] () in
  let names = KET.keeper_masc_tool_names meta in
  let schemas = KET.keeper_masc_tool_schemas meta in
  Alcotest.(check int) "count matches"
    (List.length names) (List.length schemas);
  List.iter
    (fun (s : Types.tool_schema) ->
      Alcotest.(check bool) (s.name ^ " in names") true
        (List.mem s.name names))
    schemas

let () =
  Alcotest.run "Keeper masc bridge"
    [
      ( "injection",
        [
          Alcotest.test_case "stores all masc_* schemas" `Quick
            test_inject_stores_all_masc;
        ] );
      ( "unrestricted_by_default",
        [
          Alcotest.test_case "empty allowlist exposes masc tools" `Quick
            test_default_unrestricted;
          Alcotest.test_case "exposes shard-sourced masc_*" `Quick
            test_default_exposes_shard_masc;
        ] );
      ( "allowlist",
        [
          Alcotest.test_case "opens specific tools" `Quick
            test_allowlist_opens_tools;
          Alcotest.test_case "gates shard tools too" `Quick
            test_allowlist_gates_shard_tools;
        ] );
      ( "denylist",
        [
          Alcotest.test_case "deny overrides allow" `Quick
            test_deny_overrides_allow;
          Alcotest.test_case "deny restricts unrestricted default" `Quick
            test_denylist_restricts_unrestricted_default;
          Alcotest.test_case "restricted empty allowlist blocks masc" `Quick
            test_restricted_empty_allowlist_blocks_masc;
        ] );
      ( "meta_json",
        [
          Alcotest.test_case "legacy empty allowlist remains unrestricted" `Quick
            test_legacy_empty_allowlist_remains_unrestricted;
          Alcotest.test_case "restricted empty json preserved" `Quick
            test_tool_access_restricted_empty_json_preserved;
          Alcotest.test_case "invalid kind rejected" `Quick
            test_tool_access_invalid_kind_rejected;
          Alcotest.test_case "missing kind rejected" `Quick
            test_tool_access_missing_kind_rejected;
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
    ]
