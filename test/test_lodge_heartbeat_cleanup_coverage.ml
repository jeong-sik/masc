open Alcotest

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        let rec loop idx =
          let remaining = String.length content - idx in
          let plen = String.length pattern in
          remaining >= plen
          && (String.sub content idx plen = pattern || loop (idx + 1))
        in
        if String.length pattern = 0 then true else loop 0)

let test_lodge_memory_no_agent_activities_query () =
  check bool "agentActivities query removed"
    false (file_contains_pattern "lib/lodge_memory.ml" "agentActivities(")

let test_lodge_memory_no_create_lodge_activity_mutation () =
  check bool "createLodgeActivity mutation removed"
    false (file_contains_pattern "lib/lodge_memory.ml" "createLodgeActivity(")

let test_lodge_heartbeat_no_profile_shellout () =
  check bool "profile shellout removed"
    false
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       {|Process_eio.run_argv ~timeout_sec:30.0 [sb; "graphql"; "agent"; agent_name]|})

let test_lodge_heartbeat_uses_tool_assignment_prompt () =
  check bool "structured selection prompt used"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_decision.selection_prompt");
  check bool "tool assignment phase traced"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" {|phase:"lodge_tool_assignment"|});
  check bool "structured selection parser used"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_decision.parse_selection_plan");
  check bool "tool loop worker used"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_worker.run_local");
  check bool "heartbeat delegation emits task payload"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "A2a_tools.emit_heartbeat_task")

let test_lodge_graphql_defaults_and_guards () =
  check bool "heartbeat GraphQL uses shared client"
    true
    (file_contains_pattern "lib/lodge_heartbeat_state.ml" "Graphql_client.request");
  check bool "tool_lodge GraphQL uses shared endpoint helper"
    true
    (file_contains_pattern "lib/tool_lodge_config_http.ml"
       "Graphql_endpoint.graphql_url ()");
  check bool "shared helper normalizes Railway env"
    false
    (file_contains_pattern "lib/graphql_endpoint.ml" {|Sys.getenv_opt "MASC_HTTP_PORT"|});
  check bool "shared helper supports Railway env"
    true
    (file_contains_pattern "lib/graphql_endpoint.ml" {|Sys.getenv_opt "RAILWAY_GRAPHQL_URL"|});
  check bool "shared helper has production Railway fallback"
    true
    (file_contains_pattern "lib/graphql_endpoint.ml"
       "https://second-brain-graphql-production.up.railway.app/graphql");
  check bool "HTML GraphQL guard present in shared client"
    true
    (file_contains_pattern "lib/graphql_client.ml" "endpoint returned HTML instead of JSON");
  check bool "HTML GraphQL guard present in tool_lodge"
    true
    (file_contains_pattern "lib/tool_lodge_config_http.ml"
       "endpoint returned HTML instead of JSON");
  check bool "null agents guard present in heartbeat"
    true
    (file_contains_pattern "lib/lodge_heartbeat_state.ml" "GraphQL agents is null");
  check bool "null agents guard present in tool_lodge"
    true
    (file_contains_pattern "lib/tool_lodge_config_http.ml" "GraphQL agents is null");
  check bool "shared client has curl fallback"
    true
    (file_contains_pattern "lib/graphql_client.ml"
       "curl fallback")

let test_lodge_heartbeat_updates_self_summary () =
  check bool "reflection updates self summary"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml" "Lodge_reaction.update_self_summary")

let test_lodge_heartbeat_uses_shared_prompt_cascade () =
  check bool "heartbeat uses shared prompt cascade"
    true
    (file_contains_pattern "lib/lodge_heartbeat_agents.ml" "Lodge_cascade.call")

let test_lodge_heartbeat_uses_runtime_verifier_mode () =
  check bool "heartbeat uses verifier auto mode for posts"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       "Post_verifier_llm.verify_auto ~content");
  check bool "heartbeat no longer bypasses verifier mode"
    false
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       "Post_verifier.verify ~content")

let test_lodge_heartbeat_uses_tom_context () =
  check bool "ToM context used"
    true
    (file_contains_pattern "lib/lodge_heartbeat_agents.ml" "Lodge_tom.predict_top_k")

let test_lodge_heartbeat_no_heuristic_fallback_policy () =
  check bool "scheduled trigger can request post tool"
    true
    (file_contains_pattern "lib/lodge_heartbeat_agents.ml" "| Scheduled | ManualTrigger -> true");
  check bool "content alerts cannot request post tool"
    true
    (file_contains_pattern "lib/lodge_heartbeat_agents.ml" "| ContentAlert _ | Mentioned _ -> false");
  check bool "selection failures are explicit"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       {|Skipped ("tool_loop_selection_failed:" ^ reason)|});
  check bool "post gating enforced through allowed tools"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       {|List.mem "masc_board_post" allowed_tools|});
  check bool "legacy action_hint payload removed"
    false
    (file_contains_pattern "lib/a2a_tools.ml" "action_hint");
  check bool "legacy prompt payload removed"
    false
    (file_contains_pattern "lib/a2a_tools.ml" {|("prompt", `String prompt)|});
  check bool "legacy proxied board write removed"
    false
    (file_contains_pattern "lib/a2a_tools.ml" "Board.create_post store");
  check bool "comment rate limit enforced explicitly"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       {|check_rate_limit ~agent_name `Comment|});
  check bool "post rate limit enforced explicitly"
    true
    (file_contains_pattern "lib/lodge_heartbeat.ml"
       {|check_rate_limit ~agent_name `Post|});
  check bool "worker failure reason tracked"
    true
    (file_contains_pattern "lib/lodge_worker.ml" "failure_reason")

let test_lodge_heartbeat_public_memory_helpers_removed () =
  check bool "load_agent_memories removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "val load_agent_memories");
  check bool "record_agent_memory removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "val record_agent_memory");
  check bool "ActionCode removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "ActionCode");
  check bool "ActionPropose removed from mli"
    false
    (file_contains_pattern "lib/lodge_heartbeat.mli" "ActionPropose")

let () =
  run "Lodge heartbeat cleanup coverage"
    [
      ("source", [
          test_case "agentActivities recall removed" `Quick test_lodge_memory_no_agent_activities_query;
          test_case "createLodgeActivity store removed" `Quick test_lodge_memory_no_create_lodge_activity_mutation;
          test_case "profile shellout removed" `Quick test_lodge_heartbeat_no_profile_shellout;
          test_case "tool assignment prompt mainline" `Quick test_lodge_heartbeat_uses_tool_assignment_prompt;
          test_case "graphql defaults and guards" `Quick test_lodge_graphql_defaults_and_guards;
          test_case "shared prompt cascade helper" `Quick test_lodge_heartbeat_uses_shared_prompt_cascade;
          test_case "runtime verifier mode wired" `Quick test_lodge_heartbeat_uses_runtime_verifier_mode;
          test_case "reflection updates self summary" `Quick test_lodge_heartbeat_updates_self_summary;
          test_case "ToM context used" `Quick test_lodge_heartbeat_uses_tom_context;
          test_case "no heuristic fallback policy locked" `Quick test_lodge_heartbeat_no_heuristic_fallback_policy;
          test_case "legacy public surface removed" `Quick test_lodge_heartbeat_public_memory_helpers_removed;
        ]);
    ]
