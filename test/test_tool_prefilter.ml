(** Unit tests for Tool_prefilter — TF-IDF cosine similarity. *)

open Alcotest
open Masc_mcp

(* ================================================================ *)
(* Fixtures                                                         *)
(* ================================================================ *)

let make_schema name description =
  { Types.name; description;
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ] }

let essential_tools = [
  make_schema "masc_heartbeat"
    "Update your heartbeat timestamp to prove you are still active.";
  make_schema "masc_heartbeat_start"
    "Start automatic background heartbeat pings at a given interval.";
  make_schema "masc_heartbeat_stop"
    "Stop a periodic heartbeat started by masc_heartbeat_start.";
  make_schema "masc_broadcast"
    "Send a message visible to ALL agents via SSE push.";
  make_schema "masc_join"
    "Join the MASC namespace to collaborate with other AI agents.";
  make_schema "masc_leave"
    "Leave the MASC namespace and mark yourself as offline.";
  make_schema "masc_status"
    "Get current namespace status: active agents, task queue, recent broadcasts.";
  make_schema "masc_dashboard"
    "Render the MASC dashboard summarizing namespaces, agents, and tasks.";
  make_schema "masc_agents"
    "Get detailed status of all agents: current tasks, capabilities.";
  make_schema "masc_who"
    "List all agents currently in the room with their capabilities.";
  make_schema "masc_tasks"
    "List tasks in backlog with their status and assignee.";
  make_schema "masc_add_task"
    "Add a new task to the backlog for agents to claim.";
  make_schema "masc_claim_next"
    "Claim the highest priority unclaimed task.";
  make_schema "masc_plan_init"
    "Initialize a planning context for a task.";
  make_schema "masc_plan_get"
    "Retrieve the full planning context for a task as markdown.";
  make_schema "masc_plan_update"
    "Overwrite the current task plan with new content.";
]

(** Extended tool set covering newly added synonym families. *)
let extended_tools =
  essential_tools
  @ [
    make_schema "masc_code_search"
      "Search for symbols and patterns across the codebase.";
    make_schema "masc_code_read"
      "Read the contents of a source file.";
    make_schema "masc_governance_status"
      "Query the current governance policy status.";
    make_schema "masc_autoresearch_start"
      "Start an automated research cycle.";
    make_schema "masc_team_session_start"
      "Start a supervised execution session.";
    make_schema "masc_worktree_create"
      "Create a new git worktree for an isolated branch.";
    make_schema "masc_worktree_list"
      "List all active git worktrees.";
    make_schema "masc_agent_card"
      "Retrieve the agent card and profile information.";
    make_schema "masc_auth_status"
      "Check authentication and token credential status.";
    make_schema "masc_web_search"
      "Search the internet for information.";
  ]

let names_of results =
  List.map (fun (s : Types.tool_schema) -> s.name) results

let has_tool name results =
  List.mem name (names_of results)

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > hay_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

(* ================================================================ *)
(* Tests: recall                                                    *)
(* ================================================================ *)

let test_heartbeat_in_top3 () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"send heartbeat" ~k:3 in
  check bool "masc_heartbeat in top-3" true
    (has_tool "masc_heartbeat" result)

let test_broadcast_in_top3 () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"broadcast a message to all agents" ~k:3 in
  check bool "masc_broadcast in top-3" true
    (has_tool "masc_broadcast" result)

let test_join_in_top3 () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"join the namespace" ~k:3 in
  check bool "masc_join in top-3" true
    (has_tool "masc_join" result)

let test_add_task_in_top3 () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"create a new task" ~k:3 in
  check bool "masc_add_task in top-3" true
    (has_tool "masc_add_task" result)

(* ================================================================ *)
(* Tests: synonym expansion                                         *)
(* ================================================================ *)

let test_synonym_broadcast () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"let everyone know that CI is fixed" ~k:3 in
  check bool "synonym: broadcast via 'everyone'" true
    (has_tool "masc_broadcast" result)

let test_synonym_dashboard () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"show me activity overview" ~k:3 in
  check bool "synonym: dashboard via 'activity overview'" true
    (has_tool "masc_dashboard" result)

let test_synonym_claim_next () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"give me work to do" ~k:3 in
  check bool "synonym: claim_next via 'give me work'" true
    (has_tool "masc_claim_next" result)

(* ================================================================ *)
(* Tests: new tool family synonym retrieval                         *)
(* ================================================================ *)

let test_synonym_code_search () =
  let result = Tool_prefilter.filter
    ~tools:extended_tools ~query:"search the codebase for a symbol" ~k:3 in
  check bool "synonym: masc_code_search via 'codebase search'" true
    (has_tool "masc_code_search" result)

let test_synonym_code_read () =
  let result = Tool_prefilter.filter
    ~tools:extended_tools ~query:"read source file contents" ~k:3 in
  check bool "synonym: masc_code_read via 'read source'" true
    (has_tool "masc_code_read" result)

let test_synonym_governance_status () =
  let result = Tool_prefilter.filter
    ~tools:extended_tools ~query:"check governance policy status" ~k:3 in
  check bool "synonym: masc_governance_status via 'governance status'" true
    (has_tool "masc_governance_status" result)

let test_synonym_autoresearch_start () =
  let result = Tool_prefilter.filter
    ~tools:extended_tools ~query:"begin auto research" ~k:3 in
  check bool "synonym: masc_autoresearch_start via 'begin research'" true
    (has_tool "masc_autoresearch_start" result)

let test_synonym_team_session_start () =
  let result = Tool_prefilter.filter
    ~tools:extended_tools ~query:"start a supervised execution session" ~k:3 in
  check bool "synonym: masc_team_session_start via 'start supervised execution'" true
    (has_tool "masc_team_session_start" result)

let test_synonym_worktree_create () =
  let result = Tool_prefilter.filter
    ~tools:extended_tools ~query:"create a new worktree" ~k:3 in
  check bool "synonym: masc_worktree_create via 'create worktree'" true
    (has_tool "masc_worktree_create" result)

let test_synonym_web_search () =
  let result = Tool_prefilter.filter
    ~tools:extended_tools ~query:"search the internet for information" ~k:3 in
  check bool "synonym: masc_web_search via 'search internet'" true
    (has_tool "masc_web_search" result)

(* ================================================================ *)
(* Tests: zero-result contract                                      *)
(* ================================================================ *)

let test_empty_query () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"" ~k:3 in
  check int "empty query returns []" 0 (List.length result)

let test_whitespace_query () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"   " ~k:3 in
  check int "whitespace query returns []" 0 (List.length result)

let test_disjoint_query () =
  let result = Tool_prefilter.filter
    ~tools:essential_tools ~query:"xyzzy foobar bazzle" ~k:3 in
  check int "disjoint query returns []" 0 (List.length result)

(* ================================================================ *)
(* Tests: edge cases                                                *)
(* ================================================================ *)

let test_k_exceeds_tools () =
  let small = [ make_schema "tool_a" "alpha"; make_schema "tool_b" "beta" ] in
  let result = Tool_prefilter.filter ~tools:small ~query:"alpha" ~k:100 in
  check bool "returns at most available non-zero tools" true
    (List.length result <= 2 && List.length result >= 1)

let test_single_tool () =
  let single = [ make_schema "masc_heartbeat" "heartbeat ping" ] in
  let result = Tool_prefilter.filter ~tools:single ~query:"heartbeat" ~k:5 in
  check int "single tool" 1 (List.length result);
  check string "correct tool" "masc_heartbeat" (List.hd result).name

let test_scores_descending () =
  let scored = Tool_prefilter.filter_with_scores
    ~tools:essential_tools ~query:"send heartbeat ping" ~k:5 in
  let scores = List.map snd scored in
  let rec is_sorted = function
    | [] | [_] -> true
    | a :: b :: rest -> a >= b && is_sorted (b :: rest)
  in
  check bool "scores descending" true (is_sorted scores)

let test_scores_positive () =
  let scored = Tool_prefilter.filter_with_scores
    ~tools:essential_tools ~query:"send heartbeat" ~k:5 in
  let all_positive = List.for_all (fun (_, s) -> s > 0.0) scored in
  check bool "all scores > 0" true all_positive

(* ================================================================ *)
(* Tests: synonym_text API                                          *)
(* ================================================================ *)

let test_synonym_text_known () =
  let text = Tool_prefilter.synonym_text "masc_dashboard" in
  check bool "non-empty for known tool" true (String.length text > 0);
  check string "expected synonyms"
    "happening activity overview summary monitor big picture" text

let test_synonym_text_unknown () =
  let text = Tool_prefilter.synonym_text "nonexistent_tool" in
  check string "empty for unknown" "" text

let test_synonym_text_enriches_description () =
  let base = "Render the MASC dashboard" in
  let enriched = base ^ " " ^ Tool_prefilter.synonym_text "masc_dashboard" in
  check bool "enriched longer than base" true
    (String.length enriched > String.length base)

let test_synonym_text_team_session_runtime_keywords () =
  let text = Tool_prefilter.synonym_text "masc_team_session_start" in
  check bool "team session synonyms include execution wording" true
    (contains_substring text "start supervised execution")

(* ================================================================ *)
(* Test runner                                                      *)
(* ================================================================ *)

let () =
  run "tool_prefilter"
    [
      ( "recall",
        [
          test_case "heartbeat in top-3" `Quick test_heartbeat_in_top3;
          test_case "broadcast in top-3" `Quick test_broadcast_in_top3;
          test_case "join in top-3" `Quick test_join_in_top3;
          test_case "add_task in top-3" `Quick test_add_task_in_top3;
        ] );
      ( "synonyms",
        [
          test_case "broadcast via synonym" `Quick test_synonym_broadcast;
          test_case "dashboard via synonym" `Quick test_synonym_dashboard;
          test_case "claim_next via synonym" `Quick test_synonym_claim_next;
          test_case "code_search via synonym" `Quick test_synonym_code_search;
          test_case "code_read via synonym" `Quick test_synonym_code_read;
          test_case "governance_status via synonym" `Quick test_synonym_governance_status;
          test_case "autoresearch_start via synonym" `Quick test_synonym_autoresearch_start;
          test_case "team_session_start via synonym" `Quick test_synonym_team_session_start;
          test_case "worktree_create via synonym" `Quick test_synonym_worktree_create;
          test_case "web_search via synonym" `Quick test_synonym_web_search;
        ] );
      ( "zero_result",
        [
          test_case "empty query" `Quick test_empty_query;
          test_case "whitespace query" `Quick test_whitespace_query;
          test_case "disjoint query" `Quick test_disjoint_query;
        ] );
      ( "edge_cases",
        [
          test_case "k exceeds tools" `Quick test_k_exceeds_tools;
          test_case "single tool" `Quick test_single_tool;
          test_case "scores descending" `Quick test_scores_descending;
          test_case "scores positive" `Quick test_scores_positive;
        ] );
      ( "synonym_text",
        [
          test_case "known tool returns keywords" `Quick test_synonym_text_known;
          test_case "unknown tool returns empty" `Quick test_synonym_text_unknown;
          test_case "enriches description" `Quick test_synonym_text_enriches_description;
          test_case "team session runtime keywords" `Quick
            test_synonym_text_team_session_runtime_keywords;
        ] );
    ]
