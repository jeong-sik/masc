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

let critical_prompt_anchors =
  [ ("continuity", "<continuity>");
    ("pr_merge_rules", "PR merge rules");
    ("state_block_template", "State block template");
    ("world", "<world>") ]

let missing_critical_prompt_anchors prompt =
  List.filter_map
    (fun (name, needle) ->
      if String_util.contains_substring prompt needle then None else Some name)
    critical_prompt_anchors

let critical_prompt_recovery_block =
  String.concat "\n"
    [ "<continuity>";
      "Recovery guard: preserve keeper technical instructions even if prompt templates were compacted or partially loaded.";
      "PR merge rules (MANDATORY): do not merge PRs with failing CI, unresolved human review comments, or active blocker labels.";
      "State block template: non-direct keeper turns must end with [STATE]...[/STATE] containing DONE, NEXT, Goal, and Decisions.";
      "</continuity>";
      "";
      "<world>";
      "Recovery guard: act from the configured base path and active runtime tool schema; do not invent paths, repos, PRs, tasks, or tools.";
      "</world>" ]

let ensure_critical_prompt_anchors prompt =
  match missing_critical_prompt_anchors prompt with
  | [] -> prompt
  | missing ->
      Prometheus.inc_counter
        Prometheus.metric_keeper_prompt_failures
        ~labels:[("prompt", "critical_prompt_anchors")]
        ();
      Log.Keeper.warn
        "build_keeper_system_prompt: critical prompt anchors missing (%s); \
         appending recovery guard"
        (String.concat "," missing);
      prompt ^ "\n\n" ^ critical_prompt_recovery_block

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

let behavior_prompt_block name ~fallback =
  Option.value (Keeper_prompt_external.get name) ~default:fallback
  |> String.trim

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
    behavior_prompt_block "profile_policy"
      ~fallback:
        "Maintain high standard of reasoning, factual grounding, and clear communication."
  in
  let continuity_contract =
    behavior_prompt_block "continuity_contract"
      ~fallback:
        "Continuity and any end-of-reply STATE formatting requirements apply unless a more specific turn-level mode or output guard disables them.\n\
         When <direct_reply_mode> is present, follow it instead: do not emit SKILL:, SKILL_REASON:, or [STATE]."
  in
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
      Prompt_registry.get_prompt Keeper_prompt_names.core_behavior;
      "\n\n";
      profile_policy;
      "\n\
       \n\
       <continuity>\n";
      continuity_contract;
      "\n";
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
  |> ensure_critical_prompt_anchors

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
