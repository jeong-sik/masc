(** Test keeper masc_* tool bridge — verifies schema injection
    and dispatch passthrough expose all masc_* tools to keeper.
    No Mode filtering — all masc_* tools are exposed. *)

module KET = Masc_mcp.Keeper_exec_tools

(** Verify inject_masc_schemas filters to masc_* only. *)
let test_inject_filters_prefix () =
  let schemas : Types.tool_schema list = [
    { name = "masc_join"; description = ""; input_schema = `Assoc [] };
    { name = "masc_broadcast"; description = ""; input_schema = `Assoc [] };
    { name = "keeper_time_now"; description = ""; input_schema = `Assoc [] };
  ] in
  KET.inject_masc_schemas schemas;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  Alcotest.(check int) "2 masc tools (keeper_ filtered)" 2 (List.length names);
  Alcotest.(check bool) "has masc_join" true (List.mem "masc_join" names);
  Alcotest.(check bool) "no keeper_time_now" false (List.mem "keeper_time_now" names)

(** Verify dispatch passthrough returns None for unregistered tools. *)
let test_dispatch_unregistered () =
  let result = Masc_mcp.Tool_dispatch.dispatch
    ~name:"masc_nonexistent_xyz" ~args:(`Assoc []) in
  Alcotest.(check bool) "unregistered returns None" true (result = None)

(** Verify real schemas injection produces 200+ masc tools. *)
let test_inject_real_schemas_count () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  Printf.printf "  keeper sees %d masc_* tools\n" (List.length names);
  Alcotest.(check bool) "at least 200 masc tools" true (List.length names >= 200)

(** Verify schemas and names are consistent. *)
let test_schemas_match_names () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  let schemas = KET.keeper_masc_tool_schemas dummy_meta in
  Alcotest.(check int) "count matches"
    (List.length names) (List.length schemas);
  List.iter (fun (s : Types.tool_schema) ->
    Alcotest.(check bool) (s.name ^ " in names") true
      (List.mem s.name names)) schemas

(** Verify all tools have masc_ prefix. *)
let test_all_have_prefix () =
  KET.inject_masc_schemas Masc_mcp.Tools.all_schemas_extended;
  let dummy_meta = Obj.magic () in
  let names = KET.keeper_masc_tool_names dummy_meta in
  List.iter (fun name ->
    Alcotest.(check bool) (name ^ " has masc_ prefix") true
      (String.starts_with ~prefix:"masc_" name)) names

let () =
  Alcotest.run "Keeper masc bridge" [
    ("injection", [
      Alcotest.test_case "filters to masc_ prefix" `Quick test_inject_filters_prefix;
      Alcotest.test_case "real schemas 200+" `Quick test_inject_real_schemas_count;
    ]);
    ("dispatch", [
      Alcotest.test_case "unregistered returns None" `Quick test_dispatch_unregistered;
    ]);
    ("consistency", [
      Alcotest.test_case "schemas match names" `Quick test_schemas_match_names;
      Alcotest.test_case "all have masc_ prefix" `Quick test_all_have_prefix;
    ]);
  ]
