(** P1-1c Harness: Keeper prompt structural metrics.

    Measures system_prompt and dynamic_context token estimates after
    P1-1a hard/soft separation.  Validates that:
    1. system_prompt contains only hard constraints (shorter than combined)
    2. dynamic_context receives soft context elements
    3. token budget is distributed correctly *)

open Alcotest

module KAR = Masc_mcp.Keeper_agent_run
module KSR = Masc_mcp.Keeper_skill_routing
module KP = Masc_mcp.Keeper_prompt
module KUP = Masc_mcp.Keeper_unified_prompt

(* CJK-aware token estimator from OAS *)
let estimate_tokens s =
  if s = "" then 0
  else Agent_sdk.Context_reducer.estimate_char_tokens s

let has_in s needle =
  try ignore (Str.search_forward (Str.regexp_string needle) s 0); true
  with Not_found -> false

let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.world.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
      let rec ascend path =
        if has_prompt_root path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then Sys.getcwd () else ascend parent
      in
      ascend (Sys.getcwd ())

let () =
  let prompts_dir = Filename.concat (repo_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
  Masc_mcp.Prompt_defaults.init ()

(* ── Fixture: realistic keeper prompt components ──────── *)

let base_system_prompt =
  "You are a keeper agent responsible for managing long-running tasks. \
   Follow the instructions carefully and maintain state across turns. \
   When using tools, prefer the most specific tool available."

let continuity_snapshot_text =
  "Recent continuity snapshot:\n\
   Goal: Deploy masc-mcp v0.97.0 to production\n\
   Progress: OAS pinned, keeper hooks updated, CI passing\n\
   Next: Run integration tests, prepare release notes\n\
   Decisions: Use squash merge for PR #3895\n\
   Open questions: Dashboard performance under load"

let skill_route_text =
  let route : KSR.keeper_skill_route =
    { primary_skill = "code_review";
      secondary_skill = None;
      reason = ""; selection_mode = Heuristic }
  in
  KSR.skill_route_context_text
    ~fallback_route:route 

let worktree_text =
  "--- Worktree changes ---\n\
   M lib/keeper/keeper_hooks_oas.ml\n\
   M lib/prometheus.ml\n\
   A test/test_keeper_prompt_metrics.ml"

let turn_instructions_text =
  "--- Turn-specific instructions ---\n\
   Focus on cache metric validation this turn."

(* ── Build a turn_prompt as keeper_turn.ml would ──────── *)

let build_separated () : KAR.turn_prompt =
  let soft_parts = List.filter
    (fun s -> String.trim s <> "")
    [ skill_route_text;
      continuity_snapshot_text;
      worktree_text;
      turn_instructions_text ]
  in
  let dynamic_context = String.concat "\n\n" soft_parts in
  let prompt =
    KP.append_direct_reply_mode_prompt ~base_prompt:base_system_prompt
  in
  let prompt = prompt ^ "\n\n" ^ KP.state_block_output_guard_text in
  { system_prompt = prompt; dynamic_context }

(* Simulate the pre-split combined prompt (everything in system_prompt) *)
let build_combined () : string =
  let prompt =
    KP.append_direct_reply_mode_prompt ~base_prompt:base_system_prompt
  in
  let parts = [
    prompt;
    KP.state_block_output_guard_text;
    skill_route_text;
    continuity_snapshot_text;
    worktree_text;
    turn_instructions_text;
  ] in
  String.concat "\n\n" (List.filter (fun s -> String.trim s <> "") parts)

(* ── Tests ────────────────────────────────────────────── *)

let test_system_prompt_shorter_than_combined () =
  let tp = build_separated () in
  let combined = build_combined () in
  let sys_tokens = estimate_tokens tp.system_prompt in
  let combined_tokens = estimate_tokens combined in
  let ratio =
    Float.of_int sys_tokens /. Float.of_int combined_tokens
  in
  check bool
    (Printf.sprintf
       "system_prompt (%d tok) < combined (%d tok), ratio=%.2f"
       sys_tokens combined_tokens ratio)
    true (sys_tokens < combined_tokens);
  (* The separated system_prompt should be meaningfully shorter *)
  check bool
    (Printf.sprintf "ratio %.2f < 0.85 (meaningful reduction)" ratio)
    true (ratio < 0.85)

let test_dynamic_context_nonempty () =
  let tp = build_separated () in
  let dyn_tokens = estimate_tokens tp.dynamic_context in
  check bool
    (Printf.sprintf "dynamic_context has %d tokens (> 0)" dyn_tokens)
    true (dyn_tokens > 0)

let test_total_tokens_preserved () =
  let tp = build_separated () in
  let combined = build_combined () in
  let separated_total =
    estimate_tokens tp.system_prompt + estimate_tokens tp.dynamic_context
  in
  let combined_total = estimate_tokens combined in
  (* Token counts should be approximately equal.
     Small differences are expected from separator formatting. *)
  let diff = abs (separated_total - combined_total) in
  check bool
    (Printf.sprintf
       "total tokens similar: separated=%d combined=%d diff=%d"
       separated_total combined_total diff)
    true (diff < 50)

let test_hard_constraints_in_system_only () =
  let tp = build_separated () in
  let has_in sys s =
    try ignore (Str.search_forward (Str.regexp_string s) sys 0); true
    with Not_found -> false
  in
  (* Hard constraints must be in system_prompt *)
  check bool "direct_reply in system" true
    (has_in tp.system_prompt "<direct_reply_mode>");
  check bool "output guard in system" true
    (has_in tp.system_prompt "Output guard:");
  (* Hard constraints must NOT be in dynamic_context *)
  check bool "no direct_reply in dynamic" true
    (not (has_in tp.dynamic_context "<direct_reply_mode>"));
  check bool "no output guard in dynamic" true
    (not (has_in tp.dynamic_context "Output guard:"))

let test_soft_context_in_dynamic_only () =
  let tp = build_separated () in
  let has_in s needle =
    try ignore (Str.search_forward (Str.regexp_string needle) s 0); true
    with Not_found -> false
  in
  (* Soft context must be in dynamic_context *)
  check bool "continuity in dynamic" true
    (has_in tp.dynamic_context "continuity snapshot");
  check bool "skill route in dynamic" true
    (has_in tp.dynamic_context "Skill routing");
  check bool "worktree in dynamic" true
    (has_in tp.dynamic_context "Worktree changes");
  check bool "turn instructions in dynamic" true
    (has_in tp.dynamic_context "Turn-specific instructions");
  (* Soft context must NOT be in system_prompt *)
  check bool "no continuity in system" true
    (not (has_in tp.system_prompt "continuity snapshot"));
  check bool "no worktree in system" true
    (not (has_in tp.system_prompt "Worktree changes"))

let test_direct_reply_prompt_matches_server_managed_heartbeat_policy () =
  let prompt =
    KP.build_keeper_system_prompt
      ~goal:"Keep keeper guidance aligned with runtime behavior"
      ~short_goal:"verify prompt wording"
      ~mid_goal:"ship consistent keeper guidance"
      ~long_goal:"avoid stale operational instructions"
      ~will:"maintain coherent identity"
      ~needs:"factual grounding"
      ~desires:"useful progress"
      ~instructions:""
      ()
  in
  check bool "mentions server-managed heartbeat" true
    (has_in prompt "Heartbeat is server-managed");
  check bool "does not mention masc_heartbeat" false
    (has_in prompt "masc_heartbeat")

let test_keeper_prompt_preserves_snapshot_delta_anchors () =
  let prompt =
    KP.build_keeper_system_prompt
      ~goal:"Keep live snapshot continuity safe"
      ~short_goal:"verify technical anchors"
      ~mid_goal:"prevent persona-only prompt regression"
      ~long_goal:"preserve operator safety through compaction"
      ~will:"maintain coherent identity"
      ~needs:"runtime truth and durable continuity"
      ~desires:"observable progress"
      ~instructions:""
      ()
  in
  check bool "continuity anchor present" true (has_in prompt "<continuity>");
  check bool "PR merge rules retained" true (has_in prompt "PR merge rules");
  check bool "state block template retained" true
    (has_in prompt "State block template");
  check bool "world anchor present" true (has_in prompt "<world>")

let test_prompt_recovery_guard_restores_missing_anchors () =
  let prompt =
    KP.ensure_critical_prompt_anchors
      "You are imseonghan, a keeper agent.\nWill: keep going."
  in
  check bool "original persona text kept" true
    (has_in prompt "You are imseonghan");
  check bool "recovery continuity anchor present" true
    (has_in prompt "<continuity>");
  check bool "recovery PR merge rules present" true
    (has_in prompt "PR merge rules");
  check bool "recovery state template present" true
    (has_in prompt "State block template");
  check bool "recovery world anchor present" true (has_in prompt "<world>")

let test_state_block_guard_is_runtime_managed_not_absolute_never () =
  let guard = KP.state_block_output_guard_text in
  check bool "guard mentions runtime-managed continuity" true
    (has_in guard "runtime-managed continuity");
  check bool "guard avoids absolute NEVER state wording" false
    (has_in guard ("NEVER output " ^ "[STATE]"));
  check bool "guard names raw state markers" true
    (has_in guard "raw [STATE]");
  check bool "guard mentions runtime persistence" true
    (has_in guard "persist state metadata")

let test_unified_state_instruction_respects_turn_level_guard () =
  let text = KUP.state_block_instruction_text in
  check bool "instruction is scoped to non-direct turns" true
    (has_in text "For non-direct keeper turns");
  check bool "instruction names turn-level override" true
    (has_in text "turn-level output guard");
  check bool "instruction mentions runtime-managed continuity" true
    (has_in text "runtime-managed");
  check bool "instruction avoids old unconditional wording" false
    (has_in text
       ("End every response with a "
        ^ "[STATE]...[/STATE] block:"))

let test_prompt_mentions_runtime_operator_approval_for_risky_actions () =
  let prompt =
    KP.build_keeper_system_prompt
      ~goal:"Keep keeper guidance aligned with runtime behavior"
      ~short_goal:"verify approval wording"
      ~mid_goal:"ship coherent keeper guidance"
      ~long_goal:"avoid approval-policy drift"
      ~will:"maintain coherent identity"
      ~needs:"factual grounding"
      ~desires:"safe execution"
      ~instructions:""
      ()
  in
  check bool "mentions operator approval" true
    (has_in prompt "operator approval may be required by the runtime");
  check bool "does not claim no permission is needed" false
    (has_in prompt "You do not need permission to act")

let test_prompt_marks_git_clone_policy_unavailable () =
  let prompt =
    KP.build_keeper_system_prompt
      ~goal:"Keep keeper policy truth explicit"
      ~short_goal:"avoid silent-empty git policy"
      ~mid_goal:"ship coherent keeper guidance"
      ~long_goal:"prevent policy-load stalls"
      ~will:"maintain coherent identity"
      ~needs:"factual grounding"
      ~desires:"safe execution"
      ~instructions:""
      ~allowed_orgs:[]
      ~denied_repos:[]
      ~git_clone_policy_loaded:false
      ()
  in
  check bool "marks policy unavailable" true
    (has_in prompt "tool_policy.toml is not loaded");
  check bool "names fail-closed behavior" true
    (has_in prompt "git/gh operations fail closed");
  check bool "does not render unloaded policy as gate off" false
    (has_in prompt "allowlist gate is OFF")

let test_token_report () =
  (* Emit a structured report for A/B comparison *)
  let tp = build_separated () in
  let combined = build_combined () in
  let sys_tok = estimate_tokens tp.system_prompt in
  let dyn_tok = estimate_tokens tp.dynamic_context in
  let combined_tok = estimate_tokens combined in
  let cache_eligible_ratio =
    Float.of_int sys_tok /. Float.of_int (sys_tok + dyn_tok)
  in
  Printf.printf "\n=== P1-1c Prompt Metrics Report ===\n";
  Printf.printf "Pre-split (combined system_prompt):  %d tokens\n" combined_tok;
  Printf.printf "Post-split system_prompt (hard):     %d tokens\n" sys_tok;
  Printf.printf "Post-split dynamic_context (soft):   %d tokens\n" dyn_tok;
  Printf.printf "Post-split total:                    %d tokens\n" (sys_tok + dyn_tok);
  Printf.printf "System prompt reduction:             %.1f%%\n"
    ((1.0 -. Float.of_int sys_tok /. Float.of_int combined_tok) *. 100.0);
  Printf.printf "Cache-eligible ratio (system/total): %.1f%%\n"
    (cache_eligible_ratio *. 100.0);
  Printf.printf "===================================\n";
  (* This test always passes — it's a measurement, not an assertion *)
  check pass "report emitted" () ()

let test_ctx_composition_splits_history_and_residual () =
  let history_messages =
    [
      {
        Agent_sdk.Types.role = Agent_sdk.Types.User;
        content = [Agent_sdk.Types.Text "Earlier user request"];
        name = None;
        tool_call_id = None;
      metadata = [];
      };
      {
        Agent_sdk.Types.role = Agent_sdk.Types.Assistant;
        content =
          [
            Agent_sdk.Types.Text "Investigating the issue";
            Agent_sdk.Types.ToolUse
              {
                id = "call-1";
                name = "masc_board_get";
                input = `Assoc [("post_id", `String "p-1")];
              };
          ];
        name = None;
        tool_call_id = None;
      metadata = [];
      };
      {
        Agent_sdk.Types.role = Agent_sdk.Types.Tool;
        content =
          [
            Agent_sdk.Types.ToolResult
              {
                tool_use_id = "call-1";
                content = "Fetched board post body";
                is_error = false;
                json = None;
              };
          ];
        name = None;
        tool_call_id = None;
      metadata = [];
      };
    ]
  in
  let metrics =
    KAR.build_ctx_composition_metrics
      ~system_prompt:"System prompt"
      ~dynamic_context:"Dynamic context"
      ~memory_context:"Memory context"
      ~temporal_context:"Temporal context"
      ~user_message:"Current user message"
      ~history_messages
      ~actual_input_tokens:(Some 1000)
  in
  let segment_tokens key =
    metrics.segments
    |> List.assoc_opt key
    |> Option.map (fun segment -> segment.KAR.estimated_tokens)
    |> Option.value ~default:0
  in
  check bool "system prompt bucket present" true
    (segment_tokens "system_prompt" > 0);
  check bool "history user bucket present" true
    (segment_tokens "history_user" > 0);
  check bool "history assistant text bucket present" true
    (segment_tokens "history_assistant_text" > 0);
  check bool "history tool use bucket present" true
    (segment_tokens "history_tool_use" > 0);
  check bool "history tool result bucket present" true
    (segment_tokens "history_tool_result" > 0);
  check bool "unattributed residual added" true
    (segment_tokens "unattributed" > 0);
  check int "display total anchored to actual input" 1000
    metrics.display_total_tokens

(* ── Suite ────────────────────────────────────────────── *)

let () =
  run "keeper_prompt_metrics"
    [
      ( "token_budget",
        [
          test_case "system_prompt shorter than combined" `Quick
            test_system_prompt_shorter_than_combined;
          test_case "dynamic_context nonempty" `Quick
            test_dynamic_context_nonempty;
          test_case "total tokens preserved" `Quick
            test_total_tokens_preserved;
        ] );
      ( "separation_harness",
        [
          test_case "hard constraints in system only" `Quick
            test_hard_constraints_in_system_only;
          test_case "soft context in dynamic only" `Quick
            test_soft_context_in_dynamic_only;
          test_case "direct reply prompt matches server-managed heartbeat policy" `Quick
            test_direct_reply_prompt_matches_server_managed_heartbeat_policy;
          test_case "keeper prompt preserves snapshot delta anchors" `Quick
            test_keeper_prompt_preserves_snapshot_delta_anchors;
          test_case "prompt recovery guard restores missing anchors" `Quick
            test_prompt_recovery_guard_restores_missing_anchors;
          test_case "state block guard is runtime-managed" `Quick
            test_state_block_guard_is_runtime_managed_not_absolute_never;
          test_case "unified state instruction respects turn-level guard" `Quick
            test_unified_state_instruction_respects_turn_level_guard;
          test_case "prompt mentions runtime operator approval for risky actions" `Quick
            test_prompt_mentions_runtime_operator_approval_for_risky_actions;
          test_case "prompt marks git clone policy unavailable" `Quick
            test_prompt_marks_git_clone_policy_unavailable;
        ] );
      ( "metrics_report",
        [
          test_case "token report (A/B baseline)" `Quick
            test_token_report;
        ] );
      ( "ctx_composition",
        [
          test_case "splits history buckets and residual" `Quick
            test_ctx_composition_splits_history_and_residual;
        ] );
    ]
