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

(** Format a string list for prompt rendering. Empty list -> "(none)". *)
let format_list_for_prompt (items : string list) : string =
  match items with
  | [] -> "(none)"
  | xs -> String.concat ", " xs

(** Resolve the <world> prompt with git_clone allow/deny lists injected
    as template variables.  The caller supplies the lists (pulled from
    [Keeper_tool_policy]); keeping them as arguments avoids a dependency
    cycle between [Keeper_prompt] and [Keeper_tool_policy].  Falls back
    to the raw template text if rendering fails so that prompt wiring
    bugs do not brick keepers — but the fallback is now logged loudly so
    the silent-degradation case documented in #9893 becomes observable. *)
let render_world_prompt ~allowed_orgs ~denied_repos : string =
  let vars =
    [
      ("allowed_orgs", format_list_for_prompt allowed_orgs);
      ("denied_repos", format_list_for_prompt denied_repos);
    ]
  in
  match
    Prompt_registry.render_prompt_template Keeper_prompt_names.world vars
  with
  | Ok rendered -> rendered
  | Error msg ->
      Log.Keeper.warn
        "render_world_prompt: template render failed, falling back to raw \
         template (keepers may see unrendered placeholders): %s"
        msg;
      Prompt_registry.get_prompt Keeper_prompt_names.world

let build_keeper_system_prompt
    ~goal ~short_goal ~mid_goal ~long_goal ~will ~needs ~desires
    ~instructions ?(persona_extended = "") ?(keeper_name = "")
    ?(allowed_orgs = []) ?(denied_repos = [])
    ?(active_goals = []) () =
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
  let active_goals_block =
    match active_goals with
    | [] -> ""
    | goals ->
        let lines =
          List.map
            (fun (id, title, horizon) ->
               Printf.sprintf "- %s [%s] %s" id horizon title)
            goals
        in
        Printf.sprintf "\n<available_goals>\n%s\n</available_goals>\n"
          (String.concat "\n" lines)
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
       - ACTION TOOLS: For productive turns, use these: keeper_task_claim (claim work), keeper_fs_read + keeper_fs_edit/keeper_write (read then modify files), keeper_bash (run commands inside your sandbox; use for git add/commit/push, file ops, rg, etc.), keeper_shell op=gh (ALL GitHub CLI ops - gh pr create/view/review, gh issue list, gh api, etc. NEVER use keeper_bash for gh commands), keeper_shell op=git_clone (clone repos into your workspace), keeper_board_post (share findings), keeper_stay_silent (nothing to do). Reading without acting is not productive — if you read a file, follow up with keeper_fs_edit, keeper_bash, or the appropriate gh step.\n\
       \n";
      Printf.sprintf
        "       - PASSIVE READS ALONE ARE NOT ENOUGH on actionable-signal turns. \
         Status/list/get/search/time/read-only shell calls are observation only; \
         the strict tool-use contract requires an active state-changing tool \
         (keeper_task_claim, keeper_fs_edit, keeper_bash, keeper_shell op=gh, \
         keeper_board_post, or similar) unless you explicitly skip with \
         keeper_stay_silent.\n\
         \n";
      "       - SANDBOX PATHS: keeper_bash runs inside a Docker container. Your workspace is /home/keeper/playground/<your-name>/. Do NOT use host paths (e.g. /Users/...) in keeper_bash - use relative paths or the container workspace path. Repos cloned via keeper_shell op=git_clone appear under this workspace. For any operation needing network access (gh, curl, git push/pull), use keeper_shell op=gh or keeper_shell op=git_clone instead of keeper_bash.\n\
       - TASK LIFECYCLE: When you claim a task (keeper_task_claim), you MUST close it before ending the work. For normal terminal work, call keeper_task_done. For code/PR work that needs review, call keeper_task_submit_for_verification with notes + pr_url instead of done. If active_goal_ids are configured, keeper_task_claim only returns goal-linked tasks.\n\
       - Do not ask for conversational permission before routine low-risk work. For high-risk or destructive operations, operator approval may be required by the runtime. Do not assume risky actions are pre-approved.\n\
       - GITHUB IDENTITY: keeper_shell op=gh runs under a keeper-scoped gh identity. A keeper bound to github_identity uses $base_path/.masc/github-identities/<identity>/gh and MUST NOT fall back to the operator's personal gh config. In hard sandbox mode, github_identity is mandatory and raw `gh` through keeper_bash is blocked; use keeper_shell op=gh. Outside hard mode, unbound keepers may still use the legacy $base_path/.masc/gh-auth/ bundle when present. You can review and approve peer PRs via `gh pr review <n> --approve` — this is the intended workflow for unblocking human-merge bottlenecks on MASC-originated PRs. Use judgement: do NOT rubber-stamp; read the diff, check CI, and leave a substantive review body.\n\
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
      substitute_keeper_name
        (render_world_prompt ~allowed_orgs ~denied_repos);
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
      active_goals_block;
      "</identity>";
    ]

(* XML wrapping stays in code — it is structure, not prompt content. *)
let direct_reply_mode_body () =
  Prompt_registry.get_prompt Keeper_prompt_names.reply_guidelines

let append_direct_reply_mode_prompt ~(base_prompt : string) : string =
  String.concat "\n"
    [
      base_prompt;
      "";
      "<direct_reply_mode>";
      String.trim (direct_reply_mode_body ());
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
