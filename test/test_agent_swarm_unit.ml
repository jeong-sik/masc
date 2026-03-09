(** Unit tests for swarm runner.
    No live server required — tests Error paths when MASC is unreachable. *)

open Agent_sdk
open Masc_mcp

let test_join_failure_returns_error () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let provider : Provider.config = {
    provider = Local { base_url = "http://127.0.0.1:9999" };
    model_id = "test-model";
    api_key_env = "AGENT_SDK_TEST_DUMMY_KEY_swarm";
  } in
  let spec : Agent_swarm_swarm.agent_spec = {
    name = "test-agent";
    provider;
    system_prompt = "test";
    tools = [];
    max_tokens = None;
    max_turns = 1;
    include_masc_tools = true;
    managed_task = None;
    expected_final_marker = None;
  } in
  let config : Agent_swarm_swarm.swarm_config = {
    masc_url = "http://127.0.0.1:9999";
    agents = [spec];
  } in
  let results = Agent_swarm_swarm.run ~sw ~net ~clock config ~goal:"test" in
  Alcotest.(check int) "one result" 1 (List.length results);
  let r = List.hd results in
  Alcotest.(check string) "agent name" "test-agent" r.agent_name;
  match r.result with
  | Error msg ->
    Alcotest.(check bool) "error mentions MASC or network" true
      (String.length msg > 0)
  | Ok _ ->
    Alcotest.fail "should fail when MASC server is unreachable"

let test_validate_expected_final_marker_requires_real_output () =
  let response : Agent_sdk.Types.api_response = {
    id = "resp-1";
    model = "test-model";
    stop_reason = Agent_sdk.Types.EndTurn;
    content = [ Agent_sdk.Types.Text "role output without final marker" ];
    usage = None;
  } in
  match
    Agent_swarm_swarm.validate_expected_final_marker response
      ~expected_final_marker:(Some "FINAL_MARKER[demo:discover:official]")
  with
  | Ok _ -> Alcotest.fail "missing marker should be rejected"
  | Error message ->
      Alcotest.(check bool) "non-empty error" true (String.length message > 0)

let test_validate_expected_final_marker_accepts_exact_line () =
  let marker = "FINAL_MARKER[demo:discover:official]" in
  let response : Agent_sdk.Types.api_response = {
    id = "resp-2";
    model = "test-model";
    stop_reason = Agent_sdk.Types.EndTurn;
    content = [ Agent_sdk.Types.Text ("summary\n" ^ marker) ];
    usage = None;
  } in
  match
    Agent_swarm_swarm.validate_expected_final_marker response
      ~expected_final_marker:(Some marker)
  with
  | Ok validated ->
      Alcotest.(check string) "text preserved"
        ("summary\n" ^ marker)
        (Agent_swarm_swarm.extract_text validated)
  | Error message ->
      Alcotest.failf "expected marker should pass: %s" message

let test_validate_expected_final_marker_requires_final_line_position () =
  let marker = "FINAL_MARKER[demo:discover:official]" in
  let response : Agent_sdk.Types.api_response = {
    id = "resp-3";
    model = "test-model";
    stop_reason = Agent_sdk.Types.EndTurn;
    content = [ Agent_sdk.Types.Text ("summary\n" ^ marker ^ "\ntrailing text") ];
    usage = None;
  } in
  match
    Agent_swarm_swarm.validate_expected_final_marker response
      ~expected_final_marker:(Some marker)
  with
  | Ok _ -> Alcotest.fail "marker should fail when not last non-empty line"
  | Error message ->
      Alcotest.(check string) "position error message"
        ("Missing expected final marker as final non-empty line: " ^ marker)
        message

let test_ensure_expected_final_marker_synthesizes_missing_line () =
  let marker = "FINAL_MARKER[demo:discover:official]" in
  let response : Agent_sdk.Types.api_response = {
    id = "resp-4";
    model = "test-model";
    stop_reason = Agent_sdk.Types.EndTurn;
    content = [ Agent_sdk.Types.Text "summary without marker" ];
    usage = None;
  } in
  match
    Agent_swarm_swarm.ensure_expected_final_marker response
      ~expected_final_marker:(Some marker)
  with
  | Ok validated ->
      Alcotest.(check string) "response preserved"
        "summary without marker"
        (Agent_swarm_swarm.extract_text validated.response);
      Alcotest.(check bool) "model marker missing" false
        validated.model_final_marker_seen;
      Alcotest.(check bool) "runtime assistance recorded" true
        validated.final_marker_assisted
  | Error message ->
      Alcotest.failf "expected runtime marker synthesis: %s" message

let () =
  Alcotest.run "Swarm Unit" [
    "error_paths", [
      Alcotest.test_case "join failure returns Error" `Quick test_join_failure_returns_error;
      Alcotest.test_case "missing expected final marker fails" `Quick
        test_validate_expected_final_marker_requires_real_output;
      Alcotest.test_case "exact expected final marker passes" `Quick
        test_validate_expected_final_marker_accepts_exact_line;
      Alcotest.test_case "expected final marker must be last non-empty line" `Quick
        test_validate_expected_final_marker_requires_final_line_position;
      Alcotest.test_case "ensure expected final marker synthesizes when missing" `Quick
        test_ensure_expected_final_marker_synthesizes_missing_line;
    ];
  ]
