(** Keeper_exec_tools_recall — memory correction prompts, recall candidate
    selection, and deterministic recall fallback.
    Split from keeper_exec_tools.ml. *)

open Keeper_types
open Keeper_memory

let memory_correction_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" -> (
        match List.rev candidate_user_msgs with
        | earliest :: _ ->
            Printf.sprintf
              "- You MUST return the earliest question in the list exactly or near-verbatim: %s\n"
              earliest
        | [] ->
            "- User asked for the first question. Pick the earliest evidence if available.\n")
    | Some "weather" ->
        "- User asked about weather recall. Choose the weather-related question from evidence.\n"
    | _ ->
        "- Choose the single most relevant previous user question from evidence.\n"
  in
  Printf.sprintf
    "Memory correction required.\n\
     User asked: %s\n\
     Your previous answer: %s\n\
     Ground truth previous user questions:\n%s\n\n\
     Rewrite your answer using ONLY this evidence.\n\
     - If uncertain, explicitly say uncertain.\n\
     - Do not invent questions.\n\
     %s\
     - Keep concise.\n"
    user_message first_reply evidence topic_instruction

let memory_forced_grounding_prompt
    ~(user_message : string)
    ~(first_reply : string)
    ~(candidate_user_msgs : string list)
    ~(expected_topic : string option) : string =
  let evidence =
    candidate_user_msgs
    |> List.mapi (fun i msg -> Printf.sprintf "%d) %s" (i + 1) msg)
    |> String.concat "\n"
  in
  let topic_instruction =
    match expected_topic with
    | Some "first_question" ->
        "- Intent: user asked for the first question. Evidence list order is newest->oldest, so choose the LAST evidence line.\n"
    | Some "weather" ->
        "- Intent: user asked about weather. Choose the weather-related evidence line.\n"
    | _ ->
        "- Intent: user asked about previous question. Prefer the most recent evidence unless user asked otherwise.\n"
  in
  Printf.sprintf
    "Strict memory grounding retry.\n\
     User asked: %s\n\
     Your previous answer failed grounding validation: %s\n\
     Evidence (ordered newest to oldest):\n%s\n\n\
     You MUST answer using exactly one evidence line.\n\
     - The first line MUST be the chosen evidence question copied verbatim and wrapped in double quotes.\n\
     - Then add one concise sentence in the user's language.\n\
     - Do not invent or paraphrase the chosen question.\n\
     - Keep [STATE] continuity block at the end.\n\
     %s"
    user_message first_reply evidence topic_instruction

let contains_korean_text (s : string) : bool =
  try
    let _ = Str.search_forward (Str.regexp "[가-힣]") s 0 in
    true
  with Not_found -> false

let is_recent_question_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) s 0 in
      true
    with Not_found -> false
  in
  let has_en needle =
    try
      let _ = Str.search_forward (Str.regexp_string needle) q 0 in
      true
    with Not_found -> false
  in
  has_ko "방금"
  || has_ko "직전"
  || has_ko "바로 전"
  || has_ko "좀 전에"
  || has_ko "전 질문"
  || has_en "just asked"
  || has_en "last question"
  || has_en "previous question"
  || has_en "most recent question"

let has_weather_keyword (s : string) : bool =
  let q = String.lowercase_ascii s in
  (try
     let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in
     true
   with Not_found -> false)
  ||
  (try
     let _ = Str.search_forward (Str.regexp_string "weather") q 0 in
     true
   with Not_found -> false)

let select_recall_candidate
    ~(user_message : string)
    ~(expected_topic : string option)
    ~(best_match : string option)
    (candidates : string list) : string option =
  let best_match =
    match best_match with
    | Some text ->
        let text = String.trim text in
        if text = "" then None else Some text
    | None -> None
  in
  let most_recent =
    match candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let oldest =
    match List.rev candidates with
    | c :: _ ->
        let c = String.trim c in
        if c = "" then None else Some c
    | [] -> None
  in
  let weather_candidate =
    match List.find_opt has_weather_keyword candidates with
    | None -> None
    | Some c ->
        let c = String.trim c in
        if c = "" then None else Some c
  in
  match expected_topic with
  | Some "first_question" -> (
      match oldest with Some _ as x -> x | None -> best_match)
  | Some "weather" -> (
      match weather_candidate with
      | Some _ as x -> x
      | None -> (
          match best_match with Some _ as x -> x | None -> most_recent))
  | _ ->
      if is_recent_question_query user_message then
        match most_recent with Some _ as x -> x | None -> best_match
      else best_match

let recall_fallback_reply
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(selected_question : string)
    ~(expected_topic : string option) : string =
  let ko =
    contains_korean_text user_message || contains_korean_text selected_question
  in
  if ko then
    let lead =
      match expected_topic with
      | Some "first_question" -> "내 기록상 가장 처음 물어본 건 이거야:"
      | Some "weather" -> "내 기록에 남아있는 날씨 관련 질문은 이거야:"
      | _ -> "내 기록 기준으로는, 직전에 이런 질문을 했어:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: 회상 실패 시 저장된 질문 기록으로 자연스럽게 직접 응답\n\
       Next: 필요하면 첫 질문/직전 질문/주제별로 다시 좁혀서 조회\n\
       Decisions: 회상 질의는 추측보다 저장된 사용자 질문 기록 우선\n\
       OpenQuestions: 없음\n\
       Constraints: 저장된 대화 기록 범위 밖으로는 추측하지 않음\n\
       [/STATE]"
      lead selected_question meta.goal
  else
    let lead =
      match expected_topic with
      | Some "first_question" -> "From stored history, your earliest question was:"
      | Some "weather" -> "From stored history, your weather-related question was:"
      | _ -> "From stored history, your previous question was:"
    in
    Printf.sprintf
      "%s\n\"%s\"\n\n\
       [STATE]\n\
       Goal: %s\n\
       Progress: Returned a deterministic recall answer from stored user messages\n\
       Next: Narrow to earliest/most-recent/topic-specific question if needed\n\
       Decisions: For recall queries, prefer stored user-message evidence over generation\n\
       OpenQuestions: none\n\
       Constraints: Do not infer outside stored conversation history\n\
       [/STATE]"
      lead selected_question meta.goal

let deterministic_recall_fallback
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(eval : memory_recall_eval)
    ~(candidates : string list) : (string * memory_recall_eval) option =
  if (not eval.performed) || eval.passed || eval.candidate_count <= 0 then
    None
  else
    match
      select_recall_candidate ~user_message
        ~expected_topic:eval.expected_topic ~best_match:eval.best_match candidates
    with
    | None -> None
    | Some selected_question ->
        let forced_reply =
          recall_fallback_reply ~meta ~user_message ~selected_question
            ~expected_topic:eval.expected_topic
        in
        let eval2 =
          evaluate_memory_recall ~user_message ~assistant_reply:forced_reply
            ~candidates
        in
        Some (forced_reply, eval2)
