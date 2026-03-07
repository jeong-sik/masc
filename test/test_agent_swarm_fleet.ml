open Agent_sdk
open Masc_mcp

let has_sub s sub =
  let sn = String.length s and subn = String.length sub in
  if subn > sn then false
  else
    let found = ref false in
    for i = 0 to sn - subn do
      if (not !found) && String.sub s i subn = sub then found := true
    done;
    !found

let test_cli_config_defaults () =
  let cc = Agent_swarm_external_agent.claude_code () in
  Alcotest.(check string) "claude binary" "claude" cc.binary;
  Alcotest.(check (list string)) "claude args" ["--print"] cc.args;
  Alcotest.(check string) "claude name" "claude-code" cc.name;
  let cx = Agent_swarm_external_agent.codex () in
  Alcotest.(check string) "codex binary" "codex" cx.binary;
  Alcotest.(check (list string)) "codex args"
    ["--quiet"; "--full-auto"] cx.args;
  let gc = Agent_swarm_external_agent.gemini_cli () in
  Alcotest.(check string) "gemini binary" "gemini" gc.binary;
  Alcotest.(check (list string)) "gemini args" ["-p"] gc.args

let test_fleet_member_variant () =
  let spec : Agent_swarm_swarm.agent_spec = {
    name = "test-sdk";
    provider = {
      Provider.provider = Provider.Anthropic;
      model_id = "test-model";
      api_key_env = "TEST_KEY";
    };
    system_prompt = "test prompt";
    tools = [];
    max_turns = 5;
  } in
  let sdk = Agent_swarm_fleet.Sdk_agent spec in
  let ext = Agent_swarm_fleet.Ext_agent (Agent_swarm_external_agent.claude_code ()) in
  Alcotest.(check string) "sdk member name" "test-sdk"
    (Agent_swarm_fleet.member_name sdk);
  Alcotest.(check string) "ext member name" "claude-code"
    (Agent_swarm_fleet.member_name ext)

let test_select_members () =
  let cc = Agent_swarm_external_agent.claude_code () in
  let cx = Agent_swarm_external_agent.codex () in
  let config : Agent_swarm_fleet.fleet_config = {
    masc_url = "http://localhost:8935";
    leader_name = "leader";
    members = [
      (Agent_swarm_fleet.Ext_agent cc, [Agent_swarm_fleet.Code; Agent_swarm_fleet.Review]);
      (Agent_swarm_fleet.Ext_agent cx, [Agent_swarm_fleet.Code]);
    ];
  } in
  let code = Agent_swarm_fleet.select_members config Agent_swarm_fleet.Code in
  Alcotest.(check int) "code members" 2 (List.length code);
  let review = Agent_swarm_fleet.select_members config Agent_swarm_fleet.Review in
  Alcotest.(check int) "review members" 1 (List.length review);
  let research = Agent_swarm_fleet.select_members config Agent_swarm_fleet.Research in
  Alcotest.(check int) "research members" 0 (List.length research)

let test_fleet_config_construction () =
  let config : Agent_swarm_fleet.fleet_config = {
    masc_url = "http://localhost:8935";
    leader_name = "fleet-leader";
    members = [];
  } in
  Alcotest.(check string) "url" "http://localhost:8935" config.masc_url;
  Alcotest.(check string) "leader" "fleet-leader" config.leader_name;
  Alcotest.(check int) "members" 0 (List.length config.members)

let test_fleet_prompt () =
  let prompt = Agent_swarm_prompts.fleet_leader ~goal:"Fix the bug"
    ~members:["alice"; "bob"] in
  Alcotest.(check bool) "has goal" true (has_sub prompt "Fix the bug");
  Alcotest.(check bool) "has alice" true (has_sub prompt "alice");
  Alcotest.(check bool) "has bob" true (has_sub prompt "bob");
  Alcotest.(check bool) "has masc" true (has_sub prompt "masc_")

let () =
  Alcotest.run "Fleet Unit" [
    "external_agent", [
      Alcotest.test_case "cli config defaults" `Quick
        test_cli_config_defaults;
    ];
    "fleet", [
      Alcotest.test_case "member variant" `Quick
        test_fleet_member_variant;
      Alcotest.test_case "select members" `Quick
        test_select_members;
      Alcotest.test_case "config construction" `Quick
        test_fleet_config_construction;
    ];
    "prompts", [
      Alcotest.test_case "fleet prompt" `Quick
        test_fleet_prompt;
    ];
  ]
