(** Chain Types - Core type definitions for Chain DSL

    This module defines the fundamental types for the Chain Engine:
    - {!node_type}: The 21 supported node types
    - {!node}: A single execution unit
    - {!chain}: A complete chain definition
    - {!chain_result}: The result of chain execution

    @author Chain Engine
    @since 0.2.0
*)

(** {1 Direction} *)

(** Mermaid diagram direction for visualization *)
type direction =
  | LR  (** Left to Right - horizontal flow *)
  | RL  (** Right to Left - reverse horizontal *)
  | TB  (** Top to Bottom - vertical/hierarchical *)
  | BT  (** Bottom to Top - reverse vertical *)

val direction_to_yojson : direction -> Yojson.Safe.t
val direction_of_yojson : Yojson.Safe.t -> (direction, string) result
val direction_to_string : direction -> string
val direction_of_string : string -> direction

(** P1.3: Consensus mode for Quorum nodes *)
type consensus_mode =
  | Count of int            (** At least N successes required *)
  | Majority                (** More than half must succeed (> n/2) *)
  | Unanimous               (** All nodes must succeed *)
  | Weighted of float       (** Weighted sum >= threshold *)

val consensus_mode_to_yojson : consensus_mode -> Yojson.Safe.t
val consensus_mode_of_yojson : Yojson.Safe.t -> (consensus_mode, string) result
val consensus_mode_to_string : consensus_mode -> string
val consensus_mode_of_string : string -> consensus_mode

(** {1 Configuration} *)

(** Configuration for chain execution *)
type chain_config = {
  max_depth : int;        (** Maximum recursion depth for subgraphs *)
  max_concurrency : int;  (** Max parallel executions per model *)
  timeout : int;          (** Default timeout in seconds *)
  trace : bool;           (** Enable execution tracing *)
  direction : direction;  (** Mermaid diagram direction *)
}

val chain_config_to_yojson : chain_config -> Yojson.Safe.t
val chain_config_of_yojson : Yojson.Safe.t -> (chain_config, string) result

(** Default configuration values *)
val default_config : chain_config

(** {1 Strategy Types} *)

(** Merge strategy for combining parallel results *)
type merge_strategy =
  | First           (** Take first successful result *)
  | Last            (** Take last successful result *)
  | Concat          (** Concatenate all results *)
  | WeightedAvg     (** Weighted average (for numeric) *)
  | Custom of string  (** Custom merge function name *)

val merge_strategy_to_yojson : merge_strategy -> Yojson.Safe.t
val merge_strategy_of_yojson : Yojson.Safe.t -> (merge_strategy, string) result

(** Threshold comparison operators *)
type threshold_op =
  | Gt   (** > greater than *)
  | Gte  (** >= greater than or equal *)
  | Lt   (** < less than *)
  | Lte  (** <= less than or equal *)
  | Eq   (** = equal *)
  | Neq  (** != not equal *)

val threshold_op_to_yojson : threshold_op -> Yojson.Safe.t
val threshold_op_of_yojson : Yojson.Safe.t -> (threshold_op, string) result

(** Selection strategy for Evaluator node *)
type select_strategy =
  | Best              (** Select highest score *)
  | Worst             (** Select lowest score *)
  | AboveThreshold of float  (** First candidate above threshold *)
  | WeightedRandom    (** Random selection weighted by scores *)

val select_strategy_to_yojson : select_strategy -> Yojson.Safe.t
val select_strategy_of_yojson : Yojson.Safe.t -> (select_strategy, string) result

(** Configuration for evaluator in FeedbackLoop *)
type evaluator_config = {
  scoring_func : string;
  scoring_prompt : string option;
  select_strategy : select_strategy;
}

val evaluator_config_to_yojson : evaluator_config -> Yojson.Safe.t
val evaluator_config_of_yojson : Yojson.Safe.t -> (evaluator_config, string) result

(** Result of evaluation with optional feedback *)
type evaluator_result = {
  score : float;
  feedback : string option;
  selected_output : string;
  selected_id : string;
}

val evaluator_result_to_yojson : evaluator_result -> Yojson.Safe.t
val evaluator_result_of_yojson : Yojson.Safe.t -> (evaluator_result, string) result

(** Backoff strategy for Retry node *)
type backoff_strategy =
  | Constant of float         (** Fixed delay between retries *)
  | Exponential of float      (** Exponential backoff *)
  | Linear of float           (** Linear backoff *)
  | Jitter of float * float   (** Random between min and max *)

val backoff_strategy_to_yojson : backoff_strategy -> Yojson.Safe.t
val backoff_strategy_of_yojson : Yojson.Safe.t -> (backoff_strategy, string) result

(** {1 Adapter Transforms} *)

(** Adapter transformation types for inter-node data refinement *)
type adapter_transform =
  | Extract of string              (** Extract JSON field *)
  | Template of string             (** Apply template *)
  | Summarize of int               (** Summarize with max tokens *)
  | Truncate of int                (** Truncate to max characters *)
  | JsonPath of string             (** JSONPath query *)
  | Regex of string * string       (** Regex match and replace *)
  | ValidateSchema of string       (** Validate against JSON schema *)
  | ParseJson                      (** Parse string as JSON *)
  | Stringify                      (** Convert JSON to string *)
  | Chain of adapter_transform list  (** Chain multiple transforms *)
  | Conditional of {
      condition : string;
      on_true : adapter_transform;
      on_false : adapter_transform;
    }
  | Split of {
      delimiter : string;
      chunk_size : int;
      overlap : int;
    }
  | Custom of string               (** Custom function name *)

val adapter_transform_to_yojson : adapter_transform -> Yojson.Safe.t
val adapter_transform_of_yojson : Yojson.Safe.t -> (adapter_transform, string) result

(** {1 MCTS Policy} *)

(** MCTS selection policy for tree search *)
type mcts_policy =
  | UCB1 of float                 (** UCB1 with exploration constant c *)
  | Greedy                        (** Always select highest score *)
  | EpsilonGreedy of float        (** Random with probability epsilon *)
  | Softmax of float              (** Temperature-based selection *)

val mcts_policy_to_yojson : mcts_policy -> Yojson.Safe.t
val mcts_policy_of_yojson : Yojson.Safe.t -> (mcts_policy, string) result

(** {1 Cascade Types} *)

type confidence_level = High | Medium | Low

val confidence_level_to_yojson : confidence_level -> Yojson.Safe.t
val confidence_level_of_yojson : Yojson.Safe.t -> (confidence_level, string) result
val confidence_to_float : confidence_level -> float
val confidence_of_string : string -> confidence_level

type context_mode = CM_None | CM_Summary | CM_Full

val context_mode_to_yojson : context_mode -> Yojson.Safe.t
val context_mode_of_yojson : Yojson.Safe.t -> (context_mode, string) result
val context_mode_to_string : context_mode -> string
val context_mode_of_string : string -> context_mode

(** {1 Core Types} *)

(** The 23 supported node types (including Cascade) *)
type node_type =
  | Llm of {
      model : string;
      system : string option;
      prompt : string;
      timeout : int option;
      tools : Yojson.Safe.t option;
      prompt_ref : string option;
      prompt_vars : (string * string) list;
      thinking : bool;    (** Enable thinking/reasoning mode for GLM models *)
    }
  | Tool of { name : string; args : Yojson.Safe.t }
  | Pipeline of node list
  | Fanout of node list
  | Quorum of { consensus : consensus_mode; nodes : node list; weights : (string * float) list }
  | Gate of { condition : string; then_node : node; else_node : node option }
  | Subgraph of chain
  | ChainRef of string
  | Map of { func : string; inner : node }
  | Bind of { func : string; inner : node }
  | Merge of { strategy : merge_strategy; nodes : node list }
  | Threshold of {
      metric : string;
      operator : threshold_op;
      value : float;
      input_node : node;
      on_pass : node option;
      on_fail : node option;
    }
  | GoalDriven of {
      goal_metric : string;
      goal_operator : threshold_op;
      goal_value : float;
      action_node : node;
      measure_func : string;
      max_iterations : int;
      strategy_hints : (string * string) list;
      conversational : bool;
      relay_models : string list;
    }
  | Evaluator of {
      candidates : node list;
      scoring_func : string;
      scoring_prompt : string option;
      select_strategy : select_strategy;
      min_score : float option;
    }
  | Retry of {
      node : node;
      max_attempts : int;
      backoff : backoff_strategy;
      retry_on : string list;
    }
  | Fallback of { primary : node; fallbacks : node list }
  | Race of { nodes : node list; timeout : float option }
  | ChainExec of {
      chain_source : string;
      validate : bool;
      max_depth : int;
      sandbox : bool;
      context_inject : (string * string) list;
      pass_outputs : bool;
    }
  | Adapter of {
      input_ref : string;
      transform : adapter_transform;
      on_error : [ `Fail | `Passthrough | `Default of string ];
    }
  | Cache of { key_expr : string; ttl_seconds : int; inner : node }
  | Batch of {
      batch_size : int;
      parallel : bool;
      inner : node;
      collect_strategy : [ `List | `Concat | `First | `Last ];
    }
  | Spawn of {
      clean : bool;
      inner : node;
      pass_vars : string list;
      inherit_cache : bool;
    }
  | Mcts of {
      strategies : node list;
      simulation : node;
      evaluator : string;
      evaluator_prompt : string option;
      policy : mcts_policy;
      max_iterations : int;
      max_depth : int;
      expansion_threshold : int;
      early_stop : float option;
      parallel_sims : int;
    }
  | StreamMerge of {
      nodes : node list;
      reducer : merge_strategy;
      initial : string;
      min_results : int option;
      timeout : float option;
    }
  | FeedbackLoop of {
      generator : node;
      evaluator_config : evaluator_config;
      improver_prompt : string;
      max_iterations : int;
      score_threshold : float;
      score_operator : threshold_op;
      conversational : bool;
      relay_models : string list;
    }
  | Masc_broadcast of {
      message : string;
      room : string option;
      mention : string list;
    }
  | Masc_listen of {
      filter : string option;
      timeout_sec : float;
      room : string option;
    }
  | Masc_claim of {
      task_id : string option;
      room : string option;
    }
  | Cascade of {
      tiers : cascade_tier list;
      confidence_prompt : string option;
      max_escalations : int;
      context_mode : context_mode;
      task_hint : string option;
      default_threshold : float;
    }

(** A single execution node *)
and node = {
  id : string;
  node_type : node_type;
  input_mapping : (string * string) list;
  output_key : string option;
  depends_on : string list option;
}

and cascade_tier = {
  tier_node : node;
  tier_index : int;
  confidence_threshold : float;
  cost_weight : float;
  pass_context : bool;
}

(** A complete chain definition *)
and chain = {
  id : string;
  nodes : node list;
  output : string;
  config : chain_config;
  name : string option;
  description : string option;
  version : string option;
  input_schema : Yojson.Safe.t option;
  output_schema : Yojson.Safe.t option;
  metadata : Yojson.Safe.t option;
}

(** Create a chain with default optional fields *)
val make_chain :
  id:string ->
  nodes:node list ->
  output:string ->
  ?config:chain_config ->
  ?name:string ->
  ?description:string ->
  ?version:string ->
  ?input_schema:Yojson.Safe.t ->
  ?output_schema:Yojson.Safe.t ->
  ?metadata:Yojson.Safe.t ->
  unit -> chain

val node_type_to_yojson : node_type -> Yojson.Safe.t
val node_type_of_yojson : Yojson.Safe.t -> (node_type, string) result
val node_to_yojson : node -> Yojson.Safe.t
val node_of_yojson : Yojson.Safe.t -> (node, string) result
val chain_to_yojson : chain -> Yojson.Safe.t
val chain_of_yojson : Yojson.Safe.t -> (chain, string) result
val cascade_tier_to_yojson : cascade_tier -> Yojson.Safe.t
val cascade_tier_of_yojson : Yojson.Safe.t -> (cascade_tier, string) result

(** {1 Execution Results} *)

(** A single trace entry for debugging *)
type trace_entry = {
  node_id : string;
  node_type_name : string;
  start_time : float;
  end_time : float;
  status : [ `Success | `Failure | `Skipped ];
  output_preview : string option;
  error : string option;
}

val trace_entry_to_yojson : trace_entry -> Yojson.Safe.t
val trace_entry_of_yojson : Yojson.Safe.t -> (trace_entry, string) result

(** Token usage tracking *)
type token_usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
  estimated_cost_usd : float;
}

val token_usage_to_yojson : token_usage -> Yojson.Safe.t
val token_usage_of_yojson : Yojson.Safe.t -> (token_usage, string) result
val empty_token_usage : token_usage

(** Result of chain execution *)
type chain_result = {
  chain_id : string;
  output : string;
  success : bool;
  trace : trace_entry list;
  token_usage : token_usage;
  duration_ms : int;
  metadata : (string * string) list;
}

val chain_result_to_yojson : chain_result -> Yojson.Safe.t
val chain_result_of_yojson : Yojson.Safe.t -> (chain_result, string) result

(** Execution plan produced by compiler *)
type execution_plan = {
  chain : chain;
  execution_order : string list;
  parallel_groups : string list list;
  depth : int;
}

val execution_plan_to_yojson : execution_plan -> Yojson.Safe.t
val execution_plan_of_yojson : Yojson.Safe.t -> (execution_plan, string) result

(** {1 Helper Functions} *)

val node_type_name : node_type -> string
val make_llm_node : id:string -> model:string -> ?system:string -> prompt:string -> ?timeout:int -> ?tools:Yojson.Safe.t -> ?prompt_ref:string -> ?prompt_vars:(string * string) list -> ?thinking:bool -> unit -> node
val make_adapter : id:string -> input_ref:string -> transform:adapter_transform -> ?on_error:[ `Fail | `Passthrough | `Default of string ] -> unit -> node
val make_tool_node : id:string -> name:string -> args:Yojson.Safe.t -> node
val make_pipeline : id:string -> node list -> node
val make_fanout : id:string -> node list -> node
val make_quorum : id:string -> ?consensus:consensus_mode -> ?weights:(string * float) list -> node list -> node
val make_threshold : id:string -> metric:string -> operator:threshold_op -> value:float -> input_node:node -> ?on_pass:node -> ?on_fail:node -> unit -> node
val make_goal_driven : id:string -> goal_metric:string -> goal_operator:threshold_op -> goal_value:float -> action_node:node -> measure_func:string -> max_iterations:int -> ?strategy_hints:(string * string) list -> ?conversational:bool -> ?relay_models:string list -> unit -> node
val make_evaluator : id:string -> candidates:node list -> scoring_func:string -> ?scoring_prompt:string -> select_strategy:select_strategy -> ?min_score:float -> unit -> node
val make_retry : id:string -> node:node -> max_attempts:int -> ?backoff:backoff_strategy -> ?retry_on:string list -> unit -> node
val make_fallback : id:string -> primary:node -> fallbacks:node list -> node
val make_race : id:string -> nodes:node list -> ?timeout:float -> unit -> node
val make_feedback_loop : id:string -> generator:node -> evaluator_config:evaluator_config -> improver_prompt:string -> max_iterations:int -> score_threshold:float -> ?score_operator:threshold_op -> ?conversational:bool -> ?relay_models:string list -> unit -> node
val make_cascade : id:string -> tiers:cascade_tier list -> ?confidence_prompt:string option -> ?max_escalations:int -> ?context_mode:context_mode -> ?task_hint:string -> ?default_threshold:float -> unit -> node

(** {1 Batch Execution Types} *)

type batch_priority = High | Normal | Low

val batch_priority_to_yojson : batch_priority -> Yojson.Safe.t
val batch_priority_of_yojson : Yojson.Safe.t -> (batch_priority, string) result

type retry_config = {
  max_retries : int;
  initial_delay_ms : int;
  backoff_multiplier : float;
  max_delay_ms : int;
}

val retry_config_to_yojson : retry_config -> Yojson.Safe.t
val retry_config_of_yojson : Yojson.Safe.t -> (retry_config, string) result
val default_retry_config : retry_config

type batch_config = {
  batch_max_concurrent : int;
  rate_limit_per_min : int;
  retry_policy : retry_config;
  priority : batch_priority;
}

val batch_config_to_yojson : batch_config -> Yojson.Safe.t
val batch_config_of_yojson : Yojson.Safe.t -> (batch_config, string) result
val default_batch_config : batch_config

type batch_stats = {
  total_chains : int;
  completed : int;
  failed : int;
  total_duration_ms : int;
  total_tokens : Chain_category.token_usage;
  avg_duration_ms : float;
}

val batch_stats_to_yojson : batch_stats -> Yojson.Safe.t
val batch_stats_of_yojson : Yojson.Safe.t -> (batch_stats, string) result

type batch_result = {
  batch_id : string;
  results : (string * chain_result) list;
  stats : batch_stats;
  failed_chains : (string * string) list;
}

val batch_result_to_yojson : batch_result -> Yojson.Safe.t
val batch_result_of_yojson : Yojson.Safe.t -> (batch_result, string) result

(** {1 Utility Functions} *)

val count_parallel_groups : node -> int
val count_chain_parallel_groups : chain -> int
