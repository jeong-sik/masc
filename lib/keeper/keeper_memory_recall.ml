(** Keeper_memory_recall — cost calculation, recall scoring, auto-rules, and memory eval. *)

open Keeper_types

include Keeper_memory_bank

let cost_usd_of_usage (usage : Agent_sdk.Types.api_usage) ~(model_id : string) : float =
  let pricing = Llm_provider.Pricing.pricing_for_model model_id in Llm_provider.Pricing.estimate_cost ~pricing
        ~input_tokens:usage.input_tokens ~output_tokens:usage.output_tokens ()

let read_file_tail_lines path ~max_bytes ~max_lines : string list =
  if max_lines <= 0 then []
  else if not (Fs_compat.file_exists path) then []
  else
    try
      let full_content = Fs_compat.load_file path in
      let file_len = String.length full_content in
      let read_start =
        if max_bytes <= 0 then 0
        else max 0 (file_len - max_bytes)
      in
      let content = String.sub full_content read_start (file_len - read_start) in
        let lines =
          content
          |> String.split_on_char '\n'
          |> List.filter (fun s -> String.trim s <> "")
        in
        (* When reading from mid-file, first line may be partial — drop it *)
        let lines =
          if read_start > 0 then
            match lines with _ :: rest -> rest | [] -> []
          else lines
        in
        let n = List.length lines in
        if n <= max_lines then lines
        else
          let drop = n - max_lines in
          List.filteri (fun i _ -> i >= drop) lines
    with Sys_error _ | End_of_file ->
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

(** Detect whether a query is asking about past conversation memory.

    Keywords are split by language for maintainability.
    English keywords are broad ("remember", "before") — matched after
    lowercasing to catch case variations.
    Korean keywords include spacing variants ("기억안나" vs "기억 안나")
    because Korean tokenizers often disagree on spacing. *)
let is_memory_recall_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let en_keywords = [
    "what did i ask";
    "first question";
    "before";
    "remember";
    "remembered";
    "do you remember";
    "memory";
  ] in
  let ko_keywords = [
    "기억";        (* "memory/remember" — base morpheme *)
    "기억해";      (* "do you remember" *)
    "기억안나";    (* "can't remember" — no space variant *)
    "기억 안나";   (* "can't remember" — spaced variant *)
    "기억나";      (* "I remember" — no space variant *)
    "기억 나";     (* "I remember" — spaced variant *)
    "전에 뭐";     (* "what before" — asking about prior *)
    "이전에";      (* "previously" *)
    "첫 질문";     (* "first question" *)
    "처음 물어";   (* "first asked" *)
    "뭐라고 물어봤"; (* "what did I ask" *)
  ] in
  let needles = en_keywords @ ko_keywords in
  List.exists (fun n ->
    Re.execp (Re.str n |> Re.compile) q
  ) needles

let expected_topic_hint (s : string) : string option =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    Re.execp (Re.str needle |> Re.compile) s
  in
  let has_en needle =
    Re.execp (Re.str needle |> Re.compile) q
  in
  if Re.execp (Re.str "날씨" |> Re.compile) s
     || Re.execp (Re.str "weather" |> Re.compile) q
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

let clean_for_similarity = Text_similarity.clean_for_similarity
let normalize_for_similarity = Text_similarity.normalize_for_similarity
let char_ngrams = Text_similarity.char_ngrams
let jaccard_similarity = Text_similarity.jaccard_similarity

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
    ("guardrail_reason", Json_util.string_opt_to_json e.guardrail_reason);
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
    ("guardrail_reason", Json_util.string_opt_to_json e.guardrail_reason);
    ("goal_drift", `Float e.goal_drift);
    ("repetition_risk", `Float e.repetition_risk);
    ("goal_alignment", `Float e.goal_alignment);
    ("response_alignment", `Float e.response_alignment);
    ("reasons", `List (List.map (fun reason -> `String reason) e.reasons));
  ]

let context_measured_auto_rules_of_events
    (events : Keeper_state_machine.event list)
  : Keeper_state_machine.auto_rule_summary
  =
  let rec loop = function
    | Keeper_state_machine.Context_measured { auto_rules; _ } :: _ -> auto_rules
    | _ :: rest -> loop rest
    | [] ->
      invalid_arg
        "keeper_auto_rule_eval_of_measurement: events missing Context_measured"
  in
  loop events

let keeper_auto_rule_eval_of_measurement
    ?events
    (snapshot : Keeper_measurement.measurement_snapshot)
  : keeper_auto_rule_eval
  =
  let events =
    match events with
    | Some value -> value
    | None -> Keeper_guard.evaluate snapshot
  in
  let auto_rules = context_measured_auto_rules_of_events events in
  let t = snapshot.thresholds in
  let effective_handoff_threshold =
    t.handoff_threshold *. t.model_handoff_multiplier
  in
  let reasons = [] in
  let reasons =
    if auto_rules.reflect then
      (Printf.sprintf
         "reflect(repetition_risk=%.3f>=%.3f)"
         snapshot.similarity.repetition_risk
         t.reflect_repetition_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if auto_rules.plan then
      (Printf.sprintf
         "plan(goal_alignment=%.3f<=%.3f,response_alignment=%.3f<=%.3f)"
         snapshot.similarity.goal_alignment
         t.plan_goal_alignment_threshold
         snapshot.similarity.response_alignment
         t.plan_response_alignment_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if auto_rules.compact then
      (Printf.sprintf
         "compact(ctx=%.3f,msg=%d,tokens=%d)"
         snapshot.context.context_ratio
         snapshot.context.message_count
         snapshot.context.token_count)
      :: reasons
    else reasons
  in
  let reasons =
    if auto_rules.handoff then
      (Printf.sprintf
         "handoff(ctx=%.3f>=%.3f)"
         snapshot.context.context_ratio
         effective_handoff_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    match auto_rules.guardrail_reason with
    | Some reason -> reason :: reasons
    | None -> reasons
  in
  {
    repetition_risk = snapshot.similarity.repetition_risk;
    goal_alignment = snapshot.similarity.goal_alignment;
    response_alignment = snapshot.similarity.response_alignment;
    goal_drift = auto_rules.goal_drift;
    reflect = auto_rules.reflect;
    plan = auto_rules.plan;
    compact = auto_rules.compact;
    handoff = auto_rules.handoff;
    guardrail_stop = auto_rules.guardrail_stop;
    guardrail_reason = auto_rules.guardrail_reason;
    reasons = List.rev reasons;
  }

(* ================================================================ *)
(* Model-aware threshold adjustment (#3069)                          *)
(* ================================================================ *)

(** Adjust compaction/handoff thresholds based on model metadata from OAS.
    Returns [(ratio_gate_multiplier, handoff_threshold_multiplier)].

    Uses concrete parameters (context_window, is_local) from
    [Llm_provider.Model_meta] instead of tier classification.

    - Local models with small context (< 64K): (0.75, 0.75) — earlier handoff.
    - Models with large context (>= 200K): (1.15, 1.10) — prefer compaction.
    - Everything else: (1.0, 1.0) (no adjustment).

    64K floor: llama-server default 8K is too small for keeper sessions.
    Models below 64K get early-handoff to avoid context overflow. *)
let model_threshold_multipliers_of_model_id (model_id : string) : float * float =
  let meta = Llm_provider.Model_meta.for_model_id model_id in
  let ctx = meta.context_window in
  if meta.is_local && ctx < 64_000 then
    (0.75, 0.75)
  else if ctx >= 200_000 then
    (1.15, 1.10)
  else
    (1.0, 1.0)

let evaluate_keeper_auto_rules
    ~(meta : keeper_meta)
    ~(context_ratio : float)
    ~(message_count : int)
    ~(token_count : int)
    ~(repetition_risk : float)
    ~(goal_alignment : float)
    ~(response_alignment : float)
    ?(model_id : string option) () : keeper_auto_rule_eval =
  let (ratio_mult, handoff_mult) =
    match model_id with
    | Some id -> model_threshold_multipliers_of_model_id id
    | None -> (1.0, 1.0)
  in
  let measurement =
    Keeper_measurement.capture
      ~snapshot_id:(Printf.sprintf "auto-rules-%s" meta.name)
      ~keeper_name:meta.name
      ~generation:meta.runtime.generation
      ~timestamp:0.0
      ~thresholds:
        { compaction_ratio_gate =
            Float.min Env_config_keeper.context_ratio_hard_cap
              (meta.compaction.ratio_gate *. ratio_mult)
        ; compaction_message_gate = meta.compaction.message_gate
        ; compaction_token_gate = meta.compaction.token_gate
        ; compaction_cooldown_sec = meta.compaction.cooldown_sec
        ; handoff_threshold = meta.handoff_threshold
        ; handoff_cooldown_sec = meta.handoff_cooldown_sec
        ; auto_handoff_enabled = meta.auto_handoff
        ; reflect_repetition_threshold =
            keeper_rule_reflect_repetition_threshold ()
        ; plan_goal_alignment_threshold =
            keeper_rule_plan_goal_alignment_threshold ()
        ; plan_response_alignment_threshold =
            keeper_rule_plan_response_alignment_threshold ()
        ; guardrail_repetition_threshold =
            keeper_rule_guardrail_repetition_threshold ()
        ; guardrail_goal_alignment_threshold =
            keeper_rule_guardrail_goal_alignment_threshold ()
        ; guardrail_response_alignment_threshold =
            keeper_rule_guardrail_response_alignment_threshold ()
        ; guardrail_context_threshold =
            max
              (Float.min Env_config_keeper.context_ratio_hard_cap
                 (meta.compaction.ratio_gate *. ratio_mult))
              (keeper_rule_guardrail_context_threshold ())
        ; max_consecutive_hb_failures = 1
        ; max_consecutive_turn_failures = 1
        ; model_ratio_multiplier = ratio_mult
        ; model_handoff_multiplier = handoff_mult
        }
      ~context_ratio
      ~message_count
      ~token_count
      ~max_tokens:(max 1 token_count)
      ~repetition_risk
      ~goal_alignment
      ~response_alignment
      ~now_ts:0.0
      ~idle_seconds:0
      ~since_last_compaction_sec:(float_of_int meta.compaction.cooldown_sec)
      ~since_last_handoff_sec:(float_of_int meta.handoff_cooldown_sec)
      ~proactive_warmup_elapsed:true
      ~consecutive_hb_failures:0
      ~consecutive_turn_failures:0
      ()
  in
  keeper_auto_rule_eval_of_measurement measurement

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
    ~(response_alignment : float)
    ?(model_id : string option) () : keeper_auto_rule_eval =
  let (ratio_mult, handoff_mult) =
    match model_id with
    | Some id -> model_threshold_multipliers_of_model_id id
    | None -> (1.0, 1.0)
  in
  let ratio_gate = Float.min Env_config_keeper.context_ratio_hard_cap (meta.compaction.ratio_gate *. ratio_mult) in
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
  let adjusted_handoff_threshold = Float.min Env_config_keeper.context_ratio_hard_cap (meta.handoff_threshold *. handoff_mult) in
  let handoff = meta.auto_handoff && context_ratio >= adjusted_handoff_threshold in
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
        "tool_policy=fixed";
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
    Re.execp (Re.str "날씨" |> Re.compile) s
    || Re.execp (Re.str "weather" |> Re.compile) q
  in
  (* Similarity threshold for recall match acceptance.
     0.18 (default): Jaccard + character n-gram combined score.
     At this level, queries sharing 2+ morphemes with a candidate produce
     scores above 0.18, while unrelated pairs stay below. Determined by
     manual review of recall accuracy on keeper session transcripts.

     0.15 (weather): Weather queries are typically short ("오늘 날씨" = 2 words)
     with minimal context words. The reduced n-gram surface area produces
     lower scores for genuine matches, so we lower the threshold by 0.03
     to avoid false negatives on this common query type. *)
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
            Re.execp (Re.str "첫" |> Re.compile) assistant_reply
            || Re.execp (Re.str "first" |> Re.compile) (String.lowercase_ascii assistant_reply)
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
    ("expected_topic", Json_util.string_opt_to_json e.expected_topic);
    ("candidate_count", `Int e.candidate_count);
    ("initial_score", `Float e.initial_score);
    ("final_score", `Float e.final_score);
    ("threshold", `Float e.threshold);
    ("passed", `Bool e.passed);
    ("best_match", Json_util.string_opt_to_json e.best_match);
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
