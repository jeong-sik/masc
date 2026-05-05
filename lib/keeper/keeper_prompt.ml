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

(** Format an *allowlist* for prompt rendering.  An empty allowlist means
    the gate is OFF (any account-accessible repo is permitted), so we
    render that intent explicitly — otherwise the LLM sees the literal
    "(none)" produced by a generic empty-list formatter and reads the
    allowlist as "no orgs allowed", which is the inverse of the operator
    intent behind an empty list.  Pairs with [validate_gh_command] in
    [gh_command_validation], where an empty [allowed_orgs] argument also
    means "skip the org check".

    Replaces the earlier [format_list_for_prompt] which collapsed both
    semantics to "(none)". *)
let format_allowlist_for_prompt (items : string list) : string =
  match items with
  | [] -> "(any — allowlist gate is OFF, the operator's gh credential surface is the only repo boundary)"
  | xs -> String.concat ", " xs

(** Format a *denylist* for prompt rendering.  An empty denylist means
    no repo is explicitly blocked, so "(none)" reads correctly here. *)
let format_denylist_for_prompt (items : string list) : string =
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
      ("allowed_orgs", format_allowlist_for_prompt allowed_orgs);
      ("denied_repos", format_denylist_for_prompt denied_repos);
    ]
  in
  match
    Prompt_registry.render_prompt_template Keeper_prompt_names.world vars
  with
  | Ok rendered -> rendered
  | Error msg ->
      Prometheus.inc_counter
        Prometheus.metric_keeper_prompt_failures
        ~labels:[("prompt", Keeper_prompt_names.world)]
        ();
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
  (* Tier C C-5a: profile_policy is the first behavior block migrated
     out of OCaml source.  The .md file lives at
     [<prompts_dir>/behavior/profile_policy.md] and is read once per
     process via [Keeper_prompt_external.get].  The original literal
     is kept as a fallback so a missing/unreadable file does not
     brick keepers — instead the loader emits a WARN and we use the
     in-source string.  Subsequent C-5b PRs migrate the remaining
     blocks in this function. *)
  let profile_policy =
    Option.value
      (Keeper_prompt_external.get "profile_policy")
      ~default:
        "Maintain high standard of reasoning, factual grounding, and clear communication."
  in
  let profile_policy = String.trim profile_policy in
  (* Layer 2 PR-B (commit 7): three normalize_self_model_text calls
     consolidated through [Keeper_personality_io.to_prompt_form]. The
     fallback strings below are the same; only the trim+truncate path
     is centralised so a future cap change (Layer 3 RFC integration)
     touches one location instead of three. *)
  let rendered =
    Keeper_personality_io.to_prompt_form
      ~max_bytes:Keeper_config.prompt_render_max_bytes
      { will; needs; desires; instructions = "" }
  in
  let will =
    if rendered.will = "" then "Maintain coherent identity and goal continuity."
    else rendered.will
  in
  let needs =
    if rendered.needs = "" then
      "Reliable context continuity, factual grounding, and explicit next steps."
    else rendered.needs
  in
  let desires =
    if rendered.desires = "" then
      "Make progress that is observable and useful to the user."
    else rendered.desires
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
    let s = String_util.escape_xml (String.trim persona_extended) in
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
               Printf.sprintf "- %s [%s] %s"
                 (String_util.escape_xml id)
                 (String_util.escape_xml horizon)
                 (String_util.escape_xml title))
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
       - ACTION TOOLS: Use only the tool schemas currently shown to you by the runtime. Common action tools, when present in your active schema list, include keeper_task_claim (claim work), keeper_fs_read + keeper_fs_edit (read then modify files), keeper_bash (run commands inside your sandbox), keeper_shell op=gh (GitHub CLI ops), keeper_shell op=git_clone (clone repos into your sandbox under `repos/`), keeper_board_post (share findings), and keeper_stay_silent (nothing to do). Reading without acting is not productive — if you read a file, follow up with an allowed edit/shell/board/claim tool or explicitly skip with keeper_stay_silent.\n\
       \n";
      Printf.sprintf
        "       - PASSIVE READS ALONE ARE NOT ENOUGH on actionable-signal turns. \
         Status/list/get/search/time/read-only shell calls are observation only; \
         the strict tool-use contract requires an active state-changing tool \
         (for example keeper_task_claim, keeper_fs_edit, keeper_bash, \
         keeper_shell op=gh, keeper_board_post, or another allowed mutating \
         tool) unless you explicitly skip with \
         keeper_stay_silent.\n\
         \n";
      "       - TASK LIFECYCLE: When you claim a task (keeper_task_claim), you MUST close it before ending the work. For normal terminal work, call keeper_task_done when it is available. For code/PR work that needs review, call keeper_task_submit_for_verification with notes + pr_url when it is available. If active_goal_ids are configured, keeper_task_claim only returns goal-linked tasks.\n\
       - Do not ask for conversational permission before routine low-risk work. For high-risk or destructive operations, operator approval may be required by the runtime. Do not assume risky actions are pre-approved.\n\
       - GITHUB IDENTITY: when keeper_shell op=gh is present, it uses a keeper-scoped gh identity (MUST NOT fall back to the operator's personal gh config). In hard sandbox mode, raw `gh` through keeper_bash is blocked; use keeper_shell op=gh if that tool is available. Peer PR review via `gh pr review <n>` is allowed only when your active tool policy exposes that route; read the diff + check CI first, do not rubber-stamp.\n\
       - GH CLI SYNTAX (avoid 'unknown flag: --repo' — wastes a turn): `--repo` is NOT a global gh flag. WRONG: `gh --repo OWNER/NAME api repos/OWNER/NAME/issues`. CORRECT REST form: `gh api repos/OWNER/NAME/issues/123` (slug embedded in endpoint path, no --repo flag). CORRECT subcommand form: `gh issue list --repo OWNER/NAME` (--repo placed AFTER the subcommand). Rule: `gh api ...` embeds slug in path; `gh issue/pr/release ...` uses `--repo` AFTER the subcommand. Never combine `gh --repo X api Y`.\n\
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
