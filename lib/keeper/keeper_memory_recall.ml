(** Keeper_memory_recall — cost calculation, recall scoring, auto-rules, and memory eval. *)

open Keeper_types

include Keeper_memory_bank

let cost_usd_of_usage (usage : Agent_sdk.Types.api_usage) ~(model_id : string) : float =
  let pricing = Llm_provider.Pricing.pricing_for_model model_id in Llm_provider.Pricing.estimate_cost ~pricing
        ~input_tokens:usage.input_tokens ~output_tokens:usage.output_tokens ()

let read_file_tail_lines path ~max_bytes:_ ~max_lines : string list =
  if max_lines <= 0 then []
  else if not (Fs_compat.file_exists path) then []
  else
    try
      let content = Fs_compat.load_file path in
      let lines =
        content
        |> String.split_on_char '\n'
        |> List.filter (fun s -> String.trim s <> "")
      in
      let n = List.length lines in
      let drop = max 0 (n - max_lines) in
      lines |> List.mapi (fun i s -> (i, s)) |> List.filter (fun (i, _) -> i >= drop) |> List.map snd
    with Sys_error _ ->
      []

let read_keeper_memory_summary
    (config : Room.config)
    ~(name : string)
    ~(max_bytes : int)
    ~(max_lines : int)
    ~(recent_limit : int) : keeper_memory_summary =
  let lines =
    read_file_tail_lines
      (keeper_memory_bank_path config name)
      ~max_bytes
      ~max_lines
  in
  summarize_memory_bank_lines lines ~recent_limit

let is_memory_recall_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let needles = [
    "what did i ask";
    "first question";
    "before";
    "remember";
    "remembered";
    "do you remember";
    "memory";
    "기억";
    "기억해";
    "기억안나";
    "기억 안나";
    "기억나";
    "기억 나";
    "전에 뭐";
    "이전에";
    "첫 질문";
    "처음 물어";
    "뭐라고 물어봤";
  ] in
  List.exists (fun n ->
    try
      let _ = Str.search_forward (Str.regexp_string n) q 0 in
      true
    with Not_found -> false
  ) needles

let expected_topic_hint (s : string) : string option =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    try let _ = Str.search_forward (Str.regexp_string needle) s 0 in true with Not_found -> false
  in
  let has_en needle =
    try let _ = Str.search_forward (Str.regexp_string needle) q 0 in true with Not_found -> false
  in
  if (try let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in true with Not_found -> false)
     || (try let _ = Str.search_forward (Str.regexp_string "weather") q 0 in true with Not_found -> false)
  then
    Some "weather"
  else if has_ko "첫 질문"
       || has_en "first question"
       || has_en "very first"
       || has_en "earliest"
       || ((has_ko "처음" || has_ko "첫" || has_en "first")
           && (has_ko "질문" || has_ko "물어" || has_en "question" || has_en "ask"))
  then
    Some "first_question"
  else
    None

(** Strip non-alphanumeric ASCII, keep multibyte (CJK, etc.) and digits.
    Returns a cleaned lowercase string for tokenization. *)
let clean_for_similarity (s : string) : string =
  let s = String.lowercase_ascii s in
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let code = Char.code c in
    let keep =
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      code >= 128
    in
    if not keep then Bytes.set b i ' '
  done;
  Bytes.to_string b

(** Extract unique word tokens (space-split, length >= 2). *)
let normalize_for_similarity (s : string) : string list =
  let cleaned = clean_for_similarity s in
  let words =
    cleaned
    |> String.split_on_char ' '
    |> List.filter (fun w -> String.length w >= 2)
  in
  let tbl : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.filter (fun w ->
    if Hashtbl.mem tbl w then false
    else (Hashtbl.add tbl w (); true)
  ) words

(** Extract character n-grams from a cleaned string.
    For multibyte strings (Korean, CJK), each "character" may be multiple bytes.
    We use byte-level n-grams which naturally captures morpheme overlap
    for UTF-8 encoded text (Korean 3 bytes/char → 3-byte-gram captures
    individual syllables, 6-byte-gram captures 2-syllable morphemes).

    Returns a deduplicated list of n-grams. *)
let char_ngrams ~(n : int) (s : string) : string list =
  let cleaned = clean_for_similarity s in
  (* Remove spaces for n-gram extraction *)
  let buf = Buffer.create (String.length cleaned) in
  String.iter (fun c -> if c <> ' ' then Buffer.add_char buf c) cleaned;
  let compact = Buffer.contents buf in
  let len = String.length compact in
  if len < n then (if len > 0 then [compact] else [])
  else
    let tbl : (string, unit) Hashtbl.t = Hashtbl.create 64 in
    let acc = ref [] in
    for i = 0 to len - n do
      let gram = String.sub compact i n in
      if not (Hashtbl.mem tbl gram) then begin
        Hashtbl.add tbl gram ();
        acc := gram :: !acc
      end
    done;
    List.rev !acc

(** Jaccard similarity over a combined feature set: word tokens + character n-grams.
    Word tokens capture exact matches; n-grams capture partial/morphological overlap.
    This is effective for Korean where "기억해" and "기억나" share the morpheme "기억"
    but would score 0 on word-level Jaccard.

    Uses 3-byte grams (captures Korean syllables) and 6-byte grams (captures
    2-syllable Korean morphemes) alongside word tokens. *)
let jaccard_similarity (a : string) (b : string) : float =
  let words_a = normalize_for_similarity a in
  let words_b = normalize_for_similarity b in
  let ngrams_a = char_ngrams ~n:3 a @ char_ngrams ~n:6 a in
  let ngrams_b = char_ngrams ~n:3 b @ char_ngrams ~n:6 b in
  let ta = words_a @ ngrams_a in
  let tb = words_b @ ngrams_b in
  if ta = [] && tb = [] then 1.0
  else if ta = [] || tb = [] then 0.0
  else
    let h : (string, bool) Hashtbl.t = Hashtbl.create 128 in
    List.iter (fun w -> Hashtbl.replace h w false) ta;
    let inter = ref 0 in
    let uniq_b = ref 0 in
    List.iter (fun w ->
      if Hashtbl.mem h w then begin
        if not (Hashtbl.find h w) then begin
          incr inter;
          Hashtbl.replace h w true
        end
      end else
        incr uniq_b
    ) tb;
    let union = (List.length ta) + !uniq_b in
    if union = 0 then 0.0 else float_of_int !inter /. float_of_int union

let latest_message_content_by_role
    ~(role : Agent_sdk.Types.role)
    (messages : Agent_sdk.Types.message list) : string option =
  match
    messages
    |> List.rev
    |> List.find_opt (fun (m : Agent_sdk.Types.message) -> m.role = role)
  with
  | None -> None
  | Some m -> trim_nonempty (String.trim (Agent_sdk.Types.text_of_message m))

let previous_assistant_message_content
    (messages : Agent_sdk.Types.message list) : string option =
  let assistants =
    messages
    |> List.rev
    |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
         if m.role = Agent_sdk.Types.Assistant then trim_nonempty (Agent_sdk.Types.text_of_message m) else None)
  in
  match assistants with
  | _latest :: previous :: _ -> Some previous
  | _ -> None

let goal_horizon_candidates (meta : keeper_meta) : string list =
  [meta.short_goal; meta.mid_goal; meta.long_goal; meta.goal]
  |> List.filter_map (fun raw ->
       raw
       |> normalize_goal_horizon_text
       |> trim_nonempty)
  |> List.fold_left
       (fun acc goal ->
         let key = normalize_memory_text_key goal in
         if List.exists (fun existing -> normalize_memory_text_key existing = key) acc then
           acc
         else
           goal :: acc)
       []
  |> List.rev

let best_goal_similarity ~(text : string) ~(goals : string list) : float =
  if goals = [] then 0.0
  else
    let candidate = String.trim text in
    if candidate = "" then 0.0
    else
      goals
      |> List.fold_left
           (fun best goal -> max best (jaccard_similarity candidate goal))
           0.0

let goal_alignment_score
    ~(meta : keeper_meta)
    ~(user_message : string option)
    ~(assistant_reply : string option) : float =
  let goals = goal_horizon_candidates meta in
  if goals = [] then 0.0
  else
    let user_score =
      match user_message with
      | None -> None
      | Some text -> Some (best_goal_similarity ~text ~goals)
    in
    let reply_score =
      match assistant_reply with
      | None -> None
      | Some text -> Some (best_goal_similarity ~text ~goals)
    in
    match user_score, reply_score with
    | None, None -> 0.0
    | Some s, None | None, Some s -> s
    | Some u, Some r -> (u +. r) /. 2.0

let repetition_risk_score
    ~(messages : Agent_sdk.Types.message list)
    ~(candidate_reply : string option) : float =
  match candidate_reply with
  | Some reply -> (
      match latest_message_content_by_role ~role:Agent_sdk.Types.Assistant messages with
      | Some prev -> jaccard_similarity reply prev
      | None -> 0.0)
  | None -> (
      match
        previous_assistant_message_content messages,
        latest_message_content_by_role ~role:Agent_sdk.Types.Assistant messages
      with
      | Some prev, Some latest -> jaccard_similarity latest prev
      | _ -> 0.0)

type keeper_auto_rule_eval = {
  repetition_risk: float;
  goal_alignment: float;
  response_alignment: float;
  goal_drift: float;
  reflect: bool;
  plan: bool;
  compact: bool;
  handoff: bool;
  guardrail_stop: bool;
  guardrail_reason: string option;
  reasons: string list;
}

let keeper_auto_rule_eval_to_json (e : keeper_auto_rule_eval) : Yojson.Safe.t =
  `Assoc [
    ("repetition_risk", `Float e.repetition_risk);
    ("goal_alignment", `Float e.goal_alignment);
    ("response_alignment", `Float e.response_alignment);
    ("goal_drift", `Float e.goal_drift);
    ("reflect", `Bool e.reflect);
    ("plan", `Bool e.plan);
    ("compact", `Bool e.compact);
    ("handoff", `Bool e.handoff);
    ("guardrail_stop", `Bool e.guardrail_stop);
    ("guardrail_reason",
      match e.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("reasons", `List (List.map (fun reason -> `String reason) e.reasons));
  ]

let keeper_reflection_payload_of_auto_rules (e : keeper_auto_rule_eval) : Yojson.Safe.t =
  let actions_rev = [] in
  let actions_rev =
    if e.reflect then `String "reflect" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.plan then `String "plan" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.compact then `String "compact" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.handoff then `String "handoff" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.guardrail_stop then `String "guardrail_stop" :: actions_rev else actions_rev
  in
  let has_action = actions_rev <> [] in
  `Assoc [
    ("triggered", `Bool has_action);
    ("actions", `List (List.rev actions_rev));
    ("guardrail_stop", `Bool e.guardrail_stop);
    ("guardrail_reason",
      match e.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("goal_drift", `Float e.goal_drift);
    ("repetition_risk", `Float e.repetition_risk);
    ("goal_alignment", `Float e.goal_alignment);
    ("response_alignment", `Float e.response_alignment);
    ("reasons", `List (List.map (fun reason -> `String reason) e.reasons));
  ]

let evaluate_keeper_auto_rules
    ~(meta : keeper_meta)
    ~(context_ratio : float)
    ~(message_count : int)
    ~(token_count : int)
    ~(repetition_risk : float)
    ~(goal_alignment : float)
    ~(response_alignment : float) : keeper_auto_rule_eval =
  let ratio_gate = meta.compaction.ratio_gate in
  let message_gate = meta.compaction.message_gate in
  let token_gate = meta.compaction.token_gate in
  let reflect_threshold = keeper_rule_reflect_repetition_threshold () in
  let plan_goal_alignment_threshold = keeper_rule_plan_goal_alignment_threshold () in
  let plan_response_alignment_threshold = keeper_rule_plan_response_alignment_threshold () in
  let guardrail_repetition_threshold = keeper_rule_guardrail_repetition_threshold () in
  let guardrail_goal_alignment_threshold = keeper_rule_guardrail_goal_alignment_threshold () in
  let guardrail_response_alignment_threshold = keeper_rule_guardrail_response_alignment_threshold () in
  let guardrail_context_threshold =
    max ratio_gate (keeper_rule_guardrail_context_threshold ())
  in
  let goal_drift =
    1.0 -. max 0.0 (min 1.0 (max goal_alignment response_alignment))
    |> max 0.0
    |> min 1.0
  in
  let reflect = repetition_risk >= reflect_threshold in
  let plan =
    goal_alignment <= plan_goal_alignment_threshold
    && response_alignment <= plan_response_alignment_threshold
  in
  let compact =
    context_ratio >= ratio_gate
    || (message_gate > 0 && message_count >= message_gate)
    || (token_gate > 0 && token_count >= token_gate)
  in
  let handoff = meta.auto_handoff && context_ratio >= meta.handoff_threshold in
  let guardrail_stop =
    repetition_risk >= guardrail_repetition_threshold
    && goal_alignment <= guardrail_goal_alignment_threshold
    && response_alignment <= guardrail_response_alignment_threshold
    && context_ratio >= guardrail_context_threshold
  in
  let guardrail_reason =
    if guardrail_stop then
      Some
        (Printf.sprintf
           "guardrail_stop(rep=%.3f>=%.3f,goal=%.3f<=%.3f,response=%.3f<=%.3f,ctx=%.3f>=%.3f)"
           repetition_risk
           guardrail_repetition_threshold
           goal_alignment
           guardrail_goal_alignment_threshold
           response_alignment
           guardrail_response_alignment_threshold
           context_ratio
           guardrail_context_threshold)
    else
      None
  in
  let reasons = [] in
  let reasons =
    if reflect then
      (Printf.sprintf
         "reflect(repetition_risk=%.3f>=%.3f)"
         repetition_risk
         reflect_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if plan then
      (Printf.sprintf
         "plan(goal_alignment=%.3f<=%.3f,response_alignment=%.3f<=%.3f)"
         goal_alignment
         plan_goal_alignment_threshold
         response_alignment
         plan_response_alignment_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if compact then
      (Printf.sprintf
         "compact(ctx=%.3f,msg=%d,tokens=%d)"
         context_ratio
         message_count
         token_count)
      :: reasons
    else reasons
  in
  let reasons =
    if handoff then
      (Printf.sprintf
         "handoff(ctx=%.3f>=%.3f)"
         context_ratio
         meta.handoff_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    match guardrail_reason with
    | Some reason -> reason :: reasons
    | None -> reasons
  in
  {
    repetition_risk;
    goal_alignment;
    response_alignment;
    goal_drift;
    reflect;
    plan;
    compact;
    handoff;
    guardrail_stop;
    guardrail_reason;
    reasons = List.rev reasons;
  }

(** Deterministic priority stack for auto-rule evaluation results.
    Given a keeper_auto_rule_eval where multiple rules may fire simultaneously,
    returns the single highest-priority action. Priority order (first match wins):
    1. guardrail_stop — safety-critical, 4-way AND gate
    2. reflect — repetition prevention
    3. plan — goal drift correction
    4. compact — context cleanup
    5. handoff — generation succession
    6. none — no rule fired *)
type prioritized_action =
  | Act_guardrail_stop of string
  | Act_reflect
  | Act_plan
  | Act_compact
  | Act_handoff
  | Act_none

let prioritized_action (eval : keeper_auto_rule_eval) : prioritized_action =
  if eval.guardrail_stop then
    Act_guardrail_stop (Option.value eval.guardrail_reason ~default:"guardrail_stop")
  else if eval.reflect then
    Act_reflect
  else if eval.plan then
    Act_plan
  else if eval.compact then
    Act_compact
  else if eval.handoff then
    Act_handoff
  else
    Act_none

let prioritized_action_to_string = function
  | Act_guardrail_stop reason -> Printf.sprintf "guardrail_stop(%s)" reason
  | Act_reflect -> "reflect"
  | Act_plan -> "plan"
  | Act_compact -> "compact"
  | Act_handoff -> "handoff"
  | Act_none -> "none"

let learned_policy_auto_rules
    ~(meta : keeper_meta)
    ~(context_ratio : float)
    ~(message_count : int)
    ~(token_count : int)
    ~(repetition_risk : float)
    ~(goal_alignment : float)
    ~(response_alignment : float) : keeper_auto_rule_eval =
  let ratio_gate = meta.compaction.ratio_gate in
  let message_gate = meta.compaction.message_gate in
  let token_gate = meta.compaction.token_gate in
  let goal_drift =
    1.0 -. max 0.0 (min 1.0 (max goal_alignment response_alignment))
    |> max 0.0
    |> min 1.0
  in
  let compact =
    context_ratio >= ratio_gate
    || (message_gate > 0 && message_count >= message_gate)
    || (token_gate > 0 && token_count >= token_gate)
  in
  let handoff = meta.auto_handoff && context_ratio >= meta.handoff_threshold in
  {
    repetition_risk;
    goal_alignment;
    response_alignment;
    goal_drift;
    reflect = false;
    plan = false;
    compact;
    handoff;
    guardrail_stop = false;
    guardrail_reason = None;
    reasons =
      [
        "policy_mode=heuristic";
        (if compact then "compact_safety_gate=true" else "compact_safety_gate=false");
        (if handoff then "handoff_safety_gate=true" else "handoff_safety_gate=false");
      ];
  }

let recent_user_messages (msgs : Agent_sdk.Types.message list) ~(max_n : int) : string list =
  msgs
  |> List.rev
  |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
       if m.role = Agent_sdk.Types.User then
         let c = String.trim (Agent_sdk.Types.text_of_message m) in
         if c = "" then None else Some c
       else None)
  |> take max_n

(** Load user messages from a history.jsonl file (persisted across generations).
    Each line is a JSON object with "role" and "content" fields.
    Returns up to [max_n] user messages from the tail of the file. *)
let load_history_user_messages ~(path : string) ~(max_n : int) : string list =
  let lines = read_file_tail_lines path ~max_bytes:0 ~max_lines:(max_n * 3) in
  lines
  |> List.filter_map (fun line ->
       try
         let json = Yojson.Safe.from_string line in
         let role = Yojson.Safe.Util.(json |> member "role" |> to_string) in
         if role = "user" then
           let content =
             Yojson.Safe.Util.(json |> member "content" |> to_string)
             |> String.trim
           in
           if content = "" then None else Some content
         else None
       with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None)
  |> take max_n

(** Build recall candidates by merging checkpoint messages with history.jsonl.
    Checkpoint messages are prioritized (recent context), history.jsonl
    provides cross-generation recall for older conversations. Deduplication
    uses exact string match on the first 100 characters. *)
let recall_candidates_with_history
    ~(checkpoint_messages : Agent_sdk.Types.message list)
    ~(history_path : string)
    ~(max_checkpoint : int)
    ~(max_history : int) : string list =
  let from_checkpoint = recent_user_messages checkpoint_messages ~max_n:max_checkpoint in
  let from_history = load_history_user_messages ~path:history_path ~max_n:max_history in
  (* Deduplicate: checkpoint messages take priority *)
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let key_of s =
    let len = min 100 (String.length s) in
    String.sub s 0 len
  in
  List.iter (fun s -> Hashtbl.replace seen (key_of s) ()) from_checkpoint;
  let unique_history =
    List.filter (fun s -> not (Hashtbl.mem seen (key_of s))) from_history
  in
  from_checkpoint @ unique_history

type memory_recall_eval = {
  performed: bool;
  query_kind: string;
  expected_topic: string option;
  candidate_count: int;
  initial_score: float;
  final_score: float;
  threshold: float;
  passed: bool;
  best_match: string option;
}

let evaluate_memory_recall
    ~(user_message : string)
    ~(assistant_reply : string)
    ~(candidates : string list) : memory_recall_eval =
  let recall = is_memory_recall_query user_message in
  let expected_topic = expected_topic_hint user_message in
  let has_weather_word (s : string) =
    let q = String.lowercase_ascii s in
    (try let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in true with Not_found -> false)
    || (try let _ = Str.search_forward (Str.regexp_string "weather") q 0 in true with Not_found -> false)
  in
  let threshold =
    match expected_topic with
    | Some "weather" -> 0.15
    | _ -> 0.18
  in
  if not recall then
    {
      performed = false;
      query_kind = "none";
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = true;
      best_match = None;
    }
  else if candidates = [] then
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = 0;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = false;
      best_match = None;
    }
  else
    let weather_candidates = List.filter has_weather_word candidates in
    let candidates_for_general =
      match expected_topic with
      | Some "weather" when weather_candidates <> [] -> weather_candidates
      | _ -> candidates
    in
    let oldest_candidate =
      match List.rev candidates with
      | c :: _ -> Some c
      | [] -> None
    in
    let (best_msg, best_score) =
      match expected_topic, oldest_candidate with
      | Some "first_question", Some target ->
          (Some target, jaccard_similarity assistant_reply target)
      | _ ->
          List.fold_left (fun (best_m, best_s) cand ->
            let score = jaccard_similarity assistant_reply cand in
            if score > best_s then (Some cand, score) else (best_m, best_s)
          ) (None, 0.0) candidates_for_general
    in
    let topic_bonus =
      match expected_topic with
      | Some "weather" ->
          let has_weather_reply = has_weather_word assistant_reply in
          if has_weather_reply then 0.08 else -.0.08
      | Some "first_question" ->
          let has_first =
            (try let _ = Str.search_forward (Str.regexp_string "첫") assistant_reply 0 in true with Not_found -> false)
            || (try let _ = Str.search_forward (Str.regexp_string "first") (String.lowercase_ascii assistant_reply) 0 in true with Not_found -> false)
          in
          if has_first then 0.05 else -.0.05
      | _ -> 0.0
    in
    let final_score = max 0.0 (min 1.0 (best_score +. topic_bonus)) in
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = best_score;
      final_score;
      threshold;
      passed = final_score >= threshold;
      best_match = best_msg;
    }

let memory_eval_to_json
    (e : memory_recall_eval)
    ~(correction_applied : bool)
    ~(correction_success : bool)
    ~(correction_skipped_budget : bool)
    ~(prompt_fallback_applied : bool)
    ~(prompt_fallback_success : bool)
    ~(prompt_fallback_skipped_budget : bool)
    ~(postpass_budget_ms : int)
    ~(postpass_budget_remaining_ms : int)
    ~(recall_fallback_applied : bool) : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool e.performed);
    ("query_kind", `String e.query_kind);
    ("expected_topic", match e.expected_topic with Some t -> `String t | None -> `Null);
    ("candidate_count", `Int e.candidate_count);
    ("initial_score", `Float e.initial_score);
    ("final_score", `Float e.final_score);
    ("threshold", `Float e.threshold);
    ("passed", `Bool e.passed);
    ("best_match", match e.best_match with Some m -> `String m | None -> `Null);
    ("correction_applied", `Bool correction_applied);
    ("correction_success", `Bool correction_success);
    ("correction_skipped_budget", `Bool correction_skipped_budget);
    ("prompt_fallback_applied", `Bool prompt_fallback_applied);
    ("prompt_fallback_success", `Bool prompt_fallback_success);
    ("prompt_fallback_skipped_budget", `Bool prompt_fallback_skipped_budget);
    ("postpass_budget_ms", `Int postpass_budget_ms);
    ("postpass_budget_remaining_ms", `Int postpass_budget_remaining_ms);
    ("deterministic_fallback_applied", `Bool recall_fallback_applied);
    ("recall_fallback_applied", `Bool recall_fallback_applied);
  ]

let work_kind_of_eval (e : memory_recall_eval) : string =
  if e.performed then
    if e.query_kind <> "" && e.query_kind <> "none" then
      e.query_kind
    else
      "memory_recall"
  else
    match e.expected_topic with
    | Some "weather" -> "weather_answer"
    | Some "first_question" -> "first_question_answer"
    | Some topic when topic <> "" -> topic
    | _ -> "general_chat"

(* Tool definitions moved to Tool_shard for dynamic composition.
   This alias maintains backward compatibility. *)
