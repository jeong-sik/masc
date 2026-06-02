(** Verify filter_forward_looking_summary strips backward-looking fields
    (Done, Progress, Decisions) while preserving forward-looking fields
    (Goal, Next plan, Next, OpenQuestions, Constraints).

    Motivation: RFC-MASC-001 Phase 1 closed the messages-level [STATE]
    re-parse loop but the structured snapshot is rendered back to prose
    and re-injected into the next prompt verbatim, causing the LLM to
    echo its own prior narrative. Prompt assembly filters at injection
    time; persistence retains the full summary. *)

let full_summary =
  {|Goal: verify continuity hygiene
Done: previous turn reported 5.6B+ ep cross-validated across 30/30 episodes
Next plan: continue observation
Next: check retro-clean outcome; monitor keeper idle ratio; verify parse path
Decisions: 119/119 unclaimed tasks deemed trap cycles; autoboot stable
OpenQuestions: is Phase 2 needed?
Constraints: MASC_STRUCTURED_STATE=true|}

let inert_idle_summary =
  {|Goal: structural quality improvement
Next plan: stay silent until new actionable work appears
Next: 대기 유지; all non-destructive actions exhausted
OpenQuestions: none
Constraints: repos/ empty|}

let stale_tool_surface_summary =
  {|Goal: verify live tool policy
Next plan: use keeper_task_claim after checking live policy
Constraints: tool surface: masc_* only; no keeper_* tools visible
OpenQuestions: why did the previous turn see stale tools?|}

let test_strips_backward () =
  let filtered =
    Masc_mcp.Keeper_memory_policy.filter_forward_looking_summary full_summary
  in
  Alcotest.(check bool) "Done removed"
    false (String.length filtered >= 5 && Astring.String.is_infix ~affix:"Done:" filtered);
  Alcotest.(check bool) "Decisions removed"
    false (Astring.String.is_infix ~affix:"Decisions:" filtered);
  Alcotest.(check bool) "Progress removed (would be if present)"
    false (Astring.String.is_infix ~affix:"Progress:" filtered)

let test_keeps_forward () =
  let filtered =
    Masc_mcp.Keeper_memory_policy.filter_forward_looking_summary full_summary
  in
  Alcotest.(check bool) "Goal kept"
    true (Astring.String.is_infix ~affix:"Goal:" filtered);
  Alcotest.(check bool) "Next plan kept"
    true (Astring.String.is_infix ~affix:"Next plan:" filtered);
  Alcotest.(check bool) "Next kept"
    true (Astring.String.is_infix ~affix:"Next:" filtered);
  Alcotest.(check bool) "OpenQuestions kept"
    true (Astring.String.is_infix ~affix:"OpenQuestions:" filtered);
  Alcotest.(check bool) "Constraints kept"
    true (Astring.String.is_infix ~affix:"Constraints:" filtered)

let test_empty_input () =
  Alcotest.(check string) "empty stays empty"
    "" (Masc_mcp.Keeper_memory_policy.filter_forward_looking_summary "");
  Alcotest.(check string) "all-backward becomes empty"
    "" (Masc_mcp.Keeper_memory_policy.filter_forward_looking_summary
          "Done: work\nDecisions: choice\nProgress: 50%")

let test_preserves_line_order () =
  let filtered =
    Masc_mcp.Keeper_memory_policy.filter_forward_looking_summary full_summary
  in
  let lines = String.split_on_char '\n' filtered in
  (* Goal comes before Next plan which comes before Next in the original. *)
  let goal_idx =
    List.find_index
      (fun l -> Astring.String.is_prefix ~affix:"Goal:" (String.trim l))
      lines
  in
  let next_plan_idx =
    List.find_index
      (fun l -> Astring.String.is_prefix ~affix:"Next plan:" (String.trim l))
      lines
  in
  match (goal_idx, next_plan_idx) with
  | (Some gi, Some npi) ->
    Alcotest.(check bool) "Goal precedes Next plan" true (gi < npi)
  | _ ->
    Alcotest.fail "Expected Goal and Next plan lines to be present"

let test_drops_inert_idle_directives () =
  let filtered =
    Masc_mcp.Keeper_memory_policy.filter_forward_looking_summary
      inert_idle_summary
  in
  Alcotest.(check bool) "idle next plan removed"
    false (Astring.String.is_infix ~affix:"stay silent" filtered);
  Alcotest.(check bool) "idle next removed"
    false (Astring.String.is_infix ~affix:"대기 유지" filtered);
  Alcotest.(check bool) "goal still kept"
    true (Astring.String.is_infix ~affix:"Goal:" filtered);
  Alcotest.(check bool) "constraints still kept"
    true (Astring.String.is_infix ~affix:"Constraints:" filtered)

let test_drops_stale_tool_surface_claims () =
  let filtered =
    Masc_mcp.Keeper_memory_policy.filter_forward_looking_summary
      stale_tool_surface_summary
  in
  Alcotest.(check bool) "stale masc-only claim removed"
    false (Astring.String.is_infix ~affix:"masc_* only" filtered);
  Alcotest.(check bool) "stale missing keeper tools removed"
    false (Astring.String.is_infix ~affix:"no keeper_* tools" filtered);
  Alcotest.(check bool) "goal still kept"
    true (Astring.String.is_infix ~affix:"Goal:" filtered);
  Alcotest.(check bool) "live-policy action still kept"
    true (Astring.String.is_infix ~affix:"keeper_task_claim" filtered)

let () =
  Alcotest.run "continuity forward filter"
    [ ( "filter_forward_looking_summary",
        [ Alcotest.test_case "strips backward-looking fields" `Quick
            test_strips_backward;
          Alcotest.test_case "keeps forward-looking fields" `Quick
            test_keeps_forward;
          Alcotest.test_case "empty / all-backward → empty" `Quick
            test_empty_input;
          Alcotest.test_case "preserves relative line order" `Quick
            test_preserves_line_order;
          Alcotest.test_case "drops inert idle directives" `Quick
            test_drops_inert_idle_directives;
          Alcotest.test_case "drops stale tool surface claims" `Quick
            test_drops_stale_tool_surface_claims;
        ] );
    ]
