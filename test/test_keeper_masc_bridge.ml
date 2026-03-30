(** Test keeper masc_* tool bridge — verifies tier-based schema injection
    and dispatch passthrough for keeper tool exposure. *)

module KET = Masc_mcp.Keeper_exec_tools

let make_meta ?(tool_tier = "essential") ?(extra_masc_tools = []) () =
  match Masc_mcp.Keeper_types.meta_of_json
    (`Assoc
      [
        ("name", `String "keeper-bridge-test");
        ("agent_name", `String "keeper-bridge-test");
        ("trace_id", `String "keeper-bridge-trace");
        ("tool_tier", `String tool_tier);
        ("extra_masc_tools", `List (List.map (fun s -> `String s) extra_masc_tools));
      ])
  with
  | Ok meta -> meta
  | Error e -> failwith e

(** Verify inject_masc_schemas stores all masc_* schemas (no name-based filter). *)
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
  (* inject stores all 3 masc_* tools, not the keeper_* one *)
  let meta = make_meta ~tool_tier:"full" () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check int) "3 masc tools stored" 3 (List.length names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_broadcast" true (List.mem "masc_broadcast" names);
  Alcotest.(check bool) "has masc_messages" true (List.mem "masc_messages" names);
  Alcotest.(check bool) "no keeper_time_now" false
    (List.mem "keeper_time_now" names)

(** Verify Essential tier includes expected tools and excludes non-essential. *)
let test_essential_tier_filters () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta ~tool_tier:"essential" () in
  let names = KET.keeper_masc_tool_names meta in
  (* Essential tier should include core coordination tools *)
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_join" true (List.mem "masc_join" names);
  Alcotest.(check bool) "has masc_broadcast" true (List.mem "masc_broadcast" names);
  Alcotest.(check bool) "has masc_claim_next" true (List.mem "masc_claim_next" names);
  Alcotest.(check bool) "has masc_transition" true (List.mem "masc_transition" names);
  Alcotest.(check bool) "has masc_heartbeat" true (List.mem "masc_heartbeat" names);
  (* Board tools should NOT be in Essential *)
  Alcotest.(check bool) "no masc_board_post" false (List.mem "masc_board_post" names)

(** Verify Standard tier includes board tools. *)
let test_standard_tier_includes_board () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta ~tool_tier:"standard" () in
  let names = KET.keeper_masc_tool_names meta in
  Alcotest.(check bool) "has masc_board_post" true (List.mem "masc_board_post" names);
  Alcotest.(check bool) "has masc_team_session_start" true
    (List.mem "masc_team_session_start" names);
  (* Essential tools should also be present in Standard *)
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names)

(** Verify extra_masc_tools adds tools beyond the tier. *)
let test_extra_tools_override () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta ~tool_tier:"essential" ~extra_masc_tools:["masc_board_post"] () in
  let names = KET.keeper_masc_tool_names meta in
  (* masc_board_post is NOT in Essential but IS in extra_masc_tools *)
  Alcotest.(check bool) "extra: has masc_board_post" true
    (List.mem "masc_board_post" names);
  (* Normal essential tools still present *)
  Alcotest.(check bool) "extra: has masc_status" true (List.mem "masc_status" names)

(** Verify Full tier returns all stored schemas. *)
let test_full_tier_includes_all () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta_full = make_meta ~tool_tier:"full" () in
  let meta_essential = make_meta ~tool_tier:"essential" () in
  let full_count = List.length (KET.keeper_masc_tool_names meta_full) in
  let essential_count = List.length (KET.keeper_masc_tool_names meta_essential) in
  Alcotest.(check bool) "full > essential" true (full_count > essential_count)

(** Verify dispatch passthrough returns None for unregistered tools. *)
let test_dispatch_unregistered () =
  let result =
    Masc_mcp.Tool_dispatch.dispatch ~name:"masc_nonexistent_xyz" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "unregistered returns None" true (result = None)

(** Verify schemas and names are consistent. *)
let test_schemas_match_names () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta () in
  let names = KET.keeper_masc_tool_names meta in
  let schemas = KET.keeper_masc_tool_schemas meta in
  Alcotest.(check int) "count matches"
    (List.length names) (List.length schemas);
  List.iter
    (fun (s : Types.tool_schema) ->
      Alcotest.(check bool) (s.name ^ " in names") true
        (List.mem s.name names))
    schemas

(** Verify all bridged tools still have masc_ prefix. *)
let test_all_have_prefix () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta () in
  let names = KET.keeper_masc_tool_names meta in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " has masc_ prefix") true
        (String.starts_with ~prefix:"masc_" name))
    names

(** Verify allowed tools include essential masc_* tools by default. *)
let test_allowed_tools_include_essential () =
  KET.inject_masc_schemas Masc_mcp.Config.raw_all_tool_schemas;
  let meta = make_meta () in
  let names = KET.keeper_allowed_tool_names meta in
  Alcotest.(check bool) "has masc_messages" true (List.mem "masc_messages" names);
  Alcotest.(check bool) "has masc_status" true (List.mem "masc_status" names);
  Alcotest.(check bool) "has masc_join" true (List.mem "masc_join" names);
  Alcotest.(check bool) "has masc_broadcast" true (List.mem "masc_broadcast" names)

let () =
  Alcotest.run "Keeper masc bridge"
    [
      ( "injection",
        [
          Alcotest.test_case "stores all masc_* schemas" `Quick
            test_inject_stores_all_masc;
          Alcotest.test_case "essential tier filters correctly" `Quick
            test_essential_tier_filters;
        ] );
      ( "tiers",
        [
          Alcotest.test_case "standard includes board" `Quick
            test_standard_tier_includes_board;
          Alcotest.test_case "extra_tools override" `Quick
            test_extra_tools_override;
          Alcotest.test_case "full includes all" `Quick
            test_full_tier_includes_all;
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
          Alcotest.test_case "allowed tools include essential" `Quick
            test_allowed_tools_include_essential;
        ] );
    ]
