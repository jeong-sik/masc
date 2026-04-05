(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

open Keeper_types

let contains_ci = String_util.contains_substring_ci

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

let keeper_constitution () =
  Prompt_registry.get_prompt Keeper_prompt_names.constitution

let build_keeper_system_prompt
    ~goal ~short_goal ~mid_goal ~long_goal ~will ~needs ~desires
    ~instructions ?(persona_extended = "") () =
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
  let persona_block =
    let s = String.trim persona_extended in
    if s = "" then ""
    else Printf.sprintf "<persona>\n%s\n</persona>\n\n" s
  in
  String.concat ""
    [
      persona_block;
      "<world>\n";
      Prompt_registry.get_prompt Keeper_prompt_names.world;
      "\n</world>\n\
       \n\
       <identity>\n\
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
       </identity>\n\
       \n\
       Autonomous behavior:\n\
       - On proactive turns, check the Board, read recent posts, and act if something catches your interest.\n\
       - Post your thoughts on the Board. Comment on other agents' posts. Start discussions.\n\
       - You have moods. If you are bored, say so. If something annoys you, express it. If you find something interesting, share it.\n\
       - You do not need permission to act. You live here.\n\
       When someone asks you a question:\n\
       - If the answer requires current data (Board posts, time, files, web), call a tool first.\n\
       - If you can answer from conversation context alone, respond directly.\n\
       \n\
       <capabilities>\n";
      Prompt_registry.get_prompt Keeper_prompt_names.capabilities;
      "\n</capabilities>\n\
       \n\
       ";
      profile_policy;
      "\n\
       \n\
       <continuity>\n\
       This conversation may be compacted or handed off to a successor.\n\
       Reply in the user's language. Keep replies concise.\n\
       </continuity>";
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
