(** Coverage tests for Tool_gardener — MCP tool handlers for Gardener agent

    Tests dispatch routing, input validation, and handler integration
    for gardener tools. Network-dependent handlers (health, propose_spawn
    with args, retire_agent with args, execute_spawn with args) are excluded
    because they call [Gardener.calculate_health] which invokes
    Room.get_agents_raw_in_room → GraphQL API (curl to Neo4j).

    Covered handlers:
    - masc_gardener_config (env vars only, no network)
    - masc_gardener_reset_circuit (state only, no network)
    - All handlers' input validation (early return before network calls)
    - Dispatch routing for unknown tools
*)

module Tool_gardener = Masc_mcp.Tool_gardener

(** Case-insensitive substring check for error message assertions. *)
let msg_contains ~needle haystack =
  let lc = String.lowercase_ascii haystack in
  let ln = String.lowercase_ascii needle in
  try ignore (Str.search_forward (Str.regexp_string ln) lc 0); true
  with Not_found -> false

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown_tool () =
  let (ok, msg) = Tool_gardener.dispatch () "unknown_tool" (`Assoc []) in
  Alcotest.(check bool) "unknown tool fails" false ok;
  Alcotest.(check bool) "error mentions unknown" true (msg_contains ~needle:"unknown" msg)

(** Test dispatch for non-network tools only.
    These handlers do NOT call [calculate_health] or GraphQL. *)
let test_dispatch_safe_tools () =
  let safe_tools = [
    "masc_gardener_config";
    "masc_gardener_status";
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
    "masc_gardener_status";
    "masc_gardener_propose_spawn";
    "masc_gardener_retire_agent";
    "masc_gardener_execute_spawn";
    "masc_gardener_execute_retire";
    "masc_gardener_reset_circuit";
  ] in
  List.iter (fun name ->
    let (_ok, msg) = Tool_gardener.dispatch () name (`Assoc []) in
    Alcotest.(check bool) (name ^ " is recognized") false (msg_contains ~needle:"unknown" msg)
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
  let provenance = json |> Yojson.Safe.Util.member "provenance" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "config provenance truth" "truth" provenance;
  let cb = json |> Yojson.Safe.Util.member "circuit_breaker" in
  let is_open = cb |> Yojson.Safe.Util.member "is_open" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "circuit_breaker.is_open is bool" true (is_open || not is_open);
  let can_spawn = json |> Yojson.Safe.Util.member "can_spawn" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "can_spawn is bool" true (can_spawn || not can_spawn);
  let can_retire = json |> Yojson.Safe.Util.member "can_retire" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "can_retire is bool" true (can_retire || not can_retire)

let test_status_returns_truth_runtime_json () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_status" (`Assoc []) in
  Alcotest.(check bool) "status ok" true ok;
  let json = Yojson.Safe.from_string msg in
  let provenance = json |> Yojson.Safe.Util.member "provenance" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "status provenance truth" "truth" provenance;
  let authoritative = json |> Yojson.Safe.Util.member "authoritative" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "status authoritative" true authoritative;
  let runtime = json |> Yojson.Safe.Util.member "runtime" in
  Alcotest.(check bool) "runtime present" true (runtime <> `Null);
  let tick_count = runtime |> Yojson.Safe.Util.member "tick_count" |> Yojson.Safe.Util.to_int in
  Alcotest.(check bool) "tick_count nonnegative" true (tick_count >= 0);
  let alive = runtime |> Yojson.Safe.Util.member "alive" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "alive is bool" true (alive || not alive);
  let health_summary = runtime |> Yojson.Safe.Util.member "health_summary" in
  Alcotest.(check bool) "health_summary present" true (health_summary <> `Null)

let test_spawn_decision_provenance_uses_decision_path () =
  let approved =
    Masc_mcp.Gardener_types.SpawnApproved
      {
        topic = "security";
        urgency = Masc_mcp.Gardener_types.Medium;
        proposed_traits = [];
        proposed_hours = [];
        reason = "approved";
      }
  in
  let deferred =
    Masc_mcp.Gardener_types.SpawnDeferred
      { topic = "security"; retry_after_sec = 60.0; reason = "cooldown"; }
  in
  let rejected =
    Masc_mcp.Gardener_types.SpawnRejected
      { topic = "security"; reason = "population cap"; }
  in
  Alcotest.(check string) "approved with judgment path uses judgment" "judgment"
    (Tool_gardener.spawn_decision_provenance ~decision_path:"judgment" approved);
  Alcotest.(check string) "approved with fallback path uses fallback" "fallback"
    (Tool_gardener.spawn_decision_provenance ~decision_path:"fallback" approved);
  Alcotest.(check string) "deferred judgment path stays judgment" "judgment"
    (Tool_gardener.spawn_decision_provenance ~decision_path:"judgment" deferred);
  Alcotest.(check string) "rejected judgment path stays judgment" "judgment"
    (Tool_gardener.spawn_decision_provenance ~decision_path:"judgment" rejected)

let test_retirement_decision_provenance_always_fallback () =
  let approved =
    Masc_mcp.Gardener_types.RetireApproved
      { agent_name = "agent-x"; reason = "idle"; grace_period_sec = 30.0; }
  in
  let deferred =
    Masc_mcp.Gardener_types.RetireDeferred
      { agent_name = "agent-x"; retry_after_sec = 60.0; reason = "cooldown"; }
  in
  let rejected =
    Masc_mcp.Gardener_types.RetireRejected
      { agent_name = "agent-x"; reason = "active"; }
  in
  Alcotest.(check string) "approved retirement fallback" "fallback"
    (Tool_gardener.retirement_decision_provenance approved);
  Alcotest.(check string) "deferred retirement fallback" "fallback"
    (Tool_gardener.retirement_decision_provenance deferred);
  Alcotest.(check string) "rejected retirement fallback" "fallback"
    (Tool_gardener.retirement_decision_provenance rejected)

(* ============================================================
   Input validation tests (early return, no network)
   ============================================================ *)

let test_propose_spawn_missing_topic () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_propose_spawn" (`Assoc []) in
  Alcotest.(check bool) "missing topic fails" false ok;
  Alcotest.(check bool) "error mentions topic" true (msg_contains ~needle:"topic" msg)

let test_retire_missing_agent_name () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_retire_agent" (`Assoc []) in
  Alcotest.(check bool) "missing agent_name fails" false ok;
  Alcotest.(check bool) "error mentions agent_name" true (msg_contains ~needle:"agent_name" msg)

let test_execute_spawn_missing_topic () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_execute_spawn" (`Assoc []) in
  Alcotest.(check bool) "missing topic fails" false ok;
  Alcotest.(check bool) "error mentions topic" true (msg_contains ~needle:"topic" msg)

let test_execute_retire_missing_agent () =
  let (ok, msg) = Tool_gardener.dispatch () "masc_gardener_execute_retire" (`Assoc []) in
  Alcotest.(check bool) "missing agent_name fails" false ok;
  Alcotest.(check bool) "error mentions agent_name" true (msg_contains ~needle:"agent_name" msg)

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
      Alcotest.test_case "status returns runtime json" `Quick test_status_returns_truth_runtime_json;
      Alcotest.test_case "spawn provenance path" `Quick test_spawn_decision_provenance_uses_decision_path;
      Alcotest.test_case "retirement provenance path" `Quick test_retirement_decision_provenance_always_fallback;
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
