(** Coverage tests for Tool_agent — Agent management and fitness

    Tests dispatch routing, handler execution, helper functions for:
    masc_agents, masc_agent_update, masc_get_metrics, masc_agent_fitness,
    retired masc_collaboration_graph absence, masc_agent_card
*)
module Tool_args = Tool_args
module Tool_result = Tool_result
module Tool_agent = Masc.Tool_agent
module Metrics_store_eio = Masc.Metrics_store_eio
module Workspace = Masc.Workspace

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

let with_ctx f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Workspace.default_config base_dir in
  ignore (Workspace.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_agent.context = { config; agent_name = "test-agent" } in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () -> f ctx)

let dispatch_exn ctx ~name ~args =
  match Tool_agent.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  with_ctx (fun ctx ->
  let result = Tool_agent.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None);
  )

let test_dispatch_agents_removed () =
  with_ctx (fun ctx ->
  (* masc_agents removed (2026-06-09): dead agent-status surface. *)
  let result = Tool_agent.dispatch ctx ~name:"masc_agents" ~args:(`Assoc []) in
  Alcotest.(check bool) "agents removed" true (result = None);
  )

let test_dispatch_register_capabilities_removed () =
  with_ctx (fun ctx ->
  let result = Tool_agent.dispatch ctx ~name:"masc_register_capabilities" ~args:(`Assoc []) in
  Alcotest.(check bool) "register_capabilities removed" true (result = None);
  )

let test_dispatch_collaboration_graph_removed () =
  with_ctx (fun ctx ->
  let result = Tool_agent.dispatch ctx ~name:"masc_collaboration_graph" ~args:(`Assoc []) in
  Alcotest.(check bool) "collaboration graph removed" true (result = None);
  )

let test_dispatch_agent_update_removed () =
  with_ctx (fun ctx ->
  (* masc_agent_update removed (2026-06-09): dead agent-status surface. *)
  let result = Tool_agent.dispatch ctx ~name:"masc_agent_update" ~args:(`Assoc []) in
  Alcotest.(check bool) "agent_update removed" true (result = None);
  )

let test_dispatch_agent_card () =
  with_ctx (fun ctx ->
  let result = Tool_agent.dispatch ctx ~name:"masc_agent_card" ~args:(`Assoc []) in
  Alcotest.(check bool) "agent_card dispatches" true (result <> None);
  )


(* test_handle_agents removed (2026-06-09): handle_agents deleted with the
   dead agent-status surface. *)

let test_handle_agent_card () =
  with_ctx (fun ctx ->
  let result = Tool_agent.handle_agent_card ctx (`Assoc []) in
  Alcotest.(check bool) "agent card succeeds" true (Tool_result.is_success result);
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "card name" "MASC"
    (json |> member "name" |> to_string);
  Alcotest.(check string) "card schema" "masc.agent_card.v1"
    (json |> member "schema" |> to_string);
  )

let test_handle_agent_card_rejects_unknown_action () =
  with_ctx (fun ctx ->
  let result =
    Tool_agent.handle_agent_card ctx (`Assoc [("action", `String "bogus")])
  in
  Alcotest.(check bool) "agent card rejects" false (Tool_result.is_success result);
  Alcotest.(check bool) "mentions invalid action" true
    (String.contains (Tool_result.message result) 'b');
  )

(* agent_update handler tests removed (2026-06-09): handle_agent_update deleted
   with the dead agent-status surface. *)

(* ============================================================
   Handler tests — get_metrics
   ============================================================ *)

let test_get_metrics_no_data () =
  with_ctx (fun ctx ->
  let args = `Assoc [("agent_name", `String "nonexistent"); ("days", `Int 7)] in
  let result = dispatch_exn ctx ~name:"masc_get_metrics" ~args in
  Alcotest.(check bool) "no data fails" false (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  Alcotest.(check string) "error_code" "not_found"
    (json |> member "error_code" |> to_string);
  Alcotest.(check string) "message" "no metrics found for agent: nonexistent"
    (json |> member "message" |> to_string);
  )

let test_get_metrics_missing_agent_name () =
  with_ctx (fun ctx ->
  let result = dispatch_exn ctx ~name:"masc_get_metrics" ~args:(`Assoc []) in
  Alcotest.(check bool) "missing agent_name fails" false (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  Alcotest.(check string) "status" "error"
    (json |> member "status" |> to_string);
  Alcotest.(check string) "message" "agent_name is required"
    (json |> member "message" |> to_string);
  )

let record_completed_metric config ~agent_id ~task_id =
  let metric = Metrics_store_eio.create_metric ~agent_id ~task_id () in
  let completed = Metrics_store_eio.complete_metric metric ~success:true () in
  Metrics_store_eio.record config completed;
  Metrics_store_eio.flush_pending ()

let test_get_metrics_resolves_keeper_agent_alias () =
  with_ctx (fun ctx ->
  record_completed_metric ctx.config
    ~agent_id:"nick0cave"
    ~task_id:"task-alias-metric";
  let args =
    `Assoc
      [ ("agent_name", `String "keeper-nick0cave-agent")
      ; ("days", `Int 7)
      ]
  in
  let result = dispatch_exn ctx ~name:"masc_get_metrics" ~args in
  Alcotest.(check bool) "alias metrics succeeds" true
    (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  Alcotest.(check string) "resolved agent id" "nick0cave"
    (json |> member "agent_id" |> to_string);
  Alcotest.(check string) "requested agent name" "keeper-nick0cave-agent"
    (json |> member "requested_agent_name" |> to_string);
  Alcotest.(check string) "resolved agent name" "nick0cave"
    (json |> member "resolved_agent_name" |> to_string);
  Alcotest.(check int) "total tasks" 1
    (json |> member "total_tasks" |> to_int);
  )

(* ============================================================
   Handler tests — agent_fitness
   ============================================================ *)

let test_agent_fitness_no_agents () =
  with_ctx (fun ctx ->
  let result = Tool_agent.handle_agent_fitness ctx (`Assoc []) in
  Alcotest.(check bool) "fitness succeeds" true (Tool_result.is_success result);
  Alcotest.(check bool) "has response" true (String.length (Tool_result.message result) > 0);
  )

let test_agent_fitness_specific () =
  with_ctx (fun ctx ->
  let args = `Assoc [("agent_name", `String "test-agent"); ("days", `Int 7)] in
  let result = Tool_agent.handle_agent_fitness ctx args in
  Alcotest.(check bool) "fitness with agent" true (Tool_result.is_success result);
  Alcotest.(check bool) "has response" true (String.length (Tool_result.message result) > 0);
  )

let test_agent_fitness_does_not_mutate_thompson_stats () =
  with_ctx (fun ctx ->
  let agent_name = "fitness-read-only-agent" in
  let stats = Thompson_sampling.get_stats agent_name in
  stats.alpha <- 2.0;
  stats.beta <- 3.0;
  stats.selections <- 4;
  let args = `Assoc [("agent_name", `String agent_name); ("days", `Int 7)] in
  let result = Tool_agent.handle_agent_fitness ctx args in
  Alcotest.(check bool) "fitness succeeds" true (Tool_result.is_success result);
  let after = Thompson_sampling.get_stats agent_name in
  Alcotest.(check (float 0.0001)) "alpha unchanged" 2.0 after.alpha;
  Alcotest.(check (float 0.0001)) "beta unchanged" 3.0 after.beta;
  Alcotest.(check int) "selections unchanged" 4 after.selections;
  )

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
      Alcotest.test_case "agents removed" `Quick test_dispatch_agents_removed;
      Alcotest.test_case "register_capabilities removed" `Quick
        test_dispatch_register_capabilities_removed;
      Alcotest.test_case "collaboration_graph removed" `Quick
        test_dispatch_collaboration_graph_removed;
      Alcotest.test_case "agent_update removed" `Quick test_dispatch_agent_update_removed;
      Alcotest.test_case "agent_card dispatches" `Quick test_dispatch_agent_card;
    ]);
    ("agents", [
      Alcotest.test_case "handle_agent_card" `Quick test_handle_agent_card;
      Alcotest.test_case "handle_agent_card rejects unknown action" `Quick
        test_handle_agent_card_rejects_unknown_action;
    ]);
    ("agent_update", [
      Alcotest.test_case "no agents" `Quick test_agent_fitness_no_agents;
      Alcotest.test_case "specific agent" `Quick test_agent_fitness_specific;
      Alcotest.test_case "fitness is read-only for thompson" `Quick
        test_agent_fitness_does_not_mutate_thompson_stats;
    ]);
    ("get_metrics", [
      Alcotest.test_case "no data returns not_found" `Quick test_get_metrics_no_data;
      Alcotest.test_case "missing agent_name fails" `Quick test_get_metrics_missing_agent_name;
      Alcotest.test_case "keeper agent alias resolves metric key" `Quick
        test_get_metrics_resolves_keeper_agent_alias;
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
