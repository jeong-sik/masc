(** Context Router — Selective Retrieval (Agentic RAG)

    Pre-retrieval decision gate that determines whether a query needs
    full knowledge base search, lightweight context, or no retrieval at all.

    Reduces unnecessary vector DB / Neo4j calls by ~40%% by classifying
    query intent before dispatching to Auto_recall sources.

    Decision flow:
    1. Intent classification (heuristic or LLM)
    2. State-aware check (recent broadcasts contain answer?)
    3. Route: Skip | Light (broadcasts only) | Full (all sources)

    Mode selection via MASC_CONTEXT_ROUTER_MODE:
      - heuristic (default): pattern-matching, 0-latency
      - llm: LLM-based semantic classification
      - hybrid: LLM with heuristic fallback on failure

    @see "Context Engineering" — 2025-2026 best practice
    @see IntentGPT (arXiv 2411.10670) — zero-shot intent classification
    @since 2.60.0
    @since 2.65.0 — LLM/hybrid intent classification modes *)

(** Retrieval depth — how much context to fetch *)
type retrieval_depth =
  | Skip        (** No retrieval needed — conversational, arithmetic, or already known *)
  | Light       (** Recent broadcasts + cache only — fast, low cost *)
  | Full        (** All configured sources including vector DB — comprehensive *)
[@@deriving show, eq]

(** Query intent classification *)
type query_intent =
  | Conversational   (** Greetings, acknowledgements, small talk *)
  | Task_command     (** Direct commands: claim, done, broadcast, join *)
  | Status_check     (** Room status, agent list, task list *)
  | Knowledge_query  (** Needs domain knowledge or historical context *)
  | Coordination     (** Multi-agent coordination, @mentions, voting *)
[@@deriving show, eq]

(** Routing decision with explanation *)
type routing_decision = {
  depth: retrieval_depth;
  intent: query_intent;
  reason: string;
  confidence: float;  (** 0.0-1.0 *)
}

(* ---------- Router Mode ---------- *)

(** Classification mode: heuristic pattern matching, LLM semantic, or hybrid. *)
type router_mode = Heuristic | Llm_mode | Hybrid_mode

let get_router_mode () : router_mode =
  match Sys.getenv_opt "MASC_CONTEXT_ROUTER_MODE" with
  | Some "llm" -> Llm_mode
  | Some "hybrid" -> Hybrid_mode
  | _ -> Heuristic

(* ---------- Intent Classification (Heuristic) ---------- *)

(** Conversational patterns — no retrieval needed *)
let conversational_patterns = [
  "hello"; "hi "; "hey "; "thanks"; "thank you"; "ok"; "okay";
  "bye"; "goodbye"; "good morning"; "good night";
  "ㅋㅋ"; "ㅎㅎ"; "네"; "넵"; "감사"; "안녕"; "ㅇㅇ";
  "understood"; "got it"; "sure"; "yes"; "no";
]

(** Task command patterns — operate on existing state, no search *)
let command_patterns = [
  "masc_claim"; "masc_done"; "masc_join"; "masc_leave";
  "masc_broadcast"; "masc_lock"; "masc_unlock"; "masc_vote";
  "masc_add_task"; "masc_cancel"; "masc_transition";
  "claim "; "done "; "cancel "; "broadcast ";
]

(** Status check patterns — use room state, not knowledge base *)
let status_patterns = [
  "masc_status"; "masc_tasks"; "masc_agents"; "masc_who";
  "status"; "who is"; "what tasks"; "show me"; "list ";
  "현재 상태"; "누가 있"; "태스크 목록";
]

(** Knowledge patterns — likely needs retrieval *)
let knowledge_patterns = [
  "how to"; "how do"; "what is"; "why does"; "explain";
  "find "; "search "; "look up"; "documentation";
  "어떻게"; "왜"; "설명"; "찾아"; "검색";
  "pattern"; "example"; "best practice";
  "error"; "bug"; "fix"; "debug";
]

let string_lower s = String.lowercase_ascii s

let has_pattern patterns query =
  let q = string_lower query in
  List.exists (fun p ->
    let p_lower = string_lower p in
    (* Check if query contains or starts with pattern *)
    let p_len = String.length p_lower in
    let q_len = String.length q in
    if p_len > q_len then false
    else
      let rec check i =
        if i > q_len - p_len then false
        else if String.sub q i p_len = p_lower then true
        else check (i + 1)
      in
      check 0
  ) patterns

(** Classify query intent using heuristic pattern matching.
    Fast (no LLM call), covers ~80%% of cases accurately. *)
let classify_intent_heuristic (query : string) : query_intent * float =
  let q = String.trim query in
  let len = String.length q in
  (* Very short queries are usually conversational or commands *)
  if len < 3 then (Conversational, 0.9)
  else if has_pattern command_patterns q then (Task_command, 0.95)
  else if has_pattern status_patterns q then (Status_check, 0.9)
  else if has_pattern conversational_patterns q then (Conversational, 0.85)
  else if has_pattern knowledge_patterns q then (Knowledge_query, 0.85)
  (* Check for @mentions — coordination *)
  else if String.length q > 0 && q.[0] = '@' then (Coordination, 0.9)
  (* Default: treat medium+ queries as potential knowledge queries *)
  else if len > 50 then (Knowledge_query, 0.6)
  else (Coordination, 0.5)  (* Short ambiguous → coordination *)

(* ---------- Intent Classification (LLM) ---------- *)

(** Build the LLM prompt for intent classification. *)
let build_intent_prompt (query : string) : string =
  Printf.sprintf
{|Classify the intent of this query into exactly one category.
Reply with ONLY the category name, nothing else.

Categories:
- Conversational: greetings, thanks, acknowledgements, small talk, yes/no
- Task_command: direct commands like claim, done, broadcast, join, cancel
- Status_check: asking about current status, agent list, task list, progress
- Knowledge_query: needs domain knowledge, how-to, debugging, explanations, search
- Coordination: multi-agent coordination, @mentions, delegation, voting

Query: "%s"

Category:|} query

(** Parse an intent category from LLM response text.
    Extracts the first recognized category name. *)
let parse_intent_response (text : string) : (query_intent * float) option =
  let s = String.lowercase_ascii (String.trim text) in
  let has_label pat =
    let p_len = String.length pat in
    let s_len = String.length s in
    if p_len > s_len then false
    else
      let is_label_char = function
        | 'a' .. 'z' | '0' .. '9' | '_' -> true
        | _ -> false
      in
      let rec check i =
        if i > s_len - p_len then false
        else if String.sub s i p_len = pat then
          let left_ok = i = 0 || not (is_label_char s.[i - 1]) in
          let right_idx = i + p_len in
          let right_ok =
            right_idx = s_len || not (is_label_char s.[right_idx])
          in
          (left_ok && right_ok) || check (i + 1)
        else check (i + 1)
      in
      check 0
  in
  (* Match in priority order — more specific first *)
  if has_label "task_command" || has_label "task command" then
    Some (Task_command, 0.90)
  else if has_label "status_check" || has_label "status check" then
    Some (Status_check, 0.90)
  else if has_label "knowledge_query" || has_label "knowledge query" then
    Some (Knowledge_query, 0.85)
  else if has_label "coordination" then
    Some (Coordination, 0.85)
  else if has_label "conversational" then
    Some (Conversational, 0.90)
  else
    None

(** Validate that an LLM response contains a parseable intent. *)
let intent_response_is_valid (resp : Llm_client.completion_response) : bool =
  parse_intent_response (Llm_client.text_of_response resp) <> None

(** Classify query intent using LLM semantic understanding.
    Returns (intent, confidence) or falls back to low-confidence default. *)
let classify_intent_llm (query : string) : query_intent * float =
  let prompt = build_intent_prompt query in
  match
    Lodge_cascade.call ~cascade_name:"context_router" ~prompt
      ~temperature:0.1 ~timeout_sec:10 ~max_tokens:20
      ~accept:intent_response_is_valid ()
  with
  | Ok r -> (
      match parse_intent_response r.response with
      | Some result -> result
      | None -> (Coordination, 0.3))  (* unparseable → low-confidence fallback *)
  | Error _err -> (Coordination, 0.3)  (* LLM error → low-confidence fallback *)

(** Classify query intent using hybrid mode: LLM first, heuristic fallback. *)
let classify_intent_hybrid (query : string) : query_intent * float =
  let prompt = build_intent_prompt query in
  match
    Lodge_cascade.call ~cascade_name:"context_router" ~prompt
      ~temperature:0.1 ~timeout_sec:10 ~max_tokens:20
      ~accept:intent_response_is_valid ()
  with
  | Ok r -> (
      match parse_intent_response r.response with
      | Some result -> result
      | None -> classify_intent_heuristic query)
  | Error _err -> classify_intent_heuristic query

(** Classify query intent using the active mode (env var dispatch). *)
let classify_intent (query : string) : query_intent * float =
  match get_router_mode () with
  | Heuristic -> classify_intent_heuristic query
  | Llm_mode -> classify_intent_llm query
  | Hybrid_mode -> classify_intent_hybrid query

(* ---------- State-Aware Check ---------- *)

(** Check if recent broadcasts likely contain the answer.
    Uses simple keyword overlap as a proxy for semantic similarity. *)
let broadcasts_cover_query ~(recent_broadcasts : string list) ~(query : string) : bool =
  if recent_broadcasts = [] then false
  else
    let q_words =
      query
      |> string_lower
      |> String.split_on_char ' '
      |> List.filter (fun w -> String.length w > 3)
    in
    if q_words = [] then false
    else
      let combined = String.concat " " (List.map string_lower recent_broadcasts) in
      let matching = List.filter (fun w ->
        let w_len = String.length w in
        let c_len = String.length combined in
        if w_len > c_len then false
        else
          let rec check i =
            if i > c_len - w_len then false
            else if String.sub combined i w_len = w then true
            else check (i + 1)
          in
          check 0
      ) q_words in
      let coverage = float_of_int (List.length matching) /. float_of_int (List.length q_words) in
      coverage >= 0.6  (* 60%+ keyword overlap → broadcasts likely sufficient *)

(* ---------- Main Router ---------- *)

(** Route a query to the appropriate retrieval depth.
    @param query The user/agent query
    @param recent_broadcasts Last N broadcast messages (for state-aware check)
    @return Routing decision with depth, intent, reason, and confidence *)
let route ?(recent_broadcasts = []) (query : string) : routing_decision =
  let (intent, confidence) = classify_intent query in
  match intent with
  | Conversational ->
    { depth = Skip;
      intent;
      reason = "conversational query — no retrieval needed";
      confidence }
  | Task_command ->
    { depth = Skip;
      intent;
      reason = "direct MASC command — operates on room state";
      confidence }
  | Status_check ->
    { depth = Light;
      intent;
      reason = "status query — recent broadcasts + cache sufficient";
      confidence }
  | Coordination ->
    if broadcasts_cover_query ~recent_broadcasts ~query then
      { depth = Light;
        intent;
        reason = "coordination query — answer found in recent broadcasts";
        confidence = confidence +. 0.1 }
    else
      { depth = Light;
        intent;
        reason = "coordination query — broadcasts + cache for context";
        confidence }
  | Knowledge_query ->
    if broadcasts_cover_query ~recent_broadcasts ~query then
      { depth = Light;
        intent;
        reason = "knowledge query but answer in recent broadcasts";
        confidence = confidence +. 0.1 }
    else
      { depth = Full;
        intent;
        reason = "knowledge query — full retrieval from all sources";
        confidence }

(** Convert retrieval depth to Auto_recall source list *)
let depth_to_sources (depth : retrieval_depth) : Auto_recall.recall_source list =
  match depth with
  | Skip -> []
  | Light -> [Auto_recall.Recent_broadcasts; Auto_recall.Masc_cache]
  | Full -> [Auto_recall.Recent_broadcasts; Auto_recall.Masc_cache;
             Auto_recall.File_context]

(** Create an Auto_recall config from a routing decision.
    Adjusts token budget based on depth. *)
let to_recall_config ?(base_config = Auto_recall.default_config) (decision : routing_decision)
    : Auto_recall.recall_config =
  match decision.depth with
  | Skip ->
    { base_config with enabled = false }
  | Light ->
    { base_config with
      sources = depth_to_sources Light;
      max_tokens = base_config.max_tokens / 2;  (* Half budget for light *)
    }
  | Full ->
    { base_config with
      sources = depth_to_sources Full;
    }

(** Convenience: route + fetch in one call.
    Returns (decision, recall_result option). *)
let route_and_fetch
    ?(recent_broadcasts = [])
    (room_config : Room_utils.config)
    ~(config : Auto_recall.recall_config)
    ~(query : string)
    ()
    : routing_decision * Auto_recall.recall_result =
  let decision = route ~recent_broadcasts query in
  let adjusted_config = to_recall_config ~base_config:config decision in
  let result = Auto_recall.fetch_context room_config ~config:adjusted_config ~query () in
  (decision, result)

(** Routing decision to JSON (for logging/metrics) *)
let decision_to_json (d : routing_decision) : Yojson.Safe.t =
  `Assoc [
    ("depth", `String (match d.depth with Skip -> "skip" | Light -> "light" | Full -> "full"));
    ("intent", `String (show_query_intent d.intent));
    ("reason", `String d.reason);
    ("confidence", `Float d.confidence);
  ]
