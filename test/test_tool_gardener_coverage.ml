(** Coverage tests for Tool_gardener — MCP tool handlers for Gardener agent

    Tests dispatch routing, input validation, and handler integration
    for gardener tools. Network-dependent handlers (health, propose_spawn
    with args, retire_agent with args, execute_spawn with args) are excluded
    because they call [Gardener.calculate_health] which invokes
    [Lodge_heartbeat.get_agents] → GraphQL API (curl to Neo4j).

    Covered handlers:
    - masc_gardener_config (env vars only, no network)
    - masc_gardener_reset_circuit (state only, no network)
    - All handlers' input validation (early return before network calls)
    - Dispatch routing for unknown tools
*)

module Tool_gardener = Masc_mcp.Tool_gardener

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown_tool () =
  let (ok, msg) = Tool_gardener.dispatch () "unknown_tool" (`Assoc []) in
  Alcotest.(check bool) "unknown tool fails" false ok;
  Alcotest.(check bool) "error mentions unknown" true
    (try ignore (Str.search_forward (Str.regexp_string "Unknown") msg 0); true with Not_found -> false)

(** Test dispatch for non-network tools only.
    These handlers do NOT call [calculate_health] or GraphQL. *)
let test_dispatch_safe_tools () =
  let safe_tools = [
    "masc_gardener_config";
    "masc_gardener_reset_circuit";
  ] in
  List.iter (fun name ->
    let (ok, _msg) = Tool_gardener.dispatch () name (`Assoc []) in
    Alcotest.(check bool) (name ^ " dispatches ok") true ok
  ) safe_tools

(** Validate that tool names with validation gates are recognized by dispatch.
    These handlers fail on missing required params (early return before network),
    but they should NOT return "Unknown tool" — that proves routing works.
    Excluded: masc_gardener_health (no params, calls calculate_health immediately). *)
let test_dispatch_recognizes_validatable_tools () =
  let tools_with_validation = [
    "masc_gardener_config";
    "masc_gardener_propose_spawn";
    "masc_gardener_retire_agent";
    "masc_gardener_execute_spawn";
    "masc_gardener_execute_retire";
    "masc_gardener_reset_circuit";
  ] in
  List.iter (fun name ->
    let (_ok, msg) = Tool_gardener.dispatch () name (`Assoc []) in
    let is_unknown =
      try ignore (Str.search_forward (Str.regexp_string "Unknown") msg 0); true
      with Not_found -> false
    in
    Alcotest.(check bool) (name ^ " is recognized") false is_unknown
  ) tools_with_validation

(* ============================================================
   Config tool tests (no network)
   ============================================================ *)

let test_config_returns_json () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_config" (`Assoc []) in
  Alcotest.(check bool) "config ok" true ok;
  let json = Yojson.Safe.from_string msg in
  let status = json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "status ok" "ok" status;
  let cb = json |> Yojson.Safe.Util.member "circuit_breaker" in
  let _is_open = cb |> Yojson.Safe.Util.member "is_open" |> Yojson.Safe.Util.to_bool in
  let _can_spawn = json |> Yojson.Safe.Util.member "can_spawn" |> Yojson.Safe.Util.to_bool in
  let _can_retire = json |> Yojson.Safe.Util.member "can_retire" |> Yojson.Safe.Util.to_bool in
  ()

(* ============================================================
   Input validation tests (early return, no network)
   ============================================================ *)

let test_propose_spawn_missing_topic () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_propose_spawn" (`Assoc []) in
  Alcotest.(check bool) "missing topic fails" false ok;
  Alcotest.(check bool) "error mentions topic" true
    (try ignore (Str.search_forward (Str.regexp_string "topic") msg 0); true with Not_found -> false)

let test_retire_missing_agent_name () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_retire_agent" (`Assoc []) in
  Alcotest.(check bool) "missing agent_name fails" false ok;
  Alcotest.(check bool) "error mentions agent_name" true
    (try ignore (Str.search_forward (Str.regexp_string "agent_name") msg 0); true with Not_found -> false)

let test_execute_spawn_missing_topic () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_execute_spawn" (`Assoc []) in
  Alcotest.(check bool) "missing topic fails" false ok;
  Alcotest.(check bool) "error mentions topic" true
    (try ignore (Str.search_forward (Str.regexp_string "topic") msg 0); true with Not_found -> false)

let test_execute_retire_missing_agent () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_execute_retire" (`Assoc []) in
  Alcotest.(check bool) "missing agent_name fails" false ok;
  Alcotest.(check bool) "error mentions agent_name" true
    (try ignore (Str.search_forward (Str.regexp_string "agent_name") msg 0); true with Not_found -> false)

(* ============================================================
   Circuit breaker tests (no network)
   ============================================================ *)

let test_reset_circuit () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_reset_circuit" (`Assoc []) in
  Alcotest.(check bool) "reset ok" true ok;
  let json = Yojson.Safe.from_string msg in
  let status = json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "status ok" "ok" status;
  let _was_open = json |> Yojson.Safe.Util.member "was_open" |> Yojson.Safe.Util.to_bool in
  ()

let test_reset_circuit_idempotent () =
  let _ = Tool_gardener.dispatch () "masc_gardener_reset_circuit" (`Assoc []) in
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_reset_circuit" (`Assoc []) in
  Alcotest.(check bool) "second reset ok" true ok;
  let json = Yojson.Safe.from_string msg in
  let was_open = json |> Yojson.Safe.Util.member "was_open" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "was already closed" false was_open

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_gardener" [
    ("dispatch", [
      Alcotest.test_case "unknown tool" `Quick test_dispatch_unknown_tool;
      Alcotest.test_case "safe tools dispatch" `Quick test_dispatch_safe_tools;
      Alcotest.test_case "validatable tools recognized" `Quick test_dispatch_recognizes_validatable_tools;
    ]);
    ("config", [
      Alcotest.test_case "returns json" `Quick test_config_returns_json;
    ]);
    ("validation", [
      Alcotest.test_case "propose_spawn missing topic" `Quick test_propose_spawn_missing_topic;
      Alcotest.test_case "retire missing agent_name" `Quick test_retire_missing_agent_name;
      Alcotest.test_case "execute_spawn missing topic" `Quick test_execute_spawn_missing_topic;
      Alcotest.test_case "execute_retire missing agent" `Quick test_execute_retire_missing_agent;
    ]);
    ("circuit_breaker", [
      Alcotest.test_case "reset" `Quick test_reset_circuit;
      Alcotest.test_case "reset idempotent" `Quick test_reset_circuit_idempotent;
    ]);
  ]
