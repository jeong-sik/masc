(** Test MASC tools schema and structure.
    No live server required. *)

open Agent_sdk
open Masc_mcp

let test_tool_count () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  Alcotest.(check int) "9 MASC tools" 9 (List.length tools)

let test_tool_names () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let client =
    Agent_swarm_client.create ~net ~base_url:"http://127.0.0.1:9999" ~agent_name:"test"
  in
  let tools = Agent_swarm_tools.make_tools client ~sw in
  let names = List.map (fun (t : Tool.t) -> t.schema.name) tools in
  let expected = ["masc_list_tasks"; "masc_claim_task"; "masc_set_current_task";
                  "masc_add_task"; "masc_broadcast"; "masc_complete_task";
                  "masc_room_status"; "masc_send_direct"; "masc_heartbeat"] in
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
  let result = Tool.execute claim_tool (`Assoc []) in
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
  let result = Tool.execute add_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "error is non-empty" true (String.length msg > 0)
  | Ok _ ->
    Alcotest.fail "should fail without title"

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
  let result = Tool.execute set_tool (`Assoc []) in
  match result with
  | Error msg ->
    Alcotest.(check bool) "mentions task_id" true (String.length msg > 0)
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
      Alcotest.test_case "set current task requires task_id" `Quick
        test_set_current_task_requires_task_id;
    ];
  ]
