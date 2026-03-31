(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

open Keeper_types
open Keeper_memory

(** Case-insensitive substring check. Local copy to break
    Keeper_prompt -> Keeper_alerting -> Keeper_prompt cycle. *)
let contains_ci (haystack : string) (needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  if n = "" then false
  else Re.execp (Re.str n |> Re.compile) h

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

let render_required_prompt key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok value -> value
  | Error _ -> Prompt_registry.get_prompt key

let keeper_constitution () =
  Prompt_registry.get_prompt "keeper.constitution"

let build_keeper_system_prompt
    ~goal ~short_goal ~mid_goal ~long_goal ~soul_profile ~will ~needs ~desires
    ~instructions ?(persona_extended = "") () =
  let profile =
    canonical_soul_profile soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let goal = normalize_goal_horizon_text goal in
  let short_goal, mid_goal, long_goal =
    resolve_goal_horizons ~goal ~short_goal_opt:(Some short_goal)
      ~mid_goal_opt:(Some mid_goal) ~long_goal_opt:(Some long_goal)
  in
  let profile_policy = soul_profile_policy profile in
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
      Prompt_registry.get_prompt "keeper.world";
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
       Self model:\n\
       - Will: ";
      will;
      "\n\
       - Needs: ";
      needs;
      "\n\
       - Desires: ";
      desires;
      "\n\
       <capabilities>\n";
      Prompt_registry.get_prompt "keeper.capabilities";
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

let apply_self_model_drift
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(work_kind : string) : keeper_meta * bool * string option =
  ignore (user_message, work_kind);
  (meta, false, None)

let proactive_prompt_for_keeper
    ~(meta : keeper_meta)
    ~(idle_seconds : int)
    (snapshot : keeper_state_snapshot option)
    (continuity_summary : string) : string =
  let seed = proactive_seed_for_soul_profile meta.soul_profile in
  let profile =
    canonical_soul_profile meta.soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let last_preview =
    if String.trim meta.runtime.proactive_rt.last_preview = "" then "none"
    else meta.runtime.proactive_rt.last_preview
  in
  let continuity_snapshot =
    match snapshot with
    | None -> "No continuity snapshot available."
    | Some s -> keeper_state_snapshot_to_summary_text s
  in
  let continuity_snapshot =
    if continuity_snapshot = "No continuity snapshot available." then
      let fallback = String.trim continuity_summary in
      if fallback = "" then continuity_snapshot else fallback
    else continuity_snapshot
  in
  render_required_prompt "keeper.proactive_turn"
    [
      ("idle_seconds", string_of_int idle_seconds);
      ("profile", profile);
      ("goal", meta.goal);
      ("last_preview", last_preview);
      ("continuity_snapshot", continuity_snapshot);
      ("seed", seed);
    ]

type proactive_generation_result = {
  reply: string;
  usage: Agent_sdk.Types.api_usage;
  model_used: string;
  latency_ms: int;
  attempts: int;
  total_cost_usd: float;
  fallback_applied: bool;
  tools_used: string list;
}

let proactive_retry_instruction attempt ~(reason : string) =
  let attempt_phrase, directive =
    if attempt = 2 then
      ("previous attempt", "now with a clearly different angle.")
    else
      ( "previous attempts",
        "one decisive check-in now, materially different from the last preview." )
  in
  render_required_prompt "keeper.proactive_retry"
    [ ("attempt_phrase", attempt_phrase); ("reason", reason); ("directive", directive) ]

let proactive_temperature ~cascade_name attempt =
  let fallback () =
    if attempt <= 1 then Keeper_config.keeper_proactive_temperature_low ()
    else if attempt = 2 then Keeper_config.keeper_proactive_temperature_mid ()
    else Keeper_config.keeper_proactive_temperature_high ()
  in
  Cascade_inference.resolve_temperature ~cascade_name ~fallback

include Keeper_text_processing
