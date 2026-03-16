include Chain_parser_helpers
open Chain_types

(* ============================================================================
   Chain to JSON Serializer (for JSON <-> Mermaid round-trip)
   ============================================================================ *)

(** Serialize merge strategy to string *)
let merge_strategy_to_string = function
  | First -> "first"
  | Last -> "last"
  | Concat -> "concat"
  | WeightedAvg -> "weighted_average"
  | Custom s -> "custom:" ^ s

(** Serialize threshold operator to string *)
let threshold_op_to_string = function
  | Gt -> "gt" | Gte -> "gte" | Lt -> "lt" | Lte -> "lte" | Eq -> "eq" | Neq -> "neq"

(** Serialize select strategy to JSON *)
let select_strategy_to_json = function
  | Best -> `String "best"
  | Worst -> `String "worst"
  | WeightedRandom -> `String "weighted_random"
  | AboveThreshold f -> `Assoc [("above_threshold", `Float f)]

(** Serialize backoff strategy to JSON *)
let backoff_to_json = function
  | Constant s -> `Assoc [("type", `String "constant"); ("seconds", `Float s)]
  | Exponential b -> `Assoc [("type", `String "exponential"); ("base", `Float b)]
  | Linear b -> `Assoc [("type", `String "linear"); ("base", `Float b)]
  | Jitter (min_s, max_s) -> `Assoc [("type", `String "jitter"); ("min", `Float min_s); ("max", `Float max_s)]

(** Serialize adapter transform to JSON *)
let rec adapter_transform_to_json = function
  | Extract path -> `Assoc [("type", `String "extract"); ("path", `String path)]
  | Template tpl -> `Assoc [("type", `String "template"); ("template", `String tpl)]
  | Summarize tokens -> `Assoc [("type", `String "summarize"); ("max_tokens", `Int tokens)]
  | Truncate chars -> `Assoc [("type", `String "truncate"); ("max_chars", `Int chars)]
  | JsonPath path -> `Assoc [("type", `String "jsonpath"); ("path", `String path)]
  | Regex (pattern, replacement) ->
      `Assoc [("type", `String "regex"); ("pattern", `String pattern); ("replacement", `String replacement)]
  | ValidateSchema schema -> `Assoc [("type", `String "validate_schema"); ("schema", `String schema)]
  | ParseJson -> `String "parse_json"
  | Stringify -> `String "stringify"
  | Chain transforms ->
      `Assoc [("type", `String "chain"); ("transforms", `List (List.map adapter_transform_to_json transforms))]
  | Conditional { condition; on_true; on_false } ->
      `Assoc [
        ("type", `String "conditional");
        ("condition", `String condition);
        ("on_true", adapter_transform_to_json on_true);
        ("on_false", adapter_transform_to_json on_false);
      ]
  | Split { delimiter; chunk_size; overlap } ->
      `Assoc [
        ("type", `String "split");
        ("delimiter", `String delimiter);
        ("chunk_size", `Int chunk_size);
        ("overlap", `Int overlap);
      ]
  | Custom name -> `Assoc [("type", `String "custom"); ("func", `String name)]

(** Serialize on_error policy to JSON *)
let on_error_to_json = function
  | `Fail -> `String "fail"
  | `Passthrough -> `String "passthrough"
  | `Default s -> `Assoc [("default", `String s)]

(** Serialize config to JSON *)
let config_to_json (cfg : chain_config) : Yojson.Safe.t =
  `Assoc [
    ("max_depth", `Int cfg.max_depth);
    ("max_concurrency", `Int cfg.max_concurrency);
    ("timeout", `Int cfg.timeout);
    ("trace", `Bool cfg.trace);
  ]

(** Serialize node to JSON *)
let rec node_to_json_with (include_empty_inputs : bool) (n : node) : Yojson.Safe.t =
  let base = [("id", `String n.id)] in
  (* For lossless roundtrip, preserve ALL input_mapping entries including _dep_ prefixed ones.
     Previously we filtered out _dep_ prefix entries, but this caused information loss
     during JSON → Mermaid → JSON roundtrip. The _dep_ prefix is a semantic marker for
     explicit dependencies (vs template-inferred), and must survive serialization. *)
  let filtered_mapping =
    match n.node_type with
    | Adapter { input_ref; _ } ->
        (* Only filter the implicit input_ref, not _dep_ entries *)
        List.filter (fun (k, _) -> k <> input_ref) n.input_mapping
    | _ ->
        n.input_mapping  (* Preserve all, including _dep_ prefixed entries *)
  in
  let input_mapping =
    if filtered_mapping = [] then
      if include_empty_inputs then [("inputs", `Assoc [])] else []
    else
      [("inputs", `Assoc (List.map (fun (k, v) -> (k, `String v)) filtered_mapping))]
  in
  let type_fields = match n.node_type with
    | Llm { model; system; prompt; timeout; tools; prompt_ref; prompt_vars; thinking } ->
        let fields = [
          ("type", `String "llm");
          ("model", `String model);
          ("prompt", `String prompt);
        ] in
        let fields = match system with
          | Some s -> fields @ [("system", `String s)]
          | None -> fields
        in
        let fields = match timeout with
          | Some t -> fields @ [("timeout", `Int t)]
          | None -> fields
        in
        let fields = match tools with
          | Some t -> fields @ [("tools", t)]
          | None -> fields
        in
        let fields = match prompt_ref with
          | Some r -> fields @ [("prompt_ref", `String r)]
          | None -> fields
        in
        let fields = if prompt_vars <> [] then
          fields @ [("prompt_vars", `Assoc (List.map (fun (k, v) -> (k, `String v)) prompt_vars))]
        else fields
        in
        (* Phase 6: Serialize thinking field for GLM reasoning mode *)
        let fields = if thinking then
          fields @ [("thinking", `Bool true)]
        else fields
        in
        fields

    | Tool { name; args } ->
        (* Restore nested structure if server prefix exists: "figma:parse_url" -> tool.server + tool.name *)
        if String.contains name ':' then
          let idx = String.index name ':' in
          let server = String.sub name 0 idx in
          let tool_name = String.sub name (idx + 1) (String.length name - idx - 1) in
          let tool_obj = `Assoc [
            ("server", `String server);
            ("name", `String tool_name);
            ("args", args)
          ] in
          [("type", `String "tool"); ("tool", tool_obj)]
        else
          [("type", `String "tool"); ("name", `String name); ("args", args)]

    | Pipeline nodes ->
        [("type", `String "pipeline"); ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes))]

    | Fanout nodes ->
        [("type", `String "fanout"); ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes))]

    | Quorum { consensus; nodes; weights } ->
        (* P1.3: Serialize consensus mode *)
        let consensus_field = match consensus with
          | Chain_types.Count n -> [("required", `Int n)]  (* backward compat *)
          | _ -> [("consensus", `String (Chain_types.consensus_mode_to_string consensus))]
        in
        let weights_field = if weights = [] then []
          else [("weights", `Assoc (List.map (fun (k, v) -> (k, `Float v)) weights))]
        in
        [("type", `String "quorum")]
        @ consensus_field
        @ weights_field
        @ [("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes))]

    | Gate { condition; then_node; else_node } ->
        let fields = [
          ("type", `String "gate");
          ("condition", `String condition);
          ("then", node_to_json_with include_empty_inputs then_node);
        ] in
        (match else_node with
         | Some en -> fields @ [("else", node_to_json_with include_empty_inputs en)]
         | None -> fields)

    | Subgraph c ->
        [("type", `String "subgraph"); ("graph", chain_to_json_inner_with include_empty_inputs c)]

    | ChainRef ref_id ->
        [("type", `String "chain_ref"); ("ref", `String ref_id)]

    | Map { func; inner } ->
        [("type", `String "map"); ("func", `String func); ("inner", node_to_json_with include_empty_inputs inner)]

    | Bind { func; inner } ->
        [("type", `String "bind"); ("func", `String func); ("inner", node_to_json_with include_empty_inputs inner)]

    | Merge { strategy; nodes } ->
        [
          ("type", `String "merge");
          ("strategy", `String (merge_strategy_to_string strategy));
          ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes));
        ]

    | Threshold { metric; operator; value; input_node; on_pass; on_fail } ->
        let fields = [
          ("type", `String "threshold");
          ("metric", `String metric);
          ("operator", `String (threshold_op_to_string operator));
          ("value", `Float value);
          ("input_node", node_to_json_with include_empty_inputs input_node);
        ] in
        let fields = match on_pass with Some n -> fields @ [("on_pass", node_to_json_with include_empty_inputs n)] | None -> fields in
        let fields = match on_fail with Some n -> fields @ [("on_fail", node_to_json_with include_empty_inputs n)] | None -> fields in
        fields

    | GoalDriven { goal_metric; goal_operator; goal_value; action_node;
                    measure_func; max_iterations; strategy_hints; conversational; relay_models } ->
        let fields = [
          ("type", `String "goal_driven");
          ("goal_metric", `String goal_metric);
          ("goal_operator", `String (threshold_op_to_string goal_operator));
          ("goal_value", `Float goal_value);
          ("action_node", node_to_json_with include_empty_inputs action_node);
          ("measure_func", `String measure_func);
          ("max_iterations", `Int max_iterations);
          ("conversational", `Bool conversational);
        ] in
        let fields = if strategy_hints = [] then fields
          else fields @ [("strategy_hints", `Assoc (List.map (fun (k, v) -> (k, `String v)) strategy_hints))]
        in
        let fields = if relay_models = [] then fields
          else fields @ [("relay_models", `List (List.map (fun s -> `String s) relay_models))]
        in
        fields

    | Evaluator { candidates; scoring_func; scoring_prompt; select_strategy; min_score } ->
        let fields = [
          ("type", `String "evaluator");
          ("candidates", `List (List.map (node_to_json_with include_empty_inputs) candidates));
          ("scoring_func", `String scoring_func);
          ("select_strategy", select_strategy_to_json select_strategy);
        ] in
        let fields = match scoring_prompt with
          | Some p -> fields @ [("scoring_prompt", `String p)]
          | None -> fields
        in
        let fields = match min_score with
          | Some s -> fields @ [("min_score", `Float s)]
          | None -> fields
        in
        fields

    | Retry { node = inner; max_attempts; backoff; retry_on } ->
        [
          ("type", `String "retry");
          ("node", node_to_json_with include_empty_inputs inner);
          ("max_attempts", `Int max_attempts);
          ("backoff", backoff_to_json backoff);
          ("retry_on", `List (List.map (fun s -> `String s) retry_on));
        ]

    | Fallback { primary; fallbacks } ->
        [
          ("type", `String "fallback");
          ("primary", node_to_json_with include_empty_inputs primary);
          ("fallbacks", `List (List.map (node_to_json_with include_empty_inputs) fallbacks));
        ]

    | Race { nodes; timeout } ->
        let fields = [
          ("type", `String "race");
          ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes));
        ] in
        (match timeout with
         | Some t -> fields @ [("timeout", `Float t)]
         | None -> fields)

    | ChainExec { chain_source; validate; max_depth; sandbox; context_inject; pass_outputs } ->
        let base_fields = [
          ("type", `String "chain_exec");
          ("chain_source", `String chain_source);
          ("validate", `Bool validate);
          ("max_depth", `Int max_depth);
          ("sandbox", `Bool sandbox);
          ("pass_outputs", `Bool pass_outputs);
        ] in
        let inject_fields =
          if context_inject = [] then []
          else [("context_inject", `Assoc (List.map (fun (k, v) -> (k, `String v)) context_inject))]
        in
        base_fields @ inject_fields

    | Adapter { input_ref; transform; on_error } ->
        [
          ("type", `String "adapter");
          ("input_ref", `String input_ref);
          ("transform", adapter_transform_to_json transform);
          ("on_error", on_error_to_json on_error);
        ]

    | Cache { key_expr; ttl_seconds; inner } ->
        [
          ("type", `String "cache");
          ("key_expr", `String key_expr);
          ("ttl_seconds", `Int ttl_seconds);
          ("inner", node_to_json_with include_empty_inputs inner);
        ]

    | Batch { batch_size; parallel; inner; collect_strategy } ->
        let strategy_str = match collect_strategy with
          | `List -> "list" | `Concat -> "concat" | `First -> "first" | `Last -> "last"
        in
        [
          ("type", `String "batch");
          ("batch_size", `Int batch_size);
          ("parallel", `Bool parallel);
          ("inner", node_to_json_with include_empty_inputs inner);
          ("collect_strategy", `String strategy_str);
        ]
    | Spawn { clean; inner; pass_vars; inherit_cache } ->
        [
          ("type", `String "spawn");
          ("clean", `Bool clean);
          ("inner", node_to_json_with include_empty_inputs inner);
          ("pass_vars", `List (List.map (fun v -> `String v) pass_vars));
          ("inherit_cache", `Bool inherit_cache);
        ]
    | Mcts { strategies; simulation; evaluator; evaluator_prompt; policy;
             max_iterations; max_depth; expansion_threshold; early_stop; parallel_sims } ->
        let policy_json = match policy with
          | UCB1 c -> `Assoc [("type", `String "ucb1"); ("c", `Float c)]
          | Greedy -> `Assoc [("type", `String "greedy")]
          | EpsilonGreedy e -> `Assoc [("type", `String "epsilon_greedy"); ("epsilon", `Float e)]
          | Softmax t -> `Assoc [("type", `String "softmax"); ("temperature", `Float t)]
        in
        [
          ("type", `String "mcts");
          ("strategies", `List (List.map (node_to_json_with include_empty_inputs) strategies));
          ("simulation", node_to_json_with include_empty_inputs simulation);
          ("evaluator", `String evaluator);
          ("evaluator_prompt", match evaluator_prompt with Some p -> `String p | None -> `Null);
          ("policy", policy_json);
          ("max_iterations", `Int max_iterations);
          ("max_depth", `Int max_depth);
          ("expansion_threshold", `Int expansion_threshold);
          ("early_stop", match early_stop with Some s -> `Float s | None -> `Null);
          ("parallel_sims", `Int parallel_sims);
        ]
    | StreamMerge { nodes; reducer; initial; min_results; timeout } ->
        let reducer_json = match reducer with
          | First -> `String "first"
          | Last -> `String "last"
          | Concat -> `String "concat"
          | WeightedAvg -> `String "weighted_avg"
          | Custom s -> `Assoc [("type", `String "custom"); ("name", `String s)]
        in
        [
          ("type", `String "stream_merge");
          ("nodes", `List (List.map (node_to_json_with include_empty_inputs) nodes));
          ("reducer", reducer_json);
          ("initial", `String initial);
          ("min_results", match min_results with Some n -> `Int n | None -> `Null);
          ("timeout", match timeout with Some t -> `Float t | None -> `Null);
        ]
    | FeedbackLoop { generator; evaluator_config; improver_prompt; max_iterations; score_threshold; score_operator; conversational; relay_models } ->
        let select_strategy_json = match evaluator_config.select_strategy with
          | Best -> `String "best"
          | Worst -> `String "worst"
          | WeightedRandom -> `String "weighted_random"
          | AboveThreshold t -> `List [`String "above_threshold"; `Float t]
        in
        let evaluator_config_json = `Assoc [
          ("scoring_func", `String evaluator_config.scoring_func);
          ("scoring_prompt", match evaluator_config.scoring_prompt with Some p -> `String p | None -> `Null);
          ("select_strategy", select_strategy_json);
        ] in
        let operator_str = match score_operator with
          | Gt -> "gt" | Gte -> "gte" | Lt -> "lt" | Lte -> "lte" | Eq -> "eq" | Neq -> "neq"
        in
        let fields = [
          ("type", `String "feedback_loop");
          ("generator", node_to_json_with include_empty_inputs generator);
          ("evaluator_config", evaluator_config_json);
          ("improver_prompt", `String improver_prompt);
          ("max_iterations", `Int max_iterations);
          ("score_threshold", `Float score_threshold);
          ("score_operator", `String operator_str);
          ("conversational", `Bool conversational);
        ] in
        let fields = if relay_models = [] then fields
          else fields @ [("relay_models", `List (List.map (fun s -> `String s) relay_models))]
        in
        fields
    | Masc_broadcast { message; room; mention } ->
        let fields = [
          ("type", `String "masc_broadcast");
          ("message", `String message);
          ("mention", `List (List.map (fun s -> `String s) mention));
        ] in
        (match room with Some r -> fields @ [("room", `String r)] | None -> fields)
    | Masc_listen { filter; timeout_sec; room } ->
        let fields = [
          ("type", `String "masc_listen");
          ("timeout_sec", `Float timeout_sec);
        ] in
        let fields = match filter with Some f -> fields @ [("filter", `String f)] | None -> fields in
        (match room with Some r -> fields @ [("room", `String r)] | None -> fields)
    | Masc_claim { task_id; room } ->
        let fields = [("type", `String "masc_claim")] in
        let fields = match task_id with Some t -> fields @ [("task_id", `String t)] | None -> fields in
        (match room with Some r -> fields @ [("room", `String r)] | None -> fields)
    | Cascade { tiers; confidence_prompt; max_escalations; context_mode; task_hint; default_threshold } ->
        let tier_json = `List (List.map Chain_types.cascade_tier_to_yojson tiers) in
        let fields = [
          ("type", `String "cascade");
          ("tiers", tier_json);
          ("max_escalations", `Int max_escalations);
          ("context_mode", `String (Chain_types.context_mode_to_string context_mode));
          ("default_threshold", `Float default_threshold);
        ] in
        let fields = match confidence_prompt with Some p -> ("confidence_prompt", `String p) :: fields | None -> fields in
        let fields = match task_hint with Some h -> ("task_hint", `String h) :: fields | None -> fields in
        fields
  in
  `Assoc (base @ type_fields @ input_mapping)

(** Serialize chain to JSON (inner) *)
and chain_to_json_inner_with (include_empty_inputs : bool) (c : chain) : Yojson.Safe.t =
  `Assoc [
    ("id", `String c.id);
    ("nodes", `List (List.map (node_to_json_with include_empty_inputs) c.nodes));
    ("output", `String c.output);
    ("config", config_to_json c.config);
  ]

let node_to_json (n : node) : Yojson.Safe.t =
  node_to_json_with false n

(** Main entry point: Serialize chain to JSON *)
let chain_to_json ?(include_empty_inputs = false) (c : chain) : Yojson.Safe.t =
  chain_to_json_inner_with include_empty_inputs c

(** Serialize chain to JSON string (pretty-printed) *)
let chain_to_json_string ?(pretty=true) ?(include_empty_inputs = false) (c : chain) : string =
  let json = chain_to_json ~include_empty_inputs c in
  if pretty then Yojson.Safe.pretty_to_string json
  else Yojson.Safe.to_string json
