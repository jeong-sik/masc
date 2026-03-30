(** Heuristic query router with sparse tier selection.

    This module uses deterministic keyword/length heuristics to classify a
    query and then picks 2-3 agents from a static pool. It is not an
    LLM-routed MoE system. *)

(** Query classification categories *)
type query_class =
  | Code         (** Programming, debugging, implementation *)
  | Analysis     (** Data analysis, reasoning, evaluation *)
  | Creative     (** Writing, ideation, brainstorming *)
  | Factual      (** Facts, lookup, definitions *)
  | Conversation (** Chat, casual dialogue *)
  | Complex      (** Multi-step, requires deep reasoning *)
[@@deriving show, eq]

(** Model tier for cost management *)
type model_tier =
  | Tiny   (** Lowest-cost tier *)
  | Small  (** Low-cost tier *)
  | Medium (** Mid-cost tier *)
  | Large  (** High-cost tier *)
  | Giant  (** Highest-cost tier *)
[@@deriving show, eq]

(** Agent specification *)
type agent_spec = {
  name : string;
  model : string;
  tier : model_tier;
  strengths : query_class list;
  cost_per_1k : float;  (** Cost per 1K tokens in USD *)
}
[@@deriving show]

(** Routing decision *)
type route_decision = {
  agents : agent_spec list;
  reason : string;
  estimated_cost : float;
  complexity_score : float;  (** Heuristic 0.0-1.0 score *)
}
[@@deriving show]

(** Default agent pool - configurable *)
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
        [ { name = "default-tiny"; model; tier = Tiny;
            strengths = [Factual; Conversation; Code; Analysis; Creative];
            cost_per_1k = 0.0 } ]
    | None -> []
  in
  (* NOTE: model IDs here are defaults for the council sub-library which cannot
     access Env_config_governance. Update these when model generations change. *)
  tiny_agents @ [
    { name = "sonnet"; model = "claude-sonnet-4-6"; tier = Medium;
      strengths = [Code; Analysis; Creative]; cost_per_1k = 0.003 };
    { name = "gpt-4o-mini"; model = "gpt-4.1-mini"; tier = Medium;
      strengths = [Conversation; Factual; Analysis]; cost_per_1k = 0.00015 };
    { name = "opus"; model = "claude-opus-4-6"; tier = Large;
      strengths = [Complex; Analysis; Creative; Code]; cost_per_1k = 0.015 };
    { name = "gpt-4o"; model = "gpt-4.1"; tier = Large;
      strengths = [Complex; Analysis; Code]; cost_per_1k = 0.005 };
    { name = "o1"; model = "o1"; tier = Giant;
      strengths = [Complex; Analysis; Code]; cost_per_1k = 0.015 };
  ]

(** Feature extraction from query text *)
module Features = struct
  let code_indicators = [
    "code"; "function"; "implement"; "debug"; "error"; "compile";
    "syntax"; "bug"; "class"; "method"; "variable"; "type";
    "ocaml"; "python"; "typescript"; "rust"; "javascript";
  ]

  let analysis_indicators = [
    "analyze"; "compare"; "evaluate"; "assess"; "review";
    "why"; "how"; "explain"; "understand"; "reason";
  ]

  let creative_indicators = [
    "write"; "create"; "imagine"; "story"; "poem"; "design";
    "brainstorm"; "idea"; "suggest"; "generate";
  ]

  let complex_indicators = [
    "step by step"; "multi"; "complex"; "detailed"; "thorough";
    "plan"; "architecture"; "system"; "design pattern";
  ]

  let contains_any words text =
    let lower = String.lowercase_ascii text in
    List.exists (fun w ->
      let pattern = String.lowercase_ascii w in
      let re = Re.str pattern |> Re.compile in
      Re.execp re lower
    ) words

  let count_matches words text =
    let lower = String.lowercase_ascii text in
    List.fold_left (fun acc w ->
      let pattern = String.lowercase_ascii w in
      let re = Re.str pattern |> Re.compile in
      if Re.execp re lower then acc + 1 else acc
    ) 0 words
end

(** Classify a query into heuristic categories with confidence scores. *)
let classify_query (query : string) : (query_class * float) list =
  let len = String.length query in
  let scores = [
    (Code, float_of_int (Features.count_matches Features.code_indicators query) *. 0.3);
    (Analysis, float_of_int (Features.count_matches Features.analysis_indicators query) *. 0.25);
    (Creative, float_of_int (Features.count_matches Features.creative_indicators query) *. 0.25);
    (Complex, float_of_int (Features.count_matches Features.complex_indicators query) *. 0.4);
    (Factual, if len < 50 then 0.3 else 0.1);
    (Conversation, if len < 100 && not (Features.contains_any Features.code_indicators query) 
                   then 0.2 else 0.05);
  ] in
  (* Normalize and sort by score descending *)
  let total = List.fold_left (fun acc (_, s) -> acc +. s) 0.0 scores in
  let normalized = 
    if total > 0.0 
    then List.map (fun (c, s) -> (c, s /. total)) scores
    else scores 
  in
  List.sort (fun (_, a) (_, b) -> compare b a) normalized

(** Calculate a heuristic complexity score (0.0-1.0). *)
let calculate_complexity (query : string) : float =
  let len = String.length query in
  let has_complex = Features.contains_any Features.complex_indicators query in
  let question_count = 
    List.length (String.split_on_char '?' query) - 1 in
  let base = 
    if len > 500 then 0.6
    else if len > 200 then 0.4
    else if len > 100 then 0.2
    else 0.1
  in
  let complexity_bonus = if has_complex then 0.3 else 0.0 in
  let question_bonus = Float.min 0.2 (float_of_int question_count *. 0.1) in
  Float.min 1.0 (base +. complexity_bonus +. question_bonus)

(** Select agents using deterministic sparse tier selection.

    Strategy:
    - Default to 2 agents
    - Expand to 3 agents for higher heuristic complexity *)
let select_agents 
    ?(agents = default_agents) 
    ?(max_agents = 3) 
    (query : string) : agent_spec list =
  let classifications = classify_query query in
  let complexity = calculate_complexity query in
  
  (* Get top 2 query classes *)
  let top_classes = 
    classifications 
    |> List.filter (fun (_, score) -> score > 0.1)
    |> List.map fst
    |> (fun l -> match l with a :: b :: _ -> [a; b] | _ -> l)
  in
  
  (* Score each agent by strength match *)
  let score_agent (agent : agent_spec) : float =
    let strength_score = 
      List.fold_left (fun acc cls ->
        if List.mem cls agent.strengths then acc +. 1.0 else acc
      ) 0.0 top_classes
    in
    (* Prefer cheaper models unless complexity is high *)
    let tier_penalty = match agent.tier with
      | Tiny -> 0.0
      | Small -> 0.1
      | Medium -> 0.3
      | Large -> if complexity > 0.6 then 0.2 else 0.6
      | Giant -> if complexity > 0.8 then 0.3 else 0.9
    in
    strength_score -. tier_penalty
  in
  
  (* Sort by score and take top N *)
  let scored = List.map (fun a -> (a, score_agent a)) agents in
  let sorted = List.sort (fun (_, a) (_, b) -> compare b a) scored in
  
  (* Sparse activation: 2-3 agents *)
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

(** Generate a user-facing explanation of the heuristic routing result. *)
let generate_reason (query : string) (agents : agent_spec list) : string =
  let classifications = classify_query query in
  let top_class = match classifications with
    | (cls, _) :: _ -> show_query_class cls
    | [] -> "Unknown"
  in
  let agent_names = String.concat ", " (List.map (fun a -> a.name) agents) in
  let tiers = 
    agents 
    |> List.map (fun a -> show_model_tier a.tier)
    |> List.sort_uniq String.compare
    |> String.concat "/"
  in
  Printf.sprintf "Heuristic query class: %s | Agents: [%s] | Tiers: %s"
    top_class agent_names tiers

(** Main routing function *)
let route 
    ?(agents = default_agents)
    ?(max_agents = 3)
    ?(input_tokens = 1000)
    ?(output_tokens = 500)
    (query : string) : route_decision =
  let selected = select_agents ~agents ~max_agents query in
  let complexity = calculate_complexity query in
  let cost = estimate_cost ~input_tokens ~output_tokens selected in
  let reason = generate_reason query selected in
  { agents = selected; reason; estimated_cost = cost; complexity_score = complexity }

(** Statistics: track the observed routing tier mix. *)
module Stats = struct
  type routing_stats = {
    mutable total_queries : int;
    mutable small_only : int;    (** Tiny/Small tiers only *)
    mutable has_large : int;     (** At least one Large/Giant *)
  }

  let global_stats = {
    total_queries = 0;
    small_only = 0;
    has_large = 0;
  }

  let record (decision : route_decision) : unit =
    global_stats.total_queries <- global_stats.total_queries + 1;
    let has_big = List.exists (fun a -> 
      match a.tier with Large | Giant -> true | _ -> false
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
