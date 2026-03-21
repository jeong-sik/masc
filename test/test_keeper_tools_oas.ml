(** Tests for Keeper_tools_oas — OAS Tool.t wrapping of keeper tools. *)

open Alcotest
open Masc_mcp

let make_test_meta ?(name = "test-keeper") () : Keeper_types.keeper_meta =
  match Keeper_types.meta_of_json
    (`Assoc [("name", `String name); ("agent_name", `String name);
             ("trace_id", `String "test-trace-001")]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_test_meta failed: %s" e)

let make_test_ctx () =
  Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000

let test_make_tools_returns_nonempty () =
  let meta = make_test_meta () in
  let ctx_ref = ref (make_test_ctx ()) in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref in
      check bool "tools nonempty" true (List.length tools > 0))

let test_tools_have_valid_schemas () =
  let meta = make_test_meta () in
  let ctx_ref = ref (make_test_ctx ()) in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_schema_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref in
      List.iter (fun (tool : Agent_sdk.Tool.t) ->
        check bool (Printf.sprintf "tool %s has name" tool.schema.name)
          true (String.length tool.schema.name > 0);
        check bool (Printf.sprintf "tool %s has description" tool.schema.name)
          true (String.length tool.schema.description > 0)
      ) tools)

let test_tool_count_matches_allowed () =
  let meta = make_test_meta () in
  let ctx_ref = ref (make_test_ctx ()) in
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tools_count_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir |> Array.iter (fun f ->
        Sys.remove (Filename.concat dir f));
        Unix.rmdir dir with _ -> ()))
    (fun () ->
      let config = Room.default_config dir in
      let tools = Keeper_tools_oas.make_tools ~config ~meta ~ctx_ref in
      let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
      let tool_names = List.map (fun (t : Agent_sdk.Tool.t) -> t.schema.name) tools in
      check bool "all tools are in allowed list" true
        (List.for_all (fun name -> List.mem name allowed) tool_names))

let make_research_meta () : Keeper_types.keeper_meta =
  match Keeper_types.meta_of_json
    (`Assoc [("name", `String "test-researcher");
             ("agent_name", `String "test-researcher");
             ("trace_id", `String "test-trace-research");
             ("soul_profile", `String "research")]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_research_meta failed: %s" e)

let test_research_keeper_has_autoresearch_tools () =
  let meta = make_research_meta () in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_cycle = List.mem "masc_autoresearch_cycle" allowed in
  let has_start = List.mem "masc_autoresearch_start" allowed in
  let has_status = List.mem "masc_autoresearch_status" allowed in
  check bool "has cycle" true has_cycle;
  check bool "has start" true has_start;
  check bool "has status" true has_status

let test_non_research_keeper_no_autoresearch () =
  let meta = make_test_meta () in
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let has_any = List.exists (fun n ->
    String.length n > 18
    && String.sub n 0 18 = "masc_autoresearch_") allowed in
  check bool "no autoresearch tools" false has_any

let test_research_model_tools_include_autoresearch () =
  let meta = make_research_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_model_tools meta in
  let has_cycle = List.exists (fun (t : Types.tool_schema) ->
    t.name = "masc_autoresearch_cycle") tools in
  check bool "model tools have cycle" true has_cycle

let () =
  run "Keeper_tools_oas" [
    "make_tools", [
      test_case "returns nonempty" `Quick test_make_tools_returns_nonempty;
      test_case "valid schemas" `Quick test_tools_have_valid_schemas;
      test_case "count matches allowed" `Quick test_tool_count_matches_allowed;
    ];
    "research_profile", [
      test_case "has autoresearch tools" `Quick test_research_keeper_has_autoresearch_tools;
      test_case "non-research has none" `Quick test_non_research_keeper_no_autoresearch;
      test_case "model tools include autoresearch" `Quick test_research_model_tools_include_autoresearch;
    ];
  ]
