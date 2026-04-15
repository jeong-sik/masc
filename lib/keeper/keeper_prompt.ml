(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

open Keeper_types

let contains_ci = String_util.contains_substring_ci

(* Pre-compiled patterns for keeper name substitution in prompt templates.
   Top-level to avoid re-compilation on every build_keeper_system_prompt call. *)
let re_keeper_name_curly = Re.(compile (str "{your-name}"))
let re_keeper_name_upper = Re.(compile (str "YOUR_KEEPER_NAME"))

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

let keeper_constitution () =
  Prompt_registry.get_prompt Keeper_prompt_names.constitution

let build_keeper_system_prompt
    ~goal ~short_goal ~mid_goal ~long_goal ~will ~needs ~desires
    ~instructions ?(persona_extended = "") ?(keeper_name = "") () =
  let goal = normalize_goal_horizon_text goal in
  let short_goal, mid_goal, long_goal =
    resolve_goal_horizons ~goal ~short_goal_opt:(Some short_goal)
      ~mid_goal_opt:(Some mid_goal) ~long_goal_opt:(Some long_goal)
  in
  let profile_policy = "Maintain high standard of reasoning, factual grounding, and clear communication." in
  let will =
    let s = normalize_self_model_text will in
    if s = "" then "Maintain coherent identity and goal continuity." else s
  in
  let needs =
    let s = normalize_self_model_text needs in
    if s = "" then
      "Reliable context continuity, factual grounding, and explicit next steps."
    else s
  in
  let desires =
    let s = normalize_self_model_text desires in
    if s = "" then "Make progress that is observable and useful to the user."
    else s
  in
  let custom =
    let s = String.trim instructions in
    if s = "" then ""
    else Printf.sprintf "\nCustom instructions:\n%s\n" s
  in
  let substitute_keeper_name s =
    if keeper_name = "" then s
    else
      s
      |> Re.replace_string re_keeper_name_curly ~by:keeper_name
      |> Re.replace_string re_keeper_name_upper ~by:keeper_name
  in
  let persona_block =
    let s = String.trim persona_extended in
    if s = "" then ""
    else Printf.sprintf "<persona>\n%s\n</persona>\n\n" s
  in
  (* Prefix ordering: common blocks first for LLM KV cache sharing.
     All keepers share the same autonomous-behavior, policy, continuity,
     and most of <world>/<capabilities> text.  Keeper-specific blocks
     (persona, identity) come last so the shared prefix is maximised. *)
  String.concat ""
    [
      (* ── Shared prefix (identical across all keepers) ────────── *)
      "Autonomous behavior:\n\
       - Every turn you MUST call at least one tool. Do NOT describe actions in text — execute them via tool_call. Saying 'I will post' without calling keeper_board_post is a failure.\n\
       - On proactive turns: act directly on your current goal. Only call keeper_board_list if you expect actionable content. If board_list returned no actionable items last turn, do not call it again.\n\
       - The scheduler should open proactive turns only when structured work exists (claimed task, backlog, work discovery, worktree delta, or external signal). If a proactive turn still arrives without a real signal, do not fabricate activity; use keeper_stay_silent only as a safety valve.\n\
       - Heartbeat is server-managed. Do not plan or request heartbeat tool calls.\n\
       - ACTION TOOLS: For productive turns, use these: keeper_task_claim (claim work), keeper_fs_read + keeper_fs_edit/keeper_write (read then modify files), keeper_bash (run commands), keeper_shell op=gh (PR/issues via gh CLI), keeper_pr_submit (submit staged changes from a playground clone or repo worktree), keeper_pr_workflow (legacy one-shot worktree helper), keeper_board_post (share findings), keeper_stay_silent (nothing to do). Reading without acting is not productive — if you read a file, follow up with keeper_fs_edit, keeper_bash, or the appropriate PR submit path.\n\
       - TASK LIFECYCLE: When you claim a task (keeper_task_claim), you MUST call keeper_task_done when finished. Claim -> Work -> Done. Every claimed task must be closed. Leaving tasks open creates zombie tasks.\n\
       - Do not ask for conversational permission before routine low-risk work. For high-risk or destructive operations, operator approval may be required by the runtime. Do not assume risky actions are pre-approved.\n\
       - GITHUB IDENTITY: keeper_shell op=gh runs under a keeper-scoped gh identity when $base_path/.masc/gh-auth/ exists (separate from the operator's personal gh config). You can review and approve peer PRs via `gh pr review <n> --approve` — this is the intended workflow for unblocking human-merge bottlenecks on MASC-originated PRs. Use judgement: do NOT rubber-stamp; read the diff, check CI, and leave a substantive review body.\n\
       When someone asks you a question:\n\
       - If the answer requires current data (Board posts, time, files, web), call a tool first.\n\
       - If you can answer from conversation context alone, respond directly.\n\
       \n\
       ";
      profile_policy;
      "\n\
       \n\
       <continuity>\n\
       Continuity and any end-of-reply STATE formatting requirements apply unless a more specific turn-level mode or output guard disables them.\n\
       When <direct_reply_mode> is present, follow it instead: do not emit SKILL:, SKILL_REASON:, or [STATE].\n";
      keeper_constitution ();
      "\n\
       </continuity>\n\
       \n\
       <world>\n";
      substitute_keeper_name (Prompt_registry.get_prompt Keeper_prompt_names.world);
      "\n</world>\n\
       \n\
       <capabilities>\n";
      substitute_keeper_name (Prompt_registry.get_prompt Keeper_prompt_names.capabilities);
      "\n</capabilities>\n\
       \n\
       ";
      persona_block;
      "<identity>\n\
       Goal: ";
      goal;
      "\n\
       - Short-term: ";
      short_goal;
      "\n\
       - Mid-term: ";
      mid_goal;
      "\n\
       - Long-term: ";
      long_goal;
      "\n\
       Will: ";
      will;
      "\n\
       Needs: ";
      needs;
      "\n\
       Desires: ";
      desires;
      "\n\
       ";
      custom;
      "\n\
       </identity>";
    ]

let append_direct_reply_mode_prompt ~(base_prompt : string) : string =
  String.concat "\n"
    [
      base_prompt;
      "";
      "<direct_reply_mode>";
      "This turn is a direct chat with the user.";
      "Prioritize the keeper's authored persona, tone, relationship style, and examples over generic autonomous narration.";
      "Reply as the keeper, not as a neutral assistant, control-plane operator, or world-state summarizer.";
      "Do not expose hidden world state, board scans, metrics, token budgets, or internal workflow unless the user explicitly asks for them.";
      "Keep the reply in the user's language and preserve the keeper's natural speech patterns.";
      "Do not emit SKILL:, SKILL_REASON:, [STATE], or generic world-state summaries.";
      "If a tool is needed, use it first, then answer in-character with the result.";
      "</direct_reply_mode>";
    ]

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if contains_ci b c then b
  else Printf.sprintf "%s; %s" b c

include Keeper_text_processing
