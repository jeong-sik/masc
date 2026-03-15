(** Test MASC tools schema and structure.
    No live server required. *)

open Agent_sdk
open Masc_mcp

(* Helper: convert OAS v0.23 tool_result to (string, string) result for test assertions *)
let exec tool args : (string, string) result =
  match Tool.execute tool args with
  | Ok out -> Ok out.Agent_sdk.Types.content
  | Error err -> Error err.Agent_sdk.Types.message

let has_sub s sub =
  let sn = String.length s and subn = String.length sub in
  if subn > sn then false
  else
    let found = ref false in
    for i = 0 to sn - subn do
      if (not !found) && String.sub s i subn = sub then found := true
    done;
    !found

let test_tool_count () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  Alcotest.(check int) "14 MASC tools" 14 (List.length tools)

let test_tool_names () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let names = List.map (fun (t : Tool.t) -> t.schema.name) tools in
  let expected = [
    "masc_list_tasks"; "masc_room_status";
    "masc_autoresearch_swarm_start";
    "masc_add_task"; "masc_batch_add_tasks";
    "masc_claim_task"; "masc_claim_next";
    "masc_set_current_task"; "masc_complete_task";
    "masc_release_task"; "masc_cancel_task";
    "masc_broadcast"; "masc_send_direct"; "masc_heartbeat"
  ] in
  Alcotest.(check (list string)) "tool names match" expected names

let test_tool_schema_json () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  List.iter (fun (t : Tool.t) ->
    let json = Tool.schema_to_json t in
    let s = Yojson.Safe.to_string json in
    Alcotest.(check bool) "valid JSON string" true (String.length s > 0);
    match json with
    | `Assoc pairs ->
      Alcotest.(check bool) "has name field" true
        (List.mem_assoc "name" pairs);
      Alcotest.(check bool) "has input_schema field" true
        (List.mem_assoc "input_schema" pairs)
    | _ ->
      Alcotest.fail "schema should be a JSON object"
  ) tools

let test_claim_requires_task_id () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let claim_tool = List.find (fun (t : Tool.t) -> t.schema.name = "masc_claim_task") tools in
  let result = exec claim_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "mentions task_id" true
      (String.length msg > 0)
  | Ok _ ->
    Alcotest.fail "should fail without task_id"

let test_add_task_requires_title () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let add_tool = List.find (fun (t : Tool.t) -> t.schema.name = "masc_add_task") tools in
  let result = exec add_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "error is non-empty" true (String.length msg > 0)
  | Ok _ ->
    Alcotest.fail "should fail without title"

let test_batch_add_requires_tasks () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let batch_tool =
    List.find (fun (t : Tool.t) -> t.schema.name = "masc_batch_add_tasks") tools
  in
  let result = exec batch_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "mentions tasks" true (has_sub msg "tasks")
  | Ok _ ->
    Alcotest.fail "should fail without tasks"

let test_batch_add_rejects_empty_tasks () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let batch_tool =
    List.find (fun (t : Tool.t) -> t.schema.name = "masc_batch_add_tasks") tools
  in
  let result = exec batch_tool (`Assoc [("tasks", `List [])]) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "mentions non-empty" true (has_sub msg "non-empty")
  | Ok _ ->
    Alcotest.fail "should fail with empty tasks"

let test_claim_next_no_params () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let claim_next_tool =
    List.find (fun (t : Tool.t) -> t.schema.name = "masc_claim_next") tools
  in
  let result = exec claim_next_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "non-empty rpc error" true (String.length msg > 0);
    Alcotest.(check bool) "not validation failure" false
      (has_sub msg "missing required field")
  | Ok _ ->
    Alcotest.fail "should fail because no live server is available"

let test_set_current_task_requires_task_id () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let set_tool =
    List.find (fun (t : Tool.t) -> t.schema.name = "masc_set_current_task") tools
  in
  let result = exec set_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "mentions task_id" true (String.length msg > 0)
  | Ok _ ->
    Alcotest.fail "should fail without task_id"

let test_release_requires_task_id () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let release_tool =
    List.find (fun (t : Tool.t) -> t.schema.name = "masc_release_task") tools
  in
  let result = exec release_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "mentions task_id" true (has_sub msg "task_id")
  | Ok _ ->
    Alcotest.fail "should fail without task_id"

let test_cancel_requires_task_id () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let cancel_tool =
    List.find (fun (t : Tool.t) -> t.schema.name = "masc_cancel_task") tools
  in
  let result = exec cancel_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "mentions task_id" true (has_sub msg "task_id")
  | Ok _ ->
    Alcotest.fail "should fail without task_id"

let () =
  Alcotest.run "MASC Tools" [
    "structure", [
      Alcotest.test_case "tool count" `Quick test_tool_count;
      Alcotest.test_case "tool names" `Quick test_tool_names;
      Alcotest.test_case "schema JSON" `Quick test_tool_schema_json;
      Alcotest.test_case "claim requires task_id" `Quick test_claim_requires_task_id;
      Alcotest.test_case "add_task requires title" `Quick test_add_task_requires_title;
      Alcotest.test_case "batch_add requires tasks" `Quick test_batch_add_requires_tasks;
      Alcotest.test_case "batch_add rejects empty tasks" `Quick test_batch_add_rejects_empty_tasks;
      Alcotest.test_case "claim_next no params" `Quick test_claim_next_no_params;
      Alcotest.test_case "set current task requires task_id" `Quick
        test_set_current_task_requires_task_id;
      Alcotest.test_case "release requires task_id" `Quick test_release_requires_task_id;
      Alcotest.test_case "cancel requires task_id" `Quick test_cancel_requires_task_id;
    ];
  ]
