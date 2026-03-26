(** Coverage tests for Tool_agent — Agent management and selection

    Tests dispatch routing, handler execution, helper functions, and
    selection strategies for 11 tools: masc_agents, masc_register_capabilities,
    masc_agent_update, masc_find_by_capability, masc_get_metrics,
    masc_agent_fitness, masc_select_agent, masc_collaboration_graph,
    masc_consolidate_learning, masc_agent_card, masc_agent_relations
*)
module Tool_args = Masc_mcp.Tool_args

module Tool_agent = Masc_mcp.Tool_agent
module Room = Masc_mcp.Room

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file
    (Printf.sprintf "test_agent_%d_" !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let make_ctx () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_agent.context = { config; agent_name = "test-agent" } in
  (ctx, base_dir)

let dispatch_exn ctx ~name ~args =
  match Tool_agent.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_agent.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None);
  cleanup_dir base_dir

let test_dispatch_agents () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_agent.dispatch ctx ~name:"masc_agents" ~args:(`Assoc []) in
  Alcotest.(check bool) "agents dispatches" true (result <> None);
  cleanup_dir base_dir

let test_dispatch_register_capabilities () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_agent.dispatch ctx ~name:"masc_register_capabilities" ~args:(`Assoc []) in
  Alcotest.(check bool) "register_capabilities dispatches" true (result <> None);
  cleanup_dir base_dir

let test_dispatch_agent_update () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_agent.dispatch ctx ~name:"masc_agent_update" ~args:(`Assoc []) in
  Alcotest.(check bool) "agent_update dispatches" true (result <> None);
  cleanup_dir base_dir

let test_dispatch_select_agent () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_agent.dispatch ctx ~name:"masc_select_agent" ~args:(`Assoc []) in
  Alcotest.(check bool) "select_agent dispatches" true (result <> None);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — masc_agents
   ============================================================ *)

let test_handle_agents () =
  let ctx, base_dir = make_ctx () in
  let (ok, msg) = Tool_agent.handle_agents ctx (`Assoc []) in
  Alcotest.(check bool) "agents succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — register_capabilities
   ============================================================ *)

let test_register_capabilities () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("capabilities", `List [`String "test"; `String "code"])] in
  let (ok, _msg) = Tool_agent.handle_register_capabilities ctx args in
  Alcotest.(check bool) "registers capabilities" true ok;
  cleanup_dir base_dir

(* ============================================================
   Handler tests — agent_update
   ============================================================ *)

let test_agent_update_status () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("status", `String "busy")] in
  let (_ok, msg) = Tool_agent.handle_agent_update ctx args in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_agent_update_capabilities () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("capabilities", `List [`String "review"; `String "refactor"])] in
  let (_ok, msg) = Tool_agent.handle_agent_update ctx args in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — find_by_capability
   ============================================================ *)

let test_find_by_capability () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("capability", `String "test")] in
  let (ok, msg) = Tool_agent.handle_find_by_capability ctx args in
  Alcotest.(check bool) "find succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — get_metrics
   ============================================================ *)

let test_get_metrics_no_data () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("agent_name", `String "nonexistent"); ("days", `Int 7)] in
  let (_ok, msg) = dispatch_exn ctx ~name:"masc_get_metrics" ~args in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — agent_fitness
   ============================================================ *)

let test_agent_fitness_no_agents () =
  let ctx, base_dir = make_ctx () in
  let (ok, msg) = Tool_agent.handle_agent_fitness ctx (`Assoc []) in
  Alcotest.(check bool) "fitness succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_agent_fitness_specific () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("agent_name", `String "test-agent"); ("days", `Int 7)] in
  let (ok, msg) = Tool_agent.handle_agent_fitness ctx args in
  Alcotest.(check bool) "fitness with agent" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — select_agent (3 strategies)
   ============================================================ *)

let test_select_agent_missing_agents () =
  let ctx, base_dir = make_ctx () in
  let (ok, _msg) = Tool_agent.handle_select_agent ctx (`Assoc []) in
  Alcotest.(check bool) "missing agents fails" false ok;
  cleanup_dir base_dir

let test_select_agent_capability_first () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("available_agents", `List [`String "agent-a"; `String "agent-b"]);
    ("strategy", `String "capability_first");
    ("days", `Int 7);
  ] in
  let (ok, msg) = Tool_agent.handle_select_agent ctx args in
  Alcotest.(check bool) "capability_first succeeds" true ok;
  Alcotest.(check bool) "returns JSON" true (String.contains msg '{');
  cleanup_dir base_dir

let test_select_agent_random () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("available_agents", `List [`String "agent-x"; `String "agent-y"]);
    ("strategy", `String "random");
  ] in
  let (ok, _msg) = Tool_agent.handle_select_agent ctx args in
  Alcotest.(check bool) "random succeeds" true ok;
  cleanup_dir base_dir

let test_select_agent_roulette () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("available_agents", `List [`String "a-1"; `String "a-2"; `String "a-3"]);
    ("strategy", `String "roulette_wheel");
  ] in
  let (ok, _msg) = Tool_agent.handle_select_agent ctx args in
  Alcotest.(check bool) "roulette succeeds" true ok;
  cleanup_dir base_dir

(* ============================================================
   Handler tests — collaboration_graph
   ============================================================ *)

let test_collaboration_graph_text () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("format", `String "text")] in
  let (ok, msg) = Tool_agent.handle_collaboration_graph ctx args in
  Alcotest.(check bool) "text format succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_collaboration_graph_json () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("format", `String "json")] in
  let (ok, msg) = Tool_agent.handle_collaboration_graph ctx args in
  Alcotest.(check bool) "json format succeeds" true ok;
  Alcotest.(check bool) "returns JSON" true (String.contains msg '{');
  cleanup_dir base_dir

(* ============================================================
   Handler tests — consolidate_learning
   ============================================================ *)

let test_consolidate_learning () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("decay_after_days", `Int 30)] in
  let (ok, msg) = Tool_agent.handle_consolidate_learning ctx args in
  Alcotest.(check bool) "consolidate succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — agent_card
   ============================================================ *)

let test_agent_card_get () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("action", `String "get")] in
  let (ok, msg) = Tool_agent.handle_agent_card ctx args in
  Alcotest.(check bool) "get succeeds" true ok;
  Alcotest.(check bool) "returns JSON" true (String.contains msg '{');
  cleanup_dir base_dir

let test_agent_card_refresh () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("action", `String "refresh")] in
  let (ok, msg) = Tool_agent.handle_agent_card ctx args in
  Alcotest.(check bool) "refresh succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Dispatch test — masc_agent_relations
   ============================================================ *)

let test_dispatch_agent_relations () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_agent.dispatch ctx ~name:"masc_agent_relations" ~args:(`Assoc []) in
  Alcotest.(check bool) "agent_relations dispatches" true (result <> None);
  cleanup_dir base_dir

(* ============================================================
   Schema coverage — masc_agent_relations is registered
   ============================================================ *)

let test_schema_agent_relations_present () =
  let schemas = Tool_agent.schemas in
  let has_it = List.exists (fun (s : Types.tool_schema) ->
    s.name = "masc_agent_relations") schemas in
  Alcotest.(check bool) "schema registered" true has_it

(* ============================================================
   Helper function tests
   ============================================================ *)

let test_get_string_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check string) "extracts string" "value"
    (Tool_args.get_string args "key" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  Alcotest.(check string) "uses default" "default"
    (Tool_args.get_string args "key" "default")

let test_get_string_opt_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check (option string)) "extracts Some" (Some "value")
    (Tool_args.get_string_opt args "key")

let test_get_string_opt_missing () =
  let args = `Assoc [] in
  Alcotest.(check (option string)) "returns None" None
    (Tool_args.get_string_opt args "key")

let test_get_int_present () =
  let args = `Assoc [("key", `Int 42)] in
  Alcotest.(check int) "extracts int" 42
    (Tool_args.get_int args "key" 0)

let test_get_int_missing () =
  let args = `Assoc [] in
  Alcotest.(check int) "uses default" 99
    (Tool_args.get_int args "key" 99)

let test_get_string_list_present () =
  let args = `Assoc [("key", `List [`String "a"; `String "b"])] in
  Alcotest.(check (list string)) "extracts list" ["a"; "b"]
    (Tool_args.get_string_list args "key")

let test_get_string_list_missing () =
  let args = `Assoc [] in
  Alcotest.(check (list string)) "empty list" []
    (Tool_args.get_string_list args "key")

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_agent" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown;
      Alcotest.test_case "agents dispatches" `Quick test_dispatch_agents;
      Alcotest.test_case "register_capabilities dispatches" `Quick test_dispatch_register_capabilities;
      Alcotest.test_case "agent_update dispatches" `Quick test_dispatch_agent_update;
      Alcotest.test_case "select_agent dispatches" `Quick test_dispatch_select_agent;
    ]);
    ("agents", [
      Alcotest.test_case "handle_agents" `Quick test_handle_agents;
    ]);
    ("register_capabilities", [
      Alcotest.test_case "with capabilities" `Quick test_register_capabilities;
    ]);
    ("agent_update", [
      Alcotest.test_case "status update" `Quick test_agent_update_status;
      Alcotest.test_case "capabilities update" `Quick test_agent_update_capabilities;
    ]);
    ("find_by_capability", [
      Alcotest.test_case "find capability" `Quick test_find_by_capability;
    ]);
    ("get_metrics", [
      Alcotest.test_case "no data" `Quick test_get_metrics_no_data;
    ]);
    ("agent_fitness", [
      Alcotest.test_case "no agents" `Quick test_agent_fitness_no_agents;
      Alcotest.test_case "specific agent" `Quick test_agent_fitness_specific;
    ]);
    ("select_agent", [
      Alcotest.test_case "missing agents" `Quick test_select_agent_missing_agents;
      Alcotest.test_case "capability_first" `Quick test_select_agent_capability_first;
      Alcotest.test_case "random" `Quick test_select_agent_random;
      Alcotest.test_case "roulette_wheel" `Quick test_select_agent_roulette;
    ]);
    ("collaboration_graph", [
      Alcotest.test_case "text format" `Quick test_collaboration_graph_text;
      Alcotest.test_case "json format" `Quick test_collaboration_graph_json;
    ]);
    ("consolidate_learning", [
      Alcotest.test_case "with decay" `Quick test_consolidate_learning;
    ]);
    ("agent_card", [
      Alcotest.test_case "get action" `Quick test_agent_card_get;
      Alcotest.test_case "refresh action" `Quick test_agent_card_refresh;
    ]);
    ("agent_relations", [
      Alcotest.test_case "dispatches" `Quick test_dispatch_agent_relations;
      Alcotest.test_case "schema present" `Quick test_schema_agent_relations_present;
    ]);
    ("helpers", [
      Alcotest.test_case "get_string present" `Quick test_get_string_present;
      Alcotest.test_case "get_string missing" `Quick test_get_string_missing;
      Alcotest.test_case "get_string_opt present" `Quick test_get_string_opt_present;
      Alcotest.test_case "get_string_opt missing" `Quick test_get_string_opt_missing;
      Alcotest.test_case "get_int present" `Quick test_get_int_present;
      Alcotest.test_case "get_int missing" `Quick test_get_int_missing;
      Alcotest.test_case "get_string_list present" `Quick test_get_string_list_present;
      Alcotest.test_case "get_string_list missing" `Quick test_get_string_list_missing;
    ]);
  ]
