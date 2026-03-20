(** MoE-style MODEL Router for Jiphyeon
    
    Sparse activation with 90% small / 10% large model target *)

(** {1 Types} *)

type query_class =
  | Code
  | Analysis
  | Creative
  | Factual
  | Conversation
  | Complex
[@@deriving show, eq]

type model_tier =
  | Tiny
  | Small
  | Medium
  | Large
  | Giant
[@@deriving show, eq]

type agent_spec = {
  name : string;
  model : string;
  tier : model_tier;
  strengths : query_class list;
  cost_per_1k : float;
}
[@@deriving show]

type route_decision = {
  agents : agent_spec list;
  reason : string;
  estimated_cost : float;
  complexity_score : float;
}
[@@deriving show]

(** {1 Agent Pool} *)

val default_agents : agent_spec list

(** {1 Core Functions} *)

val classify_query : string -> (query_class * float) list
(** Classify a query into categories with confidence scores.
    Returns list sorted by confidence descending. *)

val calculate_complexity : string -> float
(** Calculate complexity score (0.0-1.0) for a query. *)

val select_agents : 
  ?agents:agent_spec list -> 
  ?max_agents:int -> 
  string -> 
  agent_spec list
(** Select 2-3 agents using sparse activation (MoE style).
    @param agents Agent pool to select from (default: default_agents)
    @param max_agents Maximum agents to select (default: 3) *)

val estimate_cost : 
  ?input_tokens:int -> 
  ?output_tokens:int -> 
  agent_spec list -> 
  float
(** Estimate cost in USD for routing decision.
    @param input_tokens Expected input tokens (default: 1000)
    @param output_tokens Expected output tokens (default: 500) *)

val route : 
  ?agents:agent_spec list ->
  ?max_agents:int ->
  ?input_tokens:int ->
  ?output_tokens:int ->
  string -> 
  route_decision
(** Main routing function. Returns optimal routing decision. *)

(** {1 Statistics} *)

module Stats : sig
  type routing_stats = {
    mutable total_queries : int;
    mutable small_only : int;
    mutable has_large : int;
  }

  val global_stats : routing_stats
  val record : route_decision -> unit
  val get_ratio : unit -> float * float
  (** Returns (small_ratio, large_ratio) - target is (0.9, 0.1) *)
  val reset : unit -> unit
end

val route_with_stats :
  ?agents:agent_spec list ->
  ?max_agents:int ->
  ?input_tokens:int ->
  ?output_tokens:int ->
  string ->
  route_decision
(** Route and record stats for 90/10 tracking *)
