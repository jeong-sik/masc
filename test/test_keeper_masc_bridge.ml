(** Test keeper masc_* tool bridge — verifies schema injection
    and dispatch passthrough expose only the curated keeper bridge. *)

module KET = Masc_mcp.Keeper_exec_tools

let make_meta ?(policy_mode = "learned_offline_v1") () =
  match Masc_mcp.Keeper_types.meta_of_json
    (`Assoc
      [
        ("name", `String "keeper-bridge-test");
        ("agent_name", `String "keeper-bridge-test");
        ("trace_id", `String "keeper-bridge-trace");
        ("policy_mode", `String policy_mode);
      ])
  with
  | Ok meta -> meta
  | Error e -> failwith e

(** Verify inject_masc_schemas filters to the curated keeper allowlist. *)
let test_inject_filters_allowlist () =
  let schemas : Types.tool_schema list =
    [
      { name = "masc_status"; description = ""; input_schema = `Assoc []; visibility = Public };
      { name = "masc_broadcast"; description = ""; input_schema = `Assoc []; visibility = Public };
      { name = "masc_messages"; description = ""; input_schema = `Assoc []; visibility = Public };
      { name = "keeper_time_now"; description = ""; input_schema = `Assoc []; visibility = Public };
    ]
  in
  KET.inject_masc_schemas schemas;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  Alcotest.(check int) "2 curated masc tools" 2 (List.length names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_messages" true (List.mem "masc_messages" names);
  Alcotest.(check bool) "no masc_broadcast" false (List.mem "masc_broadcast" names);
  Alcotest.(check bool) "no keeper_time_now" false
    (List.mem "keeper_time_now" names)

(** Verify dispatch passthrough returns None for unregistered tools. *)
let test_dispatch_unregistered () =
  let result =
    Masc_mcp.Tool_dispatch.dispatch ~name:"masc_nonexistent_xyz" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "unregistered returns None" true (result = None)

(** Verify real schemas injection matches the curated keeper allowlist. *)
let test_inject_real_schemas_match_curated_names () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  let expected =
    List.sort String.compare KET.keeper_passthrough_masc_tool_names
  in
  let actual = List.sort String.compare names in
  Alcotest.(check (list string)) "curated passthrough names" expected actual

(** Verify schemas and names are consistent. *)
let test_schemas_match_names () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  let schemas = KET.keeper_masc_tool_schemas dummy_meta in
  Alcotest.(check int) "count matches"
    (List.length names) (List.length schemas);
  List.iter
    (fun (s : Types.tool_schema) ->
      Alcotest.(check bool) (s.name ^ " in names") true
        (List.mem s.name names))
    schemas

(** Verify all bridged tools still have masc_ prefix. *)
let test_all_have_prefix () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " has masc_ prefix") true
        (String.starts_with ~prefix:"masc_" name))
    names

let test_allowed_tools_use_curated_bridge () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  let meta = make_meta () in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "has masc_messages" true (List.mem "masc_messages" names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "omits masc_join" false (List.mem "masc_join" names);
  Alcotest.(check bool) "omits masc_broadcast" false
    (List.mem "masc_broadcast" names)

let () =
  Alcotest.run "Keeper masc bridge"
    [
      ( "injection",
        [
          Alcotest.test_case "filters to curated allowlist" `Quick
            test_inject_filters_allowlist;
          Alcotest.test_case "real schemas match curated list" `Quick
            test_inject_real_schemas_match_curated_names;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "unregistered returns None" `Quick
            test_dispatch_unregistered;
        ] );
      ( "consistency",
        [
          Alcotest.test_case "schemas match names" `Quick test_schemas_match_names;
          Alcotest.test_case "all have masc_ prefix" `Quick test_all_have_prefix;
          Alcotest.test_case "allowed tools use curated bridge" `Quick
            test_allowed_tools_use_curated_bridge;
        ] );
    ]
