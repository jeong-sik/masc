(** Chain Types - Core type definitions for Chain DSL

    This module defines the fundamental types for the Chain Engine:
    - node_type: The 21 supported node types (Llm, Tool, Pipeline, Cache, Batch, etc.)
    - node: A single execution unit with id and type
    - chain: A complete chain definition with nodes and config
    - chain_result: The result of chain execution

    Category theory concepts:
    - Functor (map): Transform node outputs
    - Monad (bind): Sequential dependencies
    - Monoid (merge): Combine parallel results
*)

(** Mermaid diagram direction for visualization *)
type direction =
  | LR  (** Left to Right - horizontal flow *)
  | RL  (** Right to Left - reverse horizontal *)
  | TB  (** Top to Bottom - vertical/hierarchical *)
  | BT  (** Bottom to Top - reverse vertical *)
[@@deriving yojson]

let direction_to_string = function
  | LR -> "LR" | RL -> "RL" | TB -> "TB" | BT -> "BT"

let direction_of_string = function
  | "LR" -> LR | "RL" -> RL
  | "TB" | "TD" -> TB  (* TD is alias for TB *)
  | "BT" -> BT
  | _ -> LR  (* default *)

(** P1.3: Consensus mode for Quorum nodes *)
type consensus_mode =
  | Count of int            (** At least N successes required *)
  | Majority                (** More than half must succeed (> n/2) *)
  | Unanimous               (** All nodes must succeed *)
  | Weighted of float       (** Weighted sum >= threshold (weights default to 1.0) *)
[@@deriving yojson]

let consensus_mode_to_string = function
  | Count n -> Printf.sprintf "count:%d" n
  | Majority -> "majority"
  | Unanimous -> "unanimous"
  | Weighted t -> Printf.sprintf "weighted:%.2f" t

let consensus_mode_of_string s =
  let s = String.lowercase_ascii (String.trim s) in
  if s = "majority" then Majority
  else if s = "unanimous" then Unanimous
  else if String.length s > 9 && String.sub s 0 9 = "weighted:" then
    let threshold = String.sub s 9 (String.length s - 9) in
    Weighted (try float_of_string threshold with _ -> 0.5)
  else
    (* Default: parse as count *)
    Count (try int_of_string s with _ -> 1)

(** Configuration for chain execution *)
type chain_config = {
  max_depth : int;        (** Maximum recursion depth for subgraphs *)
  max_concurrency : int;  (** Max parallel executions per model *)
  timeout : int;          (** Default timeout in seconds *)
  trace : bool;           (** Enable execution tracing *)
  direction : direction;  (** Mermaid diagram direction for WYSIWYE *)
}
[@@deriving yojson]

(** Default configuration values *)
let default_config = {
  max_depth = 8;  (* Increased for MCTS support which has nested structures *)
  max_concurrency = 3;
  timeout = 300;
  trace = false;
  direction = LR;
}

(** Merge strategy for combining parallel results *)
type merge_strategy =
  | First           (** Take first successful result *)
  | Last            (** Take last successful result *)
  | Concat          (** Concatenate all results *)
  | WeightedAvg     (** Weighted average (for numeric) *)
  | Custom of string  (** Custom merge function name *)
[@@deriving yojson]

(** Threshold comparison operators *)
type threshold_op =
  | Gt   (** > greater than *)
  | Gte  (** >= greater than or equal *)
  | Lt   (** < less than *)
  | Lte  (** <= less than or equal *)
  | Eq   (** = equal *)
  | Neq  (** != not equal *)
[@@deriving yojson]

(** Selection strategy for Evaluator node *)
type select_strategy =
  | Best              (** Select highest score *)
  | Worst             (** Select lowest score (for debugging) *)
  | AboveThreshold of float  (** First candidate above threshold *)
  | WeightedRandom    (** Random selection weighted by scores *)
[@@deriving yojson]

(** Configuration for evaluator in FeedbackLoop *)
type evaluator_config = {
  scoring_func : string;             (** Scoring function: "llm_judge", "regex_match", etc. *)
  scoring_prompt : string option;    (** Prompt for LLM judge scoring *)
  select_strategy : select_strategy; (** Selection strategy *)
}
[@@deriving yojson]

(** Result of evaluation with optional feedback *)
type evaluator_result = {
  score : float;               (** Score from 0.0 to 1.0 *)
  feedback : string option;    (** Feedback for improvement (generated when score < min_score) *)
  selected_output : string;    (** The selected output content *)
  selected_id : string;        (** ID of the selected candidate *)
}
[@@deriving yojson]

(** Backoff strategy for Retry node *)
type backoff_strategy =
  | Constant of float         (** Fixed delay between retries (seconds) *)
  | Exponential of float      (** Exponential backoff: base * 2^attempt *)
  | Linear of float           (** Linear backoff: base * attempt *)
  | Jitter of float * float   (** Random between min and max *)
[@@deriving yojson]

(** Adapter transformation types for inter-node data refinement *)
type adapter_transform =
  | Extract of string              (** Extract JSON field: "data.items[0].name" *)
  | Template of string             (** Apply template: "Result: {{value}}" *)
  | Summarize of int               (** Summarize with max tokens *)
  | Truncate of int                (** Truncate to max characters *)
  | JsonPath of string             (** JSONPath query *)
  | Regex of string * string       (** Regex match and replace: (pattern, replacement) *)
  | ValidateSchema of string       (** Validate against JSON schema name *)
  | ParseJson                      (** Parse string as JSON *)
  | Stringify                      (** Convert JSON to string *)
  | Chain of adapter_transform list  (** Chain multiple transforms *)
  | Conditional of {
      condition : string;          (** Condition expression *)
      on_true : adapter_transform;
      on_false : adapter_transform;
    }
  | Split of {
      delimiter : string;          (** Split delimiter: "line", "paragraph", "sentence", or custom string *)
      chunk_size : int;            (** Max chunk size in estimated tokens (chars/4) *)
      overlap : int;               (** Overlap between chunks in estimated tokens *)
    }
  | Custom of string               (** Custom function name *)
[@@deriving yojson]

(** MCTS selection policy for tree search *)
type mcts_policy =
  | UCB1 of float                 (** UCB1 with exploration constant c *)
  | Greedy                        (** Always select highest score *)
  | EpsilonGreedy of float        (** Random with probability epsilon *)
  | Softmax of float              (** Temperature-based selection *)
[@@deriving yojson]

(** Confidence level for Cascade self-assessment *)
type confidence_level = High | Medium | Low
[@@deriving yojson]

let confidence_to_float = function
  | High -> 1.0 | Medium -> 0.5 | Low -> 0.2

let confidence_of_string s =
  match String.lowercase_ascii s with
  | "high" -> High | "medium" -> Medium | _ -> Low

(** Context passing mode between cascade tiers *)
type context_mode = CM_None | CM_Summary | CM_Full
[@@deriving yojson]

let context_mode_to_string = function
  | CM_None -> "none" | CM_Summary -> "summary" | CM_Full -> "full"

let context_mode_of_string s =
  match String.lowercase_ascii s with
  | "none" -> CM_None | "full" -> CM_Full | _ -> CM_Summary

(** The 23 supported node types (including Cascade) *)
type node_type =
  | Llm of {
      model : string;     (** Model name: gemini, claude, codex, ollama:*, glm *)
      system : string option;  (** System instruction for role definition *)
      prompt : string;    (** Prompt template with {{var}} placeholders *)
      timeout : int option;
      tools : Yojson.Safe.t option;  (** MCP tools for function calling (Ollama, GLM) *)
      prompt_ref : string option;  (** Reference to prompt registry entry (id or id@version) *)
      prompt_vars : (string * string) list;  (** Variable substitutions for prompt_ref *)
      thinking : bool;    (** Enable thinking/reasoning mode (GLM 4.7) - auto-enabled for complex prompts *)
    }
  | Tool of {
      name : string;      (** MCP tool name *)
      args : Yojson.Safe.t;  (** Tool arguments as JSON *)
    }
  | Pipeline of node list    (** Sequential execution: a >> b >> c *)
  | Fanout of node list      (** Parallel execution: a ||| b ||| c *)
  | Quorum of {
      consensus : consensus_mode;  (** P1.3: Consensus algorithm *)
      nodes : node list;
      weights : (string * float) list;  (** Optional weights per node id *)
    }
  | Gate of {
      condition : string;    (** Condition expression *)
      then_node : node;      (** Execute if true *)
      else_node : node option;  (** Execute if false *)
    }
  | Subgraph of chain        (** Inline nested chain *)
  | ChainRef of string       (** Reference to registered chain *)
  | Map of {
      func : string;         (** Transformation function name *)
      inner : node;          (** Node to transform output of *)
    }
  | Bind of {
      func : string;         (** Dynamic routing function *)
      inner : node;          (** Node to get input from *)
    }
  | Merge of {
      strategy : merge_strategy;
      nodes : node list;
    }
  | Threshold of {
      metric : string;           (** Metric name: "confidence", "coverage", "latency", "score" *)
      operator : threshold_op;   (** Comparison operator *)
      value : float;             (** Threshold value *)
      input_node : node;         (** Node to get value from *)
      on_pass : node option;     (** Execute if condition passes *)
      on_fail : node option;     (** Execute if condition fails *)
    }
  | GoalDriven of {
      goal_metric : string;        (** Target metric: "coverage", "score", "success_rate" *)
      goal_operator : threshold_op; (** Comparison operator for goal condition *)
      goal_value : float;          (** Target value to achieve *)
      action_node : node;          (** Node to execute repeatedly *)
      measure_func : string;       (** Metric measurement function: "exec_test", "call_api", "parse_json" *)
      max_iterations : int;        (** Maximum iteration count *)
      strategy_hints : (string * string) list;  (** Strategy hints: [("below_50", "fast"), ("above_50", "accurate")] *)
      conversational : bool;       (** Enable conversational mode with context accumulation *)
      relay_models : string list;  (** Models to rotate through: ["gemini"; "claude"; "codex"] *)
    }
  | Evaluator of {
      candidates : node list;      (** Candidate nodes to evaluate *)
      scoring_func : string;       (** Scoring function: "llm_judge", "regex_match", "json_schema", "anti_fake", "custom" *)
      scoring_prompt : string option;  (** Prompt for LLM judge scoring *)
      select_strategy : select_strategy;  (** Selection strategy *)
      min_score : float option;    (** Minimum score threshold (fails if none meet it) *)
    }
  (* Resilience Nodes *)
  | Retry of {
      node : node;                   (** Node to retry on failure *)
      max_attempts : int;            (** Maximum retry attempts *)
      backoff : backoff_strategy;    (** Delay strategy between retries *)
      retry_on : string list;        (** Error patterns to retry on (empty = all) *)
    }
  | Fallback of {
      primary : node;                (** Primary node to try first *)
      fallbacks : node list;         (** Fallback nodes tried in order *)
    }
  | Race of {
      nodes : node list;             (** Nodes to race (first wins) *)
      timeout : float option;        (** Optional timeout for stragglers *)
    }
  | ChainExec of {
      chain_source : string;         (** Node ID or variable containing chain JSON *)
      validate : bool;               (** Validate generated chain before execution *)
      max_depth : int;               (** Maximum recursion depth (default: 3) *)
      sandbox : bool;                (** Restrict dangerous tools in generated chain *)
      context_inject : (string * string) list;  (** Context mapping: (child_var, parent_source) *)
      pass_outputs : bool;           (** Pass all parent outputs to child (default: true) *)
    }
  (* Inter-node data transformation *)
  | Adapter of {
      input_ref : string;            (** Input source: node ID or "{{node.output}}" *)
      transform : adapter_transform; (** Transformation to apply *)
      on_error : [ `Fail | `Passthrough | `Default of string ];  (** Error handling *)
    }
  (* Caching node - avoids re-executing expensive operations *)
  | Cache of {
      key_expr : string;             (** Cache key expression: "{{input}}" or "static-key" *)
      ttl_seconds : int;             (** Time-to-live in seconds (0 = infinite) *)
      inner : node;                  (** Node to cache results from *)
    }
  (* Batch processing node - process list items in batches *)
  | Batch of {
      batch_size : int;              (** Number of items per batch *)
      parallel : bool;               (** Process items within batch in parallel *)
      inner : node;                  (** Node to apply to each item *)
      collect_strategy : [ `List | `Concat | `First | `Last ];  (** How to collect results *)
    }
  (* Clean context spawn - execute inner node with fresh context (no prior outputs/conversation) *)
  | Spawn of {
      clean : bool;                  (** true = start with empty context, false = inherit *)
      inner : node;                  (** Node to execute in spawned context *)
      pass_vars : string list;       (** Variables to pass even when clean=true: ["input"; "config"] *)
      inherit_cache : bool;          (** Whether to keep cache from parent context (default: true) *)
    }
  (* MCTS - Monte Carlo Tree Search for multi-strategy exploration *)
  | Mcts of {
      strategies : node list;        (** Strategy nodes to explore *)
      simulation : node;             (** Simulation node for rollout *)
      evaluator : string;            (** Scoring function: "llm_judge", "regex", "custom" *)
      evaluator_prompt : string option;  (** Prompt for LLM evaluator *)
      policy : mcts_policy;          (** Selection policy: UCB1, Greedy, EpsilonGreedy, Softmax *)
      max_iterations : int;          (** Maximum MCTS iterations *)
      max_depth : int;               (** Maximum tree depth *)
      expansion_threshold : int;     (** Visits before expansion *)
      early_stop : float option;     (** Stop if score exceeds threshold *)
      parallel_sims : int;           (** Number of parallel simulations *)
    }
  (* StreamMerge - Process results progressively as they arrive (not waiting for slowest) *)
  | StreamMerge of {
      nodes : node list;             (** Nodes to execute in parallel *)
      reducer : merge_strategy;      (** How to combine results: First, Concat, Custom *)
      initial : string;              (** Initial accumulator value (e.g., "" or "[]") *)
      min_results : int option;      (** Minimum results before returning (None = wait for all) *)
      timeout : float option;        (** Timeout in seconds (applies after min_results met) *)
    }
  (* FeedbackLoop - Iterative quality improvement with evaluator feedback *)
  | FeedbackLoop of {
      generator : node;              (** Generator node that produces output *)
      evaluator_config : evaluator_config;  (** Evaluator configuration *)
      improver_prompt : string;      (** Prompt template with {{feedback}} and {{previous_output}} *)
      max_iterations : int;          (** Maximum iteration count *)
      score_threshold : float;       (** Score threshold (0.0-1.0) *)
      score_operator : threshold_op; (** Comparison operator: Gte, Lte, Gt, Lt, Eq *)
      conversational : bool;         (** Enable conversational mode with context accumulation *)
      relay_models : string list;    (** Models to rotate through: ["gemini"; "claude"; "codex"] *)
    }
  (* MASC - Multi-Agent Streaming Coordination nodes *)
  | Masc_broadcast of {
      message : string;               (** Message template with {{var}} placeholders *)
      room : string option;           (** Room name (None = current room) *)
      mention : string list;          (** Agent mentions: ["@codex"; "@gemini"] *)
    }
  | Masc_listen of {
      filter : string option;         (** Message filter pattern (regex) *)
      timeout_sec : float;            (** Timeout in seconds *)
      room : string option;           (** Room name (None = current room) *)
    }
  | Masc_claim of {
      task_id : string option;        (** Specific task ID (None = claim_next) *)
      room : string option;           (** Room name (None = current room) *)
    }
  | Cascade of {
      tiers : cascade_tier list;
      confidence_prompt : string option;
      max_escalations : int;
      context_mode : context_mode;
      task_hint : string option;
      default_threshold : float;
    }
[@@deriving yojson]

(** A single execution node *)
and node = {
  id : string;                           (** Unique node identifier *)
  node_type : node_type;                 (** The node's type and config *)
  input_mapping : (string * string) list;  (** Map: param -> {{node.output}} *)
  (* Preset node fields (optional, for data/chains/*.json) *)
  output_key : string option; [@yojson.option]       (** Output variable name *)
  depends_on : string list option; [@yojson.option]  (** Explicit dependencies *)
}
[@@deriving yojson]

(** A tier in a Cascade node *)
and cascade_tier = {
  tier_node : node;
  tier_index : int;
  confidence_threshold : float;
  cost_weight : float;
  pass_context : bool;
}

(** A complete chain definition *)
and chain = {
  id : string;           (** Chain identifier *)
  nodes : node list;     (** List of nodes in the chain *)
  output : string;       (** ID of the output node *)
  config : chain_config; (** Execution configuration *)
  (* Preset metadata fields (optional, for data/chains/*.json) *)
  name : string option; [@yojson.option]          (** Human-readable name *)
  description : string option; [@yojson.option]   (** Chain description *)
  version : string option; [@yojson.option]       (** Semantic version *)
  input_schema : Yojson.Safe.t option; [@yojson.option]   (** JSON Schema for input *)
  output_schema : Yojson.Safe.t option; [@yojson.option]  (** JSON Schema for output *)
  metadata : Yojson.Safe.t option; [@yojson.option]       (** Arbitrary metadata *)
}
[@@deriving yojson]

(** Create a chain with default optional fields *)
let make_chain ~id ~nodes ~output ?(config = default_config)
    ?name ?description ?version ?input_schema ?output_schema ?metadata () =
  { id; nodes; output; config; name; description; version;
    input_schema; output_schema; metadata }

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
[@@deriving yojson]

(** Token usage tracking *)
type token_usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
  estimated_cost_usd : float;
}
[@@deriving yojson]

let empty_token_usage = {
  prompt_tokens = 0;
  completion_tokens = 0;
  total_tokens = 0;
  estimated_cost_usd = 0.0;
}

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
[@@deriving yojson]

(** Execution plan produced by compiler *)
type execution_plan = {
  chain : chain;
  execution_order : string list;  (** Topologically sorted node IDs *)
  parallel_groups : string list list;  (** Groups that can run in parallel *)
  depth : int;  (** Maximum nesting depth *)
}
[@@deriving yojson]

(** Helper: Get node type name as string *)
let node_type_name = function
  | Llm _ -> "llm"
  | Tool _ -> "tool"
  | Pipeline _ -> "pipeline"
  | Fanout _ -> "fanout"
  | Quorum _ -> "quorum"
  | Gate _ -> "gate"
  | Subgraph _ -> "subgraph"
  | ChainRef _ -> "chain_ref"
  | Map _ -> "map"
  | Bind _ -> "bind"
  | Merge _ -> "merge"
  | Threshold _ -> "threshold"
  | GoalDriven _ -> "goal_driven"
  | Evaluator _ -> "evaluator"
  | Retry _ -> "retry"
  | Fallback _ -> "fallback"
  | Race _ -> "race"
  | ChainExec _ -> "chain_exec"
  | Adapter _ -> "adapter"
  | Cache _ -> "cache"
  | Batch _ -> "batch"
  | Spawn _ -> "spawn"
  | Mcts _ -> "mcts"
  | StreamMerge _ -> "stream_merge"
  | FeedbackLoop _ -> "feedback_loop"
  | Masc_broadcast _ -> "masc_broadcast"
  | Masc_listen _ -> "masc_listen"
  | Masc_claim _ -> "masc_claim"
  | Cascade _ -> "cascade"

(** Helper: Create a simple LLM node *)
let make_llm_node ~id ~model ?system ~prompt ?timeout ?tools ?prompt_ref ?(prompt_vars=[]) ?(thinking=false) () =
  { id; node_type = Llm { model; system; prompt; timeout; tools; prompt_ref; prompt_vars; thinking };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create an adapter node for inter-node data transformation *)
let make_adapter ~id ~input_ref ~transform ?(on_error=`Fail) () =
  { id; node_type = Adapter { input_ref; transform; on_error };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a simple tool node *)
let make_tool_node ~id ~name ~args =
  { id; node_type = Tool { name; args };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a pipeline from nodes *)
let make_pipeline ~id nodes =
  { id; node_type = Pipeline nodes;
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a fanout from nodes *)
let make_fanout ~id nodes =
  { id; node_type = Fanout nodes;
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a quorum node (P1.3: supports consensus modes) *)
let make_quorum ~id ?(consensus = Count 1) ?(weights = []) nodes =
  { id; node_type = Quorum { consensus; nodes; weights };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a threshold node *)
let make_threshold ~id ~metric ~operator ~value ~input_node ?on_pass ?on_fail () =
  { id; node_type = Threshold { metric; operator; value; input_node; on_pass; on_fail };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a goal-driven iterative node *)
let make_goal_driven ~id ~goal_metric ~goal_operator ~goal_value
    ~action_node ~measure_func ~max_iterations ?(strategy_hints=[])
    ?(conversational=false) ?(relay_models=[]) () =
  { id; node_type = GoalDriven {
      goal_metric; goal_operator; goal_value;
      action_node; measure_func; max_iterations; strategy_hints;
      conversational; relay_models
    }; input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create an evaluator node *)
let make_evaluator ~id ~candidates ~scoring_func ?scoring_prompt ~select_strategy ?min_score () =
  { id; node_type = Evaluator { candidates; scoring_func; scoring_prompt; select_strategy; min_score };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a retry node with backoff *)
let make_retry ~id ~node ~max_attempts ?(backoff = Exponential 1.0) ?(retry_on = []) () =
  { id; node_type = Retry { node; max_attempts; backoff; retry_on };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a fallback chain *)
let make_fallback ~id ~primary ~fallbacks =
  { id; node_type = Fallback { primary; fallbacks };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a race node (first result wins) *)
let make_race ~id ~nodes ?timeout () =
  { id; node_type = Race { nodes; timeout };
    input_mapping = []; output_key = None; depends_on = None }

(** Helper: Create a feedback loop node for iterative quality improvement *)
let make_feedback_loop ~id ~generator ~evaluator_config ~improver_prompt
    ~max_iterations ~score_threshold ?(score_operator=Gte)
    ?(conversational=false) ?(relay_models=[]) () =
  { id; node_type = FeedbackLoop {
      generator; evaluator_config; improver_prompt;
      max_iterations; score_threshold; score_operator;
      conversational; relay_models
    }; input_mapping = []; output_key = None; depends_on = None }

let make_cascade ~id ~tiers ?(confidence_prompt=None) ?(max_escalations=2)
    ?(context_mode=CM_Summary) ?task_hint ?(default_threshold=0.7) () =
  { id; node_type = Cascade {
      tiers; confidence_prompt; max_escalations; context_mode; task_hint;
      default_threshold
    }; input_mapping = []; output_key = None; depends_on = None }

(** {1 Batch Execution Types - Phase 5} *)

(** Batch priority levels *)
type batch_priority =
  | High
  | Normal
  | Low
[@@deriving yojson]

(** Retry configuration for batch execution *)
type retry_config = {
  max_retries: int;           (** Maximum retry attempts *)
  initial_delay_ms: int;      (** Initial delay before first retry *)
  backoff_multiplier: float;  (** Exponential backoff multiplier *)
  max_delay_ms: int;          (** Maximum delay between retries *)
}
[@@deriving yojson]

(** Default retry configuration *)
let default_retry_config = {
  max_retries = 3;
  initial_delay_ms = 1000;
  backoff_multiplier = 2.0;
  max_delay_ms = 30000;
}

(** Batch execution configuration *)
type batch_config = {
  batch_max_concurrent: int;  (** Maximum concurrent chain executions *)
  rate_limit_per_min: int;    (** Rate limit per minute per model *)
  retry_policy: retry_config; (** Retry configuration *)
  priority: batch_priority;   (** Batch priority level *)
}
[@@deriving yojson]

(** Default batch configuration *)
let default_batch_config = {
  batch_max_concurrent = 5;
  rate_limit_per_min = 60;
  retry_policy = default_retry_config;
  priority = Normal;
}

(** Batch execution statistics *)
type batch_stats = {
  total_chains: int;          (** Total chains in batch *)
  completed: int;             (** Successfully completed chains *)
  failed: int;                (** Failed chains *)
  total_duration_ms: int;     (** Total execution time *)
  total_tokens: Chain_category.token_usage;  (** Aggregated token usage *)
  avg_duration_ms: float;     (** Average chain duration *)
}
[@@deriving yojson]

(** Result of batch execution *)
type batch_result = {
  batch_id: string;                       (** Unique batch identifier *)
  results: (string * chain_result) list;  (** Chain ID to result mapping *)
  stats: batch_stats;                     (** Execution statistics *)
  failed_chains: (string * string) list;  (** Chain ID to error mapping *)
}
[@@deriving yojson]

(** Count parallel groups in a chain structure recursively.
    Parallel groups are: Fanout, Quorum, Merge, Race, Evaluator *)
let rec count_parallel_groups (node: node) : int =
  match node.node_type with
  | Fanout nodes ->
      1 + List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 nodes
  | Quorum { nodes; _ } ->
      1 + List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 nodes
  | Merge { nodes; _ } ->
      1 + List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 nodes
  | Race { nodes; _ } ->
      1 + List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 nodes
  | Evaluator { candidates; _ } ->
      1 + List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 candidates
  | Pipeline nodes ->
      List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 nodes
  | Gate { then_node; else_node; _ } ->
      count_parallel_groups then_node +
      (match else_node with Some n -> count_parallel_groups n | None -> 0)
  | Threshold { input_node; on_pass; on_fail; _ } ->
      count_parallel_groups input_node +
      (match on_pass with Some n -> count_parallel_groups n | None -> 0) +
      (match on_fail with Some n -> count_parallel_groups n | None -> 0)
  | Retry { node = inner; _ } | Map { inner; _ } | Bind { inner; _ } ->
      count_parallel_groups inner
  | Fallback { primary; fallbacks; _ } ->
      count_parallel_groups primary +
      List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 fallbacks
  | Subgraph chain ->
      List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 chain.nodes
  | GoalDriven { action_node; _ } -> count_parallel_groups action_node
  | Cache { inner; _ } -> count_parallel_groups inner
  | Batch { inner; parallel; _ } ->
      (* Batch is a parallel group if parallel=true *)
      (if parallel then 1 else 0) + count_parallel_groups inner
  | Spawn { inner; _ } ->
      (* Spawn wraps inner - count inner's parallel groups *)
      count_parallel_groups inner
  | Mcts { strategies; simulation; _ } ->
      (* MCTS runs strategies in parallel and performs parallel simulations *)
      1 + List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 strategies +
      count_parallel_groups simulation
  | StreamMerge { nodes; _ } ->
      (* StreamMerge runs nodes in parallel and processes results progressively *)
      1 + List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 nodes
  | FeedbackLoop { generator; _ } ->
      (* FeedbackLoop wraps generator - count generator's parallel groups *)
      count_parallel_groups generator
  | Cascade { tiers; _ } ->
      List.fold_left (fun acc t -> acc + count_parallel_groups t.tier_node) 0 tiers
  | Llm _ | Tool _ | ChainRef _ | ChainExec _ | Adapter _
  | Masc_broadcast _ | Masc_listen _ | Masc_claim _ -> 0

(** Count total parallel groups in a chain *)
let count_chain_parallel_groups (chain: chain) : int =
  List.fold_left (fun acc n -> acc + count_parallel_groups n) 0 chain.nodes
