(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

open Keeper_types
open Keeper_memory
open Keeper_alerting

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
    ~instructions =
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
  Printf.sprintf
    "You are a keeper agent with persistent memory.\n\
     Goal: %s\n\
     Goal horizons:\n\
     - Short: %s\n\
     - Mid: %s\n\
     - Long: %s\n\
     \n\
     Tool guidance:\n\
     - You can call tools for time/context/memory/weather checks.\n\
     - Prefer tools when user asks for factual current status or memory lookup evidence.\n\
     - After tool use, answer with concise, grounded statements.\n\
     \n\
     Self model:\n\
     - Will: %s\n\
     - Needs: %s\n\
     - Desires: %s\n\
     \n\
     %s\n\
     \n\
    %s\
    %s"
    goal short_goal mid_goal long_goal will needs desires profile_policy
    keeper_constitution custom

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
  if not meta.drift_enabled then
    (meta, false, None)
  else if String.trim user_message = "" then
    (meta, false, None)
  else if work_kind <> "general_chat" && work_kind <> "memory_recall" then
    (meta, false, None)
  else
    let turn_gap = meta.total_turns - meta.last_drift_turn in
    if turn_gap < meta.drift_min_turn_gap then
      (meta, false, None)
    else
      let msg = String.lowercase_ascii user_message in
      let has_any keywords = List.exists (fun kw -> contains_ci msg kw) keywords in
      let relationship_flag =
        has_any
          [ "연애"; "관계"; "감정"; "사람"; "호감"; "불호"; "신뢰"; "친밀"; "친구";
            "relationship"; "emotion"; "trust"; "liking"; "dislike" ]
      in
      let safety_flag =
        has_any
          [ "위험"; "리스크"; "장애"; "실패"; "사고"; "롤백"; "incident"; "risk";
            "failure"; "rollback"; "outage" ]
      in
      let delivery_flag =
        has_any
          [ "실행"; "마감"; "배포"; "완료"; "일정"; "ship"; "deliver"; "deadline";
            "execute" ]
      in
      let memory_flag =
        has_any
          [ "기억"; "메모"; "승계"; "핸드오프"; "컴팩팅"; "memory"; "handoff";
            "compaction"; "context" ]
      in
      let conflict_flag =
        has_any
          [ "갈등"; "충돌"; "싸움"; "비난"; "불편"; "conflict"; "fight"; "blame" ]
      in
      if not (relationship_flag || safety_flag || delivery_flag || memory_flag || conflict_flag)
      then
        (meta, false, None)
      else
        let will' =
          meta.will
          |> (fun v ->
               if safety_flag then
                 append_trait_clause ~base:v
                   ~clause:"불확실성이 커지면 즉시 보수 모드로 전환한다."
               else v)
          |> (fun v ->
               if conflict_flag then
                 append_trait_clause ~base:v
                   ~clause:"갈등 상황에서는 해석보다 사실 확인과 경계선 선언을 먼저 수행한다."
               else v)
          |> compact_self_model_text
        in
        let needs' =
          meta.needs
          |> (fun v ->
               if relationship_flag then
                 append_trait_clause ~base:v
                   ~clause:"관계의 비대칭, 감정 신호, 실제 사실을 분리 기록한다."
               else v)
          |> (fun v ->
               if memory_flag then
                 append_trait_clause ~base:v
                   ~clause:"기억 항목은 사실/해석/결정을 분리해 보존한다."
               else v)
          |> compact_self_model_text
        in
        let desires' =
          meta.desires
          |> (fun v ->
               if delivery_flag then
                 append_trait_clause ~base:v
                   ~clause:"다음 행동을 책임/기한/검증 기준과 함께 즉시 고정한다."
               else v)
          |> (fun v ->
               if relationship_flag then
                 append_trait_clause ~base:v
                   ~clause:"관계를 해치지 않으면서도 핵심을 말하는 문장을 우선 선택한다."
               else v)
          |> compact_self_model_text
        in
        if will' = meta.will && needs' = meta.needs && desires' = meta.desires
        then
          (meta, false, None)
        else
          let tags =
            []
            |> (fun xs -> if relationship_flag then "relationship" :: xs else xs)
            |> (fun xs -> if safety_flag then "safety" :: xs else xs)
            |> (fun xs -> if delivery_flag then "delivery" :: xs else xs)
            |> (fun xs -> if memory_flag then "memory" :: xs else xs)
            |> (fun xs -> if conflict_flag then "conflict" :: xs else xs)
            |> List.rev
          in
          let reason =
            Printf.sprintf "auto-drift(turn=%d,gap=%d,tags=%s)" meta.total_turns
              turn_gap (String.concat "," tags)
          in
          ( {
              meta with
              will = will';
              needs = needs';
              desires = desires';
              drift_count_total = meta.drift_count_total + 1;
              last_drift_turn = meta.total_turns;
              last_drift_reason = reason;
              updated_at = now_iso ();
            },
            true,
            Some reason )

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
     Guidance (strict):\n\
     - Prefer the same language as the recent conversation.\n\
     - Avoid repeating the previous proactive message verbatim.\n\
     - Keep it concise and useful for the current goal.\n\
     - If external checks or actions are needed, call tools before finalizing.\n\
     - When a required write action is identified, execute it via tools and then summarize.\n\
     - For this proactive turn only, do NOT output [STATE] blocks.\n\
     - Output exactly one line using this format:\n\
       CHECKIN: <single complete sentence ending with punctuation>"
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

let proactive_temperature attempt =
  if attempt <= 1 then Keeper_config.keeper_proactive_temperature_low ()
  else if attempt = 2 then Keeper_config.keeper_proactive_temperature_mid ()
  else Keeper_config.keeper_proactive_temperature_high ()

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
