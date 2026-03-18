(** Coverage tests for Tool_perpetual — MCP tool handlers for
    the Perpetual Agent Runtime.

    Tests dispatch routing, wrap_result, handle_status/stop/inject
    with pre-populated global state, and handle_start error paths.

    Network-free: no actual LLM calls. We populate active_agents
    directly and test handler logic. *)

module Tool_perpetual = Masc_mcp.Tool_perpetual
module Perpetual_loop = Masc_mcp.Perpetual_loop
module Llm_client = Masc_mcp.Llm_provider_dispatch

(* ============================================================
   Test Helpers
   ============================================================ *)

(** Create a minimal context with no Eio deps. *)
let make_ctx () : Tool_perpetual.context = {
  agent_name = "test-agent";
  start_loop = None;
  sw = None;
  proc_mgr = None;
  room_config = None;
}

(** Create a default model spec for testing. *)
let test_model : Masc_mcp.Llm_types.model_spec = {
  provider = Masc_mcp.Llm_types.Llama;
  model_id = "test-model";
  max_context = 4000;
  api_url = "http://127.0.0.1:8085";
  api_key_env = None;
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

(** Create a loop config and state, register in active_agents. *)
let register_agent trace_id =
  let config = Perpetual_loop.default_config
    ~goal:"test goal" ~models:[test_model] () in
  let state = Perpetual_loop.create_state config in
  let state = { state with Perpetual_loop.generation = 0 } in
  Hashtbl.replace Tool_perpetual.active_agents trace_id (state, config);
  Tool_perpetual.latest_trace_id := Some trace_id;
  (state, config)

(** Clear global state between tests. *)
let cleanup () =
  Hashtbl.clear Tool_perpetual.active_agents;
  Tool_perpetual.latest_trace_id := None

(* ============================================================
   wrap_result tests
   ============================================================ *)

let test_wrap_result_success () =
  let json = `Assoc [("status", `String "ok")] in
  let (ok, s) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "no error key → success" true ok;
  Alcotest.(check bool) "serialized" true (String.length s > 0)

let test_wrap_result_error () =
  let json = `Assoc [("error", `String "something broke")] in
  let (ok, _s) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "error key → false" false ok

let test_wrap_result_non_assoc () =
  let json = `String "plain" in
  let (ok, _s) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "non-assoc → success" true ok

(* ============================================================
   dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  let ctx = make_ctx () in
  let result = Tool_perpetual.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown → None" true (result = None)

let test_dispatch_routes_start () =
  cleanup ();
  let ctx = make_ctx () in
  let result = Tool_perpetual.dispatch ctx ~name:"masc_perpetual_start"
    ~args:(`Assoc [("goal", `String "test"); ("models", `List [])]) in
  Alcotest.(check bool) "start routes" true (result <> None);
  cleanup ()

let test_dispatch_routes_status () =
  cleanup ();
  let ctx = make_ctx () in
  let result = Tool_perpetual.dispatch ctx ~name:"masc_perpetual_status"
    ~args:(`Assoc []) in
  Alcotest.(check bool) "status routes" true (result <> None)

let test_dispatch_routes_stop () =
  cleanup ();
  let ctx = make_ctx () in
  let result = Tool_perpetual.dispatch ctx ~name:"masc_perpetual_stop"
    ~args:(`Assoc []) in
  Alcotest.(check bool) "stop routes" true (result <> None)

let test_dispatch_routes_inject () =
  cleanup ();
  let ctx = make_ctx () in
  let result = Tool_perpetual.dispatch ctx ~name:"masc_perpetual_inject"
    ~args:(`Assoc [("message", `String "hi")]) in
  Alcotest.(check bool) "inject routes" true (result <> None)

(* ============================================================
   handle_start tests
   ============================================================ *)

let test_start_no_valid_models () =
  cleanup ();
  let ctx = make_ctx () in
  let args = `Assoc [
    ("goal", `String "test goal");
    ("models", `List [`String "invalid-no-colon"]);
  ] in
  let result = Tool_perpetual.dispatch ctx ~name:"masc_perpetual_start" ~args in
  (match result with
  | Some (ok, body) ->
    Alcotest.(check bool) "fails on no valid models" false ok;
    Alcotest.(check bool) "error in body" true
      (String.length body > 0 && Yojson.Safe.Util.member "error"
        (Yojson.Safe.from_string body) <> `Null)
  | None -> Alcotest.fail "should route");
  cleanup ()

let test_start_with_valid_model () =
  cleanup ();
  let ctx = make_ctx () in
  let args = `Assoc [
    ("goal", `String "write a poem");
    ("models", `List [`String "llama:test-model"]);
  ] in
  let result = Tool_perpetual.dispatch ctx ~name:"masc_perpetual_start" ~args in
  (match result with
  | Some (ok, body) ->
    Alcotest.(check bool) "succeeds" true ok;
    let json = Yojson.Safe.from_string body in
    let status = Yojson.Safe.Util.(member "status" json |> to_string) in
    (* No start_loop → status="created" *)
    Alcotest.(check string) "status created (no loop)" "created" status
  | None -> Alcotest.fail "should route");
  cleanup ()

let test_start_optional_params () =
  cleanup ();
  let ctx = make_ctx () in
  let args = `Assoc [
    ("goal", `String "test");
    ("models", `List [`String "llama:test-model"]);
    ("verify", `Bool false);
    ("heartbeat_sec", `Float 60.0);
    ("max_idle", `Int 10);
    ("coding_mode", `Bool true);
    ("coding_agent", `String "codex");
    ("coding_timeout_sec", `Int 3600);
  ] in
  let result = Tool_perpetual.dispatch ctx ~name:"masc_perpetual_start" ~args in
  (match result with
  | Some (ok, _body) ->
    Alcotest.(check bool) "succeeds with all optional params" true ok
  | None -> Alcotest.fail "should route");
  cleanup ()

(* ============================================================
   handle_status tests
   ============================================================ *)

let test_status_no_agent () =
  cleanup ();
  let (ok, body) = Tool_perpetual.wrap_result (Tool_perpetual.handle_status (`Assoc [])) in
  Alcotest.(check bool) "fails" false ok;
  Alcotest.(check bool) "error in body" true
    (let parsed = Yojson.Safe.from_string body in
     Yojson.Safe.Util.member "error" parsed <> `Null)

let test_status_with_agent () =
  cleanup ();
  let _state, _config = register_agent "trace-001" in
  let json = Tool_perpetual.handle_status (`Assoc []) in
  let result = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "succeeds" true (fst result);
  let parsed = Yojson.Safe.from_string (snd result) in
  let goal = Yojson.Safe.Util.(member "goal" parsed |> to_string) in
  Alcotest.(check string) "goal matches" "test goal" goal;
  cleanup ()

let test_status_by_trace_id () =
  cleanup ();
  ignore (register_agent "trace-aaa");
  ignore (register_agent "trace-bbb");
  let json = Tool_perpetual.handle_status (`Assoc [("trace_id", `String "trace-aaa")]) in
  let (ok, _) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "finds specific trace" true ok;
  cleanup ()

let test_status_unknown_trace () =
  cleanup ();
  let json = Tool_perpetual.handle_status (`Assoc [("trace_id", `String "nonexistent")]) in
  let (ok, _) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "fails for unknown" false ok;
  cleanup ()

(* ============================================================
   handle_stop tests
   ============================================================ *)

let test_stop_no_agent () =
  cleanup ();
  let json = Tool_perpetual.handle_stop (`Assoc []) in
  let (ok, _) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "fails" false ok

let test_stop_with_agent () =
  cleanup ();
  let (state, _config) = register_agent "trace-stop" in
  Alcotest.(check bool) "running before stop" true state.Perpetual_loop.running;
  let json = Tool_perpetual.handle_stop (`Assoc [("reason", `String "test done")]) in
  let (ok, body) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "succeeds" true ok;
  Alcotest.(check bool) "stopped" false state.Perpetual_loop.running;
  let parsed = Yojson.Safe.from_string body in
  let reason = Yojson.Safe.Util.(member "reason" parsed |> to_string) in
  Alcotest.(check string) "reason preserved" "test done" reason;
  cleanup ()

let test_stop_default_reason () =
  cleanup ();
  ignore (register_agent "trace-def");
  let json = Tool_perpetual.handle_stop (`Assoc []) in
  let (ok, body) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "succeeds" true ok;
  let parsed = Yojson.Safe.from_string body in
  let reason = Yojson.Safe.Util.(member "reason" parsed |> to_string) in
  Alcotest.(check string) "default reason" "manual stop" reason;
  cleanup ()

(* ============================================================
   handle_inject tests
   ============================================================ *)

let test_inject_no_agent () =
  cleanup ();
  let json = Tool_perpetual.handle_inject (`Assoc [("message", `String "hello")]) in
  let (ok, _) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "fails" false ok

let test_inject_with_agent () =
  cleanup ();
  let (state, _config) = register_agent "trace-inject" in
  let prev_idle = state.Perpetual_loop.idle_turns in
  state.Perpetual_loop.idle_turns <- 3;
  let json = Tool_perpetual.handle_inject (`Assoc [("message", `String "new goal info")]) in
  let (ok, body) = Tool_perpetual.wrap_result json in
  Alcotest.(check bool) "succeeds" true ok;
  Alcotest.(check int) "idle resets to 0" 0 state.Perpetual_loop.idle_turns;
  ignore prev_idle;
  let parsed = Yojson.Safe.from_string body in
  let msg_len = Yojson.Safe.Util.(member "message_length" parsed |> to_int) in
  Alcotest.(check int) "message_length" (String.length "new goal info") msg_len;
  cleanup ()

(* ============================================================
   schemas tests
   ============================================================ *)

let test_schemas_count () =
  Alcotest.(check int) "4 schemas" 4
    (List.length Tool_perpetual.schemas)

let test_schemas_names () =
  let names = List.map (fun (s : Masc_mcp.Types.tool_schema) -> s.name)
    Tool_perpetual.schemas in
  List.iter (fun expected ->
    Alcotest.(check bool) (expected ^ " present") true
      (List.mem expected names)
  ) ["masc_perpetual_start"; "masc_perpetual_status";
     "masc_perpetual_stop"; "masc_perpetual_inject"]

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_perpetual coverage" [
    ("wrap_result", [
      Alcotest.test_case "success" `Quick test_wrap_result_success;
      Alcotest.test_case "error" `Quick test_wrap_result_error;
      Alcotest.test_case "non-assoc" `Quick test_wrap_result_non_assoc;
    ]);
    ("dispatch", [
      Alcotest.test_case "unknown" `Quick test_dispatch_unknown;
      Alcotest.test_case "routes start" `Quick test_dispatch_routes_start;
      Alcotest.test_case "routes status" `Quick test_dispatch_routes_status;
      Alcotest.test_case "routes stop" `Quick test_dispatch_routes_stop;
      Alcotest.test_case "routes inject" `Quick test_dispatch_routes_inject;
    ]);
    ("handle_start", [
      Alcotest.test_case "no valid models" `Quick test_start_no_valid_models;
      Alcotest.test_case "valid model" `Quick test_start_with_valid_model;
      Alcotest.test_case "optional params" `Quick test_start_optional_params;
    ]);
    ("handle_status", [
      Alcotest.test_case "no agent" `Quick test_status_no_agent;
      Alcotest.test_case "with agent" `Quick test_status_with_agent;
      Alcotest.test_case "by trace_id" `Quick test_status_by_trace_id;
      Alcotest.test_case "unknown trace" `Quick test_status_unknown_trace;
    ]);
    ("handle_stop", [
      Alcotest.test_case "no agent" `Quick test_stop_no_agent;
      Alcotest.test_case "with agent" `Quick test_stop_with_agent;
      Alcotest.test_case "default reason" `Quick test_stop_default_reason;
    ]);
    ("handle_inject", [
      Alcotest.test_case "no agent" `Quick test_inject_no_agent;
      Alcotest.test_case "with agent" `Quick test_inject_with_agent;
    ]);
    ("schemas", [
      Alcotest.test_case "count" `Quick test_schemas_count;
      Alcotest.test_case "names" `Quick test_schemas_names;
    ]);
  ]
