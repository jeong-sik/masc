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
    max_tokens = None;
    max_turns = 5;
    include_masc_tools = true;
    managed_task = None;
    expected_final_marker = None;
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

let test_fleet_planner_prompt () =
  let prompt = Agent_swarm_prompts.fleet_planner ~goal:"Ship the feature" in
  Alcotest.(check bool) "has goal" true (has_sub prompt "Ship the feature");
  Alcotest.(check bool) "uses batch add" true
    (has_sub prompt "masc_batch_add_tasks");
  Alcotest.(check bool) "planner no dev tools" true
    (has_sub prompt "Do not use development tools")

let test_fleet_worker_prompt () =
  let prompt =
    Agent_swarm_prompts.fleet_worker ~name:"fleet-worker-1" ~workdir:"/tmp/work"
  in
  Alcotest.(check bool) "has worker name" true
    (has_sub prompt "fleet-worker-1");
  Alcotest.(check bool) "has workdir" true
    (has_sub prompt "/tmp/work");
  Alcotest.(check bool) "uses claim_next" true
    (has_sub prompt "masc_claim_next");
  Alcotest.(check bool) "uses set current task" true
    (has_sub prompt "masc_set_current_task")

let test_run_full_plan () =
  let provider = Provider.local_qwen () in
  let plan =
    Agent_swarm_fleet.build_run_full_plan ~provider ~goal:"Fix the bug"
      ~num_members:3 ~workdir:"/tmp/work" ~max_turns:7
  in
  Alcotest.(check string) "planner name" "fleet-planner"
    plan.planner_spec.Agent_swarm_swarm.name;
  Alcotest.(check bool) "planner uses masc tools" true
    plan.planner_spec.Agent_swarm_swarm.include_masc_tools;
  Alcotest.(check int) "worker count" 3 (List.length plan.worker_specs);
  Alcotest.(check string) "first worker" "fleet-worker-1"
    ((List.hd plan.worker_specs).Agent_swarm_swarm.name);
  Alcotest.(check bool) "worker prompt carries workdir" true
    (has_sub (List.hd plan.worker_specs).Agent_swarm_swarm.system_prompt "/tmp/work");
  Alcotest.(check bool) "worker turn budget" true
    (List.for_all
       (fun spec -> spec.Agent_swarm_swarm.max_turns = 7)
       plan.worker_specs)

let test_run_full_plan_rejects_zero_members () =
  Alcotest.check_raises "zero members rejected"
    (Invalid_argument "num_members must be positive")
    (fun () ->
       ignore
         (Agent_swarm_fleet.build_run_full_plan ~provider:(Provider.local_qwen ())
            ~goal:"Fix the bug" ~num_members:0 ~workdir:"/tmp/work"
            ~max_turns:7))

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
      Alcotest.test_case "fleet planner prompt" `Quick
        test_fleet_planner_prompt;
      Alcotest.test_case "fleet worker prompt" `Quick
        test_fleet_worker_prompt;
      Alcotest.test_case "run_full plan" `Quick
        test_run_full_plan;
      Alcotest.test_case "run_full plan rejects zero members" `Quick
        test_run_full_plan_rejects_zero_members;
    ];
  ]
