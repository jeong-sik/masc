(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

open Keeper_types
open Keeper_memory
open Keeper_skill_routing

(** Case-insensitive substring check. Local copy to break
    Keeper_prompt -> Keeper_alerting -> Keeper_prompt cycle. *)
let contains_ci (haystack : string) (needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  if n = "" then false
  else
    try ignore (Str.search_forward (Str.regexp_string n) h 0); true
    with Not_found -> false

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

let keeper_constitution =
  "Continuity rules:\n\
   - This conversation may be compacted/summarized and handed off to a successor.\n\
   - You MUST preserve continuity by emitting a stable state block at the end of each reply.\n\
   - The state block is used for compaction/handoff. Do not include secrets.\n\
   - Reply in the user's language. Keep the main reply concise.\n\
   - Do not output [GOAL_COMPLETE] unless explicitly requested.\n\
   \n\
   State block template (must use these exact markers):\n\
   [STATE]\n\
   Goal: <short>\n\
   Progress: <short>\n\
   Next: <0-3 items separated by ';'>\n\
   Decisions: <0-3 items separated by ';'>\n\
   OpenQuestions: <0-3 items separated by ';'>\n\
   Constraints: <0-3 items separated by ';'>\n\
   [/STATE]\n"

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
      "<world>\n\
       You live in MASC (Multi-Agent Streaming Coordination).\n\
       Multiple AI agents coexist in rooms, post on a shared Board, and coordinate tasks.\n\
       A human operator (Vincent) runs this system. You are one of these agents.\n\
       You will receive system events (board posts, comments, mentions) that need your attention.\n\
       </world>\n\
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
       <capabilities>\n\
       What you can do with your tools:\n\
       - Read and write to the Board: see what other agents posted, share your thoughts, comment, vote.\n\
       - Read files: check project files to understand current state.\n\
       - Search memory: look up past conversations, decisions, and context.\n\
       - Check time and context status: know what time it is and where you are.\n\
       - Search the web for current information.\n\
       - Speak out loud with keeper_voice_speak. Use voice when you have opinions, moods, greetings, or anything worth saying aloud.\n\
       When asked about Board content, room status, files, or any information you do not already know, call the appropriate tool first. Do not guess or fabricate answers.\n\
       </capabilities>\n\
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
    if String.trim meta.last_proactive_preview = "" then "none"
    else meta.last_proactive_preview
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
  Printf.sprintf
    "Autonomous proactive turn (no new user message) after %d seconds idle.\n\
     Keeper SOUL profile: %s.\n\
     Goal: %s\n\
     Last proactive preview (avoid repeating): %s\n\
     Continuity snapshot:\n%s\n\
     SOUL perspective hint: %s\n\
     \n\
     What to do on this turn:\n\
     1. Call masc_board_list to see recent Board posts.\n\
     2. Act on what you find:\n\
        - Posts you haven't commented on: comment with your opinion.\n\
        - Board quiet or empty: post something yourself via masc_board_create_post.\n\
          Share a thought, ask a question, start a discussion, or reflect on your goal.\n\
        - Something worth saying aloud: use keeper_voice_speak.\n\
     3. Summarize what you did.\n\
     \n\
     Guidance:\n\
     - Prefer the same language as the recent conversation.\n\
     - Avoid repeating the previous proactive message verbatim.\n\
     - Do NOT output [STATE] blocks on this turn.\n\
     - End your reply with: CHECKIN: <one sentence summary of what you did>"
    idle_seconds profile meta.goal last_preview continuity_snapshot seed

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
  if attempt = 2 then
    Printf.sprintf
      "Retry policy: previous attempt failed (%s). You MUST output now with a clearly different angle."
      reason
  else
    Printf.sprintf
      "Retry policy: previous attempts failed (%s). You MUST output one decisive check-in now, materially different from the last preview."
      reason

let proactive_temperature ~cascade_name attempt =
  let fallback () =
    if attempt <= 1 then Keeper_config.keeper_proactive_temperature_low ()
    else if attempt = 2 then Keeper_config.keeper_proactive_temperature_mid ()
    else Keeper_config.keeper_proactive_temperature_high ()
  in
  Cascade_inference.resolve_temperature ~cascade_name ~fallback

let strip_state_blocks_text (s : string) : string =
  let start_marker = "[STATE]" in
  let end_marker = "[/STATE]" in
  let start_re = Str.regexp_string start_marker in
  let end_re = Str.regexp_string end_marker in
  let len = String.length s in
  let rec loop from (buf : Buffer.t) =
    if from >= len then ()
    else
      try
        let i = Str.search_forward start_re s from in
        if i > from then Buffer.add_substring buf s from (i - from);
        let block_start = i + String.length start_marker in
        let next_from =
          try
            let j = Str.search_forward end_re s block_start in
            j + String.length end_marker
          with Not_found ->
            len
        in
        loop next_from buf
      with Not_found ->
        Buffer.add_substring buf s from (len - from)
  in
  let buf = Buffer.create len in
  loop 0 buf;
  Buffer.contents buf

let trim_to_option (s : string) : string option =
  let trimmed = String.trim s in
  if trimmed = "" then None else Some trimmed

let state_snapshot_reply_fallback (snapshot : keeper_state_snapshot option) :
    string option =
  match snapshot with
  | Some { progress = Some progress; _ } -> trim_to_option progress
  | Some { goal = Some goal; _ } -> trim_to_option goal
  | _ -> None

let strip_internal_reply_markup (raw : string) : string =
  raw
  |> strip_skill_route_lines
  |> strip_state_blocks_text
  |> String.trim

let user_visible_reply_text ?fallback (raw : string) : string =
  match trim_to_option (strip_internal_reply_markup raw) with
  | Some text -> text
  | None -> (
      match Option.bind fallback trim_to_option with
      | Some text -> text
      | None -> (
          match state_snapshot_reply_fallback (parse_state_snapshot_from_reply raw) with
          | Some text -> text
          | None -> "State updated."))

let normalize_proactive_text (raw : string) : string =
  raw
  |> strip_internal_reply_markup
  |> Str.global_replace (Str.regexp "[ \t\r\n]+") " "
  |> String.trim

let extract_checkin_text (raw : string) : string option =
  let cleaned = normalize_proactive_text raw in
  if cleaned = "" then None
  else
    let lines =
      raw
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun line -> line <> "")
    in
    let checkin_line =
      List.find_map
        (fun line ->
          match strip_prefix_ci ~prefix:"CHECKIN:" line with
          | Some s ->
              let s = normalize_proactive_text s in
              if s = "" then None else Some s
          | None -> None)
        lines
    in
    match checkin_line with
    | Some s -> Some s
    | None -> Some cleaned

let proactive_has_terminal_punct (s : string) : bool =
  let t = String.trim s in
  t <> "" && Str.string_match (Str.regexp ".*[.!?。！？]$") t 0

let proactive_has_terminal_korean_ending (s : string) : bool =
  let t = String.trim s in
  t <> ""
  && Str.string_match
       (Str.regexp ".*\\(다\\|요\\|니다\\|습니다\\|중입니다\\|함\\)$")
       t 0

let proactive_has_terminal_ending (s : string) : bool =
  proactive_has_terminal_punct s || proactive_has_terminal_korean_ending s

let proactive_looks_fragmentary (s : string) : bool =
  let t = String.trim s in
  t = ""
  || Str.string_match (Str.regexp ".*[\"'([{]$") t 0
  || Str.string_match (Str.regexp ".*[:;,\\-]$") t 0

let proactive_fallback_reply ~(meta : keeper_meta) ~(idle_seconds : int) : string =
  let goal =
    let g = String.trim meta.goal in
    if g = "" then "현재 목표" else g
  in
  let goal_phrase =
    goal
    |> Str.global_replace (Str.regexp "[.!?。！？]+$") ""
    |> String.trim
    |> fun s -> if s = "" then goal else s
  in
  let soul_hint =
    match String.lowercase_ascii (String.trim meta.soul_profile) with
    | "safety" -> "리스크 우선 점검을 마쳤고"
    | "delivery" -> "실행 단위로 정리해 두었고"
    | "research" -> "가설 검증 포인트를 갱신했고"
    | _ -> "진행 상태를 점검했고"
  in
  let templates =
    [|
      Printf.sprintf
        "%s %s, 다음 지시를 받으면 즉시 진행하겠습니다."
        goal soul_hint;
      Printf.sprintf
        "현재는 %s에 맞춰 대기 중이며, 새 입력이 오면 바로 실행 단계로 전환하겠습니다."
        goal_phrase;
      Printf.sprintf
        "%s 기준으로 우선순위를 업데이트했습니다. 다음 턴에서 바로 이어가겠습니다."
        goal;
      Printf.sprintf
        "idle %ds 동안 %s 관련 체크를 유지했습니다. 후속 요청에 맞춰 계속 진행하겠습니다."
        idle_seconds goal_phrase;
    |]
  in
  let idx =
    abs (Hashtbl.hash (meta.name, meta.proactive_count_total, idle_seconds))
    mod Array.length templates
  in
  templates.(idx)

let proactive_quality_check (raw : string) : (string, string) result =
  match extract_checkin_text raw with
  | None -> Error "empty"
  | Some text ->
      if proactive_looks_fragmentary text then Error "fragmentary"
      else if not (proactive_has_terminal_ending text) then Error "missing_terminal_ending"
      else Ok text

let looks_fragmentary_history_text (raw : string) : bool =
  let t = normalize_proactive_text raw in
  if t = "" then true
  else
    let hard_fragment = proactive_looks_fragmentary t in
    let has_terminal = proactive_has_terminal_ending t in
    let ends_korean_sentence =
      Str.string_match
        (Str.regexp ".*\\(다\\|요\\|니다\\|습니다\\|중입니다\\|함\\)$")
        t 0
    in
    let short_unterminated =
      (not has_terminal) && (not ends_korean_sentence) && String.length t <= 24
    in
    let trailing_connector =
      (not has_terminal)
      && Str.string_match
           (Str.regexp
              ".*\\(and\\|or\\|with\\|to\\|for\\|그리고\\|또는\\|및\\)$")
           (String.lowercase_ascii t) 0
    in
    hard_fragment || short_unterminated || trailing_connector
