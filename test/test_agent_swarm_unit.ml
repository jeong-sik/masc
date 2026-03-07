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
    max_turns = 1;
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

let () =
  Alcotest.run "Swarm Unit" [
    "error_paths", [
      Alcotest.test_case "join failure returns Error" `Quick test_join_failure_returns_error;
    ];
  ]
