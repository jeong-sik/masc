(** Capability-aware query router with sparse tier selection.

    This module classifies queries using structural pattern analysis
    (not keyword matching) and scores agents by multi-dimensional
    capability dot product. It picks 2-3 agents from a static pool.
    It is not an LLM-routed MoE system. *)

(** Query classification categories (preserved for backward compat) *)
type query_class =
  | Code         (** Programming, debugging, implementation *)
  | Analysis     (** Data analysis, reasoning, evaluation *)
  | Creative     (** Writing, ideation, brainstorming *)
  | Factual      (** Facts, lookup, definitions *)
  | Conversation (** Chat, casual dialogue *)
  | Complex      (** Multi-step, requires deep reasoning *)
[@@deriving show, eq]

(** Multi-dimensional query requirements extracted from text.
    Each dimension is 0.0-1.0, computed from structural patterns. *)
type query_requirements = {
  reasoning_depth : float;
  code_ability : float;
  creativity : float;
  factual_precision : float;
  speed_priority : float;
}
[@@deriving show]

(** Agent capability scores (0.0-1.0 per dimension) *)
type agent_capabilities = {
  reasoning_score : float;
  code_score : float;
  creativity_score : float;
  factual_score : float;
  speed_score : float;
}
[@@deriving show]

(** Agent specification *)
type agent_spec = {
  name : string;
  model : string;
  capabilities : agent_capabilities;
  cost_per_1k : float;  (** Cost per 1K tokens in USD *)
}
[@@deriving show]

(** Routing decision *)
type route_decision = {
  agents : agent_spec list;
  reason : string;
  estimated_cost : float;
  complexity_score : float;
  requirements : query_requirements;
  match_scores : (string * float) list;
}
[@@deriving show]

(* ================================================================
   Default agent pool
   ================================================================ *)

let default_tiny_model_opt () =
  let split_csv_nonempty raw =
    raw
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let label_opt =
    match Sys.getenv_opt "MASC_DEFAULT_CASCADE" with
    | Some raw -> (
        match split_csv_nonempty raw with
        | first :: _ -> Some first
        | [] -> None)
    | None -> (
        match (Sys.getenv_opt "MASC_DEFAULT_PROVIDER", Sys.getenv_opt "MASC_DEFAULT_MODEL") with
        | Some provider, Some model_id ->
            let provider = String.trim provider in
            let model_id = String.trim model_id in
            if provider = "" || model_id = "" then None else Some (provider ^ ":" ^ model_id)
        | _ -> None)
  in
  match label_opt with
  | Some label -> (
      match String.index_opt label ':' with
      | Some idx when idx + 1 < String.length label ->
          Some (String.sub label (idx + 1) (String.length label - idx - 1))
      | _ -> Some label)
  | None -> None

let default_agents : agent_spec list =
  let tiny_agents =
    match default_tiny_model_opt () with
    | Some model ->
        [ { name = "default-tiny"; model;
            capabilities = { reasoning_score = 0.3; code_score = 0.4;
                             creativity_score = 0.3; factual_score = 0.5;
                             speed_score = 1.0 };
            cost_per_1k = 0.0 } ]
    | None -> []
  in
  tiny_agents @ [
    { name = "sonnet"; model = "claude-sonnet-4-6";
      capabilities = { reasoning_score = 0.7; code_score = 0.8;
                       creativity_score = 0.7; factual_score = 0.7;
                       speed_score = 0.6 };
      cost_per_1k = 0.003 };
    { name = "gpt-4o-mini"; model = "gpt-4.1-mini";
      capabilities = { reasoning_score = 0.4; code_score = 0.5;
                       creativity_score = 0.4; factual_score = 0.6;
                       speed_score = 0.8 };
      cost_per_1k = 0.00015 };
    { name = "opus"; model = "claude-opus-4-6";
      capabilities = { reasoning_score = 0.95; code_score = 0.9;
                       creativity_score = 0.9; factual_score = 0.9;
                       speed_score = 0.3 };
      cost_per_1k = 0.015 };
    { name = "gpt-4o"; model = "gpt-4.1";
      capabilities = { reasoning_score = 0.7; code_score = 0.75;
                       creativity_score = 0.6; factual_score = 0.75;
                       speed_score = 0.5 };
      cost_per_1k = 0.005 };
    { name = "o1"; model = "o1";
      capabilities = { reasoning_score = 1.0; code_score = 0.8;
                       creativity_score = 0.5; factual_score = 0.8;
                       speed_score = 0.1 };
      cost_per_1k = 0.015 };
  ]

(* ================================================================
   Pattern-based query requirement extraction
   ================================================================ *)

module Patterns = struct
  (** Compiled regex + weight pairs. Compiled once at module init. *)

  let compile pat = Re.compile (Re.Pcre.re ~flags:[`CASELESS] pat)

  let reasoning_patterns = [
    (* Causal / why questions *)
    (compile {|why\s+(?:does|is|do|are|would|can't|cannot)|}, 0.4);
    (compile {|how\s+(?:would|should|can|do)\s+(?:you|we|I)|}, 0.3);
    (* Design / tradeoff analysis *)
    (compile {|trade.?offs?|implications|consequences|pros?\s+and\s+cons?|}, 0.4);
    (compile {|compare\s+.*(?:and|vs\.?|versus)|}, 0.3);
    (* Multi-step reasoning markers *)
    (compile {|step.by.step|walk.*through|break.*down|}, 0.3);
    (* Domain complexity markers -- short queries still score high *)
    (compile {|concurren|mutex|deadlock|race\s+condition|}, 0.4);
    (compile {|distribut|byzantin|consensus|replicat|}, 0.4);
    (compile {|architect|system\s+design|design\s+pattern|}, 0.3);
    (compile {|proof|theorem|induction|invariant|formal\s+verif|}, 0.5);
    (compile {|optimi[sz]|complex|NP.hard|algorithm|}, 0.25);
    (* Multi-constraint detection *)
    (compile {|\b(?:but|however|while|although|constraint|trade)\b|}, 0.15);
  ]

  let code_patterns = [
    (* Language names *)
    (compile {|\b(?:ocaml|haskell|rust|python|typescript|javascript|java|go|c\+\+|kotlin|swift|elixir|clojure)\b|}, 0.4);
    (* Code fences *)
    (compile {|```|}, 0.5);
    (* Code artifacts in text *)
    (compile {|\b(?:def |fn |let |class |struct |interface |module )|}, 0.5);
    (* Implementation keywords *)
    (compile {|\b(?:implement|refactor|debug|compile|lint|test\s+case|unit\s+test)\b|}, 0.3);
    (compile {|\b(?:function|method|variable|API|endpoint|middleware)\b|}, 0.2);
    (compile {|\b(?:bug|error|stack\s+trace|exception|segfault)\b|}, 0.3);
  ]

  let creativity_patterns = [
    (compile {|\b(?:write|create|compose|draft)\b.*(?:story|poem|essay|article|song)|}, 0.5);
    (compile {|\b(?:imagine|brainstorm|ideate|invent)\b|}, 0.4);
    (compile {|\b(?:creative|fiction|narrative|metaphor)\b|}, 0.3);
    (compile {|\b(?:generate|suggest|propose)\b.*(?:idea|concept|name|title)|}, 0.3);
  ]

  let factual_patterns = [
    (compile {|\b(?:what\s+is|what\s+are|define|definition\s+of)\b|}, 0.4);
    (compile {|\b(?:when\s+was|who\s+(?:is|was|invented)|where\s+(?:is|was))\b|}, 0.4);
    (compile {|\b(?:list|enumerate|name\s+(?:the|all))\b|}, 0.3);
    (compile {|\b(?:fact|lookup|reference|specification)\b|}, 0.2);
  ]

  let speed_patterns = [
    (compile {|\b(?:quick|fast|brief|short|one.?liner|tldr|tl;dr)\b|}, 0.4);
    (compile {|\b(?:just|simply|only)\b|}, 0.15);
  ]

  (** Sum matched pattern weights, capped at 1.0 *)
  let score_patterns patterns text =
    let total = List.fold_left (fun acc (re, weight) ->
      if Re.execp re text then acc +. weight else acc
    ) 0.0 patterns in
    Float.min 1.0 total
end

(** Extract multi-dimensional requirements from query text. *)
let extract_requirements (query : string) : query_requirements =
  let text = String.lowercase_ascii query in
  {
    reasoning_depth = Patterns.score_patterns Patterns.reasoning_patterns text;
    code_ability = Patterns.score_patterns Patterns.code_patterns text;
    creativity = Patterns.score_patterns Patterns.creativity_patterns text;
    factual_precision = Patterns.score_patterns Patterns.factual_patterns text;
    speed_priority = Patterns.score_patterns Patterns.speed_patterns text;
  }

(* ================================================================
   Backward-compatible derived functions
   ================================================================ *)

(** Derive query_class from requirements (backward compat) *)
let classify_from_requirements (r : query_requirements) : (query_class * float) list =
  let raw = [
    (Code, r.code_ability);
    (Analysis, (r.reasoning_depth +. r.factual_precision) /. 2.0);
    (Creative, r.creativity);
    (Factual, r.factual_precision);
    (Conversation, r.speed_priority *. Float.max 0.0 (1.0 -. r.reasoning_depth));
    (Complex, r.reasoning_depth);
  ] in
  let total = List.fold_left (fun acc (_, s) -> acc +. s) 0.0 raw in
  let normalized =
    if total > 0.0
    then List.map (fun (c, s) -> (c, s /. total)) raw
    else raw
  in
  List.sort (fun (_, a) (_, b) -> compare b a) normalized

(** Classify a query into heuristic categories with confidence scores.
    Backward-compatible wrapper. *)
let classify_query (query : string) : (query_class * float) list =
  classify_from_requirements (extract_requirements query)

(** Calculate a heuristic complexity score (0.0-1.0).
    Derived from requirements instead of text length. *)
let calculate_complexity (query : string) : float =
  let r = extract_requirements query in
  let weighted =
    (r.reasoning_depth *. 0.4)
    +. (r.code_ability *. 0.2)
    +. ((1.0 -. r.speed_priority) *. 0.2)
    +. (r.creativity *. 0.1)
    +. (r.factual_precision *. 0.1)
  in
  (* Ensure "hello" stays < 0.3: zero requirements → base 0.2 from (1-0)*0.2 *)
  Float.min 1.0 weighted

(* ================================================================
   Capability-aware scoring
   ================================================================ *)

(** Cost penalty derived from actual per-token cost.
    Uses sqrt scaling to approximate the previous discrete tiers:
    $0     -> 0.0   (was Tiny: 0.0)
    $0.003 -> ~0.27 (was Medium: 0.3)
    $0.005 -> ~0.35 (was Large: 0.6, but Large penalty was too aggressive)
    $0.015 -> ~0.60 (was Giant: 0.9)
    Capped at 0.9. *)
let cost_penalty (agent : agent_spec) : float =
  if agent.cost_per_1k <= 0.0 then 0.0
  else
    let max_expected_cost = 0.015 in
    Float.min 0.9 (sqrt (agent.cost_per_1k /. max_expected_cost) *. 0.6)

(** Score an agent against query requirements.
    Returns capability match (dot product) minus cost penalty.
    Cost penalty decreases as complexity increases. *)
let score_agent ~(requirements : query_requirements) ~(complexity : float)
    (agent : agent_spec) : float =
  let c = agent.capabilities in
  let r = requirements in
  let match_score =
    (r.reasoning_depth *. c.reasoning_score)
    +. (r.code_ability *. c.code_score)
    +. (r.creativity *. c.creativity_score)
    +. (r.factual_precision *. c.factual_score)
    +. (r.speed_priority *. c.speed_score)
  in
  let cost_sensitivity = 1.0 -. (complexity *. 0.7) in
  let penalty = cost_penalty agent *. cost_sensitivity in
  match_score -. penalty

(* ================================================================
   Agent selection and routing
   ================================================================ *)

(** Select agents using capability-aware sparse tier selection.
    2 agents normally, 3 for high complexity. *)
let select_agents
    ?(agents = default_agents)
    ?(max_agents = 3)
    (query : string) : agent_spec list =
  let requirements = extract_requirements query in
  let complexity = calculate_complexity query in
  let scored = List.map (fun a ->
    (a, score_agent ~requirements ~complexity a)
  ) agents in
  let sorted = List.sort (fun (_, a) (_, b) -> compare b a) scored in
  let n =
    if complexity > 0.7 then min max_agents 3
    else 2
  in
  sorted
  |> List.filteri (fun i _ -> i < n)
  |> List.map fst

(** Estimate cost for a routing decision *)
let estimate_cost
    ?(input_tokens = 1000)
    ?(output_tokens = 500)
    (agents : agent_spec list) : float =
  let total_tokens = input_tokens + output_tokens in
  List.fold_left (fun acc agent ->
    acc +. (agent.cost_per_1k *. float_of_int total_tokens /. 1000.0)
  ) 0.0 agents

(** Generate a user-facing explanation of the routing result. *)
let generate_reason (query : string) (agents : agent_spec list) : string =
  let classifications = classify_query query in
  let top_class = match classifications with
    | (cls, _) :: _ -> show_query_class cls
    | [] -> "Unknown"
  in
  let agent_names = String.concat ", " (List.map (fun a -> a.name) agents) in
  let costs =
    agents
    |> List.map (fun a -> Printf.sprintf "$%.4f/1k" a.cost_per_1k)
    |> String.concat ", "
  in
  Printf.sprintf "Heuristic query class: %s | Agents: [%s] | Costs: %s"
    top_class agent_names costs

(** Main routing function *)
let route
    ?(agents = default_agents)
    ?(max_agents = 3)
    ?(input_tokens = 1000)
    ?(output_tokens = 500)
    (query : string) : route_decision =
  let requirements = extract_requirements query in
  let complexity = calculate_complexity query in
  let selected = select_agents ~agents ~max_agents query in
  let cost = estimate_cost ~input_tokens ~output_tokens selected in
  let reason = generate_reason query selected in
  let match_scores = List.map (fun a ->
    (a.name, score_agent ~requirements ~complexity a)
  ) selected in
  { agents = selected; reason; estimated_cost = cost;
    complexity_score = complexity; requirements; match_scores }

(** Statistics: track the observed routing tier mix. *)
module Stats = struct
  type routing_stats = {
    mutable total_queries : int;
    mutable small_only : int;
    mutable has_large : int;
  }

  let global_stats = {
    total_queries = 0;
    small_only = 0;
    has_large = 0;
  }

  let record (decision : route_decision) : unit =
    global_stats.total_queries <- global_stats.total_queries + 1;
    let has_big = List.exists (fun a ->
      a.cost_per_1k >= 0.005
    ) decision.agents in
    if has_big
    then global_stats.has_large <- global_stats.has_large + 1
    else global_stats.small_only <- global_stats.small_only + 1

  let get_ratio () : float * float =
    let total = float_of_int global_stats.total_queries in
    if total = 0.0 then (0.0, 0.0)
    else (
      float_of_int global_stats.small_only /. total,
      float_of_int global_stats.has_large /. total
    )

  let reset () : unit =
    global_stats.total_queries <- 0;
    global_stats.small_only <- 0;
    global_stats.has_large <- 0
end

(** Route and record stats *)
let route_with_stats
    ?(agents = default_agents)
    ?(max_agents = 3)
    ?(input_tokens = 1000)
    ?(output_tokens = 500)
    (query : string) : route_decision =
  let decision = route ~agents ~max_agents ~input_tokens ~output_tokens query in
  Stats.record decision;
  decision
