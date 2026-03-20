include Chain_parser_helpers
open Chain_types

(** Parse adapter transform from JSON *)
let rec parse_adapter_transform (json : Yojson.Safe.t) : (adapter_transform, string) result =
  let open Yojson.Safe.Util in
  match json with
  | `String s ->
      (* Simple string format: "extract:data.field" or "truncate:100" *)
      (match String.split_on_char ':' s with
       | ["extract"; path] -> Ok (Extract path)
       | ["template"; tpl] -> Ok (Template tpl)
       | ["summarize"; n] -> (try Ok (Summarize (int_of_string n)) with Failure _ -> Error "Invalid summarize value")
       | ["truncate"; n] -> (try Ok (Truncate (int_of_string n)) with Failure _ -> Error "Invalid truncate value")
       | ["jsonpath"; path] -> Ok (JsonPath path)
       | ["parse_json"] | ["parse"] -> Ok ParseJson
       | ["stringify"] -> Ok Stringify
       | ["custom"; name] -> Ok (Custom name)
       | [simple] ->
           (* Handle simple keywords *)
           (match simple with
            | "parse_json" | "parse" -> Ok ParseJson
            | "stringify" -> Ok Stringify
            | _ -> Error (Printf.sprintf "Unknown simple transform: %s" simple))
       | _ -> Error (Printf.sprintf "Invalid transform string format: %s" s))
  | `Assoc _ ->
      (* Object format with "type" field *)
      let typ = parse_string_with_default json "type" "unknown" in
      (match typ with
       | "extract" ->
           let path = parse_string_with_default json "path" "." in
           Ok (Extract path)
       | "template" ->
           let tpl = parse_string_with_default json "template" "{{value}}" in
           Ok (Template tpl)
       | "summarize" ->
           let max_tokens = parse_int_with_default json "max_tokens" 500 in
           Ok (Summarize max_tokens)
       | "truncate" ->
           let max_chars = parse_int_with_default json "max_chars" 1000 in
           Ok (Truncate max_chars)
       | "jsonpath" ->
           let path = parse_string_with_default json "path" "$" in
           Ok (JsonPath path)
       | "regex" ->
           let pattern = parse_string_with_default json "pattern" ".*" in
           let replacement = parse_string_with_default json "replacement" "" in
           Ok (Regex (pattern, replacement))
       | "validate_schema" ->
           let schema = parse_string_with_default json "schema" "" in
           Ok (ValidateSchema schema)
       | "parse_json" | "parse" -> Ok ParseJson
       | "stringify" -> Ok Stringify
       | "chain" ->
           let transforms_json = parse_list_with_default json "transforms" in
           let* transforms = parse_adapter_transforms transforms_json in
           Ok (Chain transforms)
       | "conditional" ->
           let* condition =
             match parse_string_opt json "condition" with
             | Some s -> Ok s
             | None -> Error "Missing 'condition' in conditional transform"
           in
           let* on_true = parse_adapter_transform (json |> member "on_true") in
           let* on_false = parse_adapter_transform (json |> member "on_false") in
           Ok (Conditional { condition; on_true; on_false })
       | "custom" ->
           let name = parse_string_with_default json "name" "identity" in
           Ok (Custom name)
       | "unknown" ->
           (* No type field: treat the whole object as a template JSON *)
           (* Convert the object to a JSON template string *)
           let tpl = Yojson.Safe.to_string json in
           Ok (Template tpl)
       | unknown -> Error (Printf.sprintf "Unknown transform type: %s" unknown))
  | _ -> Error "Transform must be a string or object"

(** Parse list of adapter transforms *)
and parse_adapter_transforms (json_list : Yojson.Safe.t list) : (adapter_transform list, string) result =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
        match parse_adapter_transform json with
        | Ok t -> aux (t :: acc) rest
        | Error e -> Error e
  in
  aux [] json_list

(** Parse a single node from JSON *)
let rec parse_node (json : Yojson.Safe.t) : (node, string) result =
  let open Yojson.Safe.Util in
  try
    let* id = require_string json "id" in
    let* node_type_str = require_string json "type" in

    let* node_type = parse_node_type json node_type_str in

    (* Parse explicit input_mapping if provided, otherwise extract from prompt/args *)
    (* Helper for auto-extracting input mappings from node content *)
    let auto_extract_mappings () =
      match node_type with
      | Model { prompt; _ } -> extract_input_mappings prompt
      | Tool { args; _ } -> extract_json_mappings args
      | _ -> []
    in
    (* Parse input_mapping: try "input_mapping" (list format) then "inputs" (assoc format) *)
    let input_mapping =
      match json |> member "input_mapping" with
      | `List pairs ->
          (* Legacy format: [["key", "source"], ...] *)
          List.filter_map (fun pair ->
            match pair with
            | `List [`String k; `String v] -> Some (k, v)
            | _ -> None
          ) pairs
      | `Null | `Bool false ->
          (* Try "inputs" format: {"key": "source", ...} - used by chain_to_json output *)
          (match json |> member "inputs" with
           | `Assoc pairs -> List.map (fun (k, v) ->
               match v with
               | `String s -> (k, s)
               | _ -> (k, Yojson.Safe.to_string v)
             ) pairs
           | `Null -> auto_extract_mappings ()
           | _ -> auto_extract_mappings ())
      | _ -> []
    in

    (* Parse "output_key" field (optional) *)
    let output_key = match json |> member "output_key" with
      | `String s -> Some s
      | _ -> None
    in

    (* Parse "depends_on" field as both string list and edges (common in real chain files) *)
    let depends_on_list, depends_on_mapping =
      match json |> member "depends_on" with
      | `List deps ->
          let parsed = List.filter_map (fun d ->
            match d with
            | `String dep_id -> Some dep_id
            | _ -> None
          ) deps in
          let mapping = List.map (fun dep_id -> ("_dep_" ^ dep_id, dep_id)) parsed in
          (Some parsed, mapping)
      | _ -> (None, [])
    in

    (* Ensure Adapter input_ref contributes to dependency ordering *)
    let input_mapping =
      match node_type with
      | Adapter { input_ref; _ } ->
          if List.exists (fun (k, _) -> k = input_ref) input_mapping then input_mapping
          else input_mapping @ [(input_ref, input_ref)]
      | _ -> input_mapping
    in

    (* Combine input_mapping with depends_on.
       Note: _dep_ prefix ensures no key collision with template-inferred mappings.
       E.g., template {{foo}} creates ("foo", "foo") while depends_on creates ("_dep_foo", "foo").
       Both coexist intentionally - _dep_ marks explicit dependencies for roundtrip preservation. *)
    let final_input_mapping = input_mapping @ depends_on_mapping in

    Ok { id; node_type; input_mapping = final_input_mapping;
         output_key; depends_on = depends_on_list }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Error (Printf.sprintf "JSON type error: %s" msg)
  | exn ->
      Error (Printf.sprintf "Parse error: %s" (Printexc.to_string exn))

(** Parse node type based on type string *)
and parse_node_type (json : Yojson.Safe.t) (type_str : string) : (node_type, string) result =
  let open Yojson.Safe.Util in
  match type_str with
  | "model" ->
      (* Support both flat and nested format:
         Flat:   {"type":"model","model":"gemini","prompt":"..."}
         Nested: {"type":"model","model":{"model":"gemini","prompt":"..."}}
      *)
      let model_json = match json |> member "model" with
        | `Assoc _ as model_obj -> model_obj
        | _ -> json
      in
      let* model = require_string model_json "model" in
      let system = parse_string_opt model_json "system" in
      let timeout = parse_int_opt model_json "timeout" in
      let tools =
        match model_json |> member "tools" with
        | `Null -> None
        | v -> Some v
      in
      (* Prompt Registry support: prompt_ref takes precedence *)
      let prompt_ref = parse_string_opt model_json "prompt_ref" in
      let prompt_vars =
        match model_json |> member "prompt_vars" with
        | `Assoc pairs ->
            List.filter_map (fun (k, v) ->
              match v with `String s -> Some (k, s) | _ -> None) pairs
        | _ -> []
      in
      (* Phase 6: Parse thinking field for GLM reasoning mode *)
      let thinking = parse_bool_with_default model_json "thinking" false in
      (* If prompt_ref is set, load from registry; otherwise require prompt field *)
      let* prompt =
        match prompt_ref with
        | Some ref ->
            (* Parse ref format: "id" or "id@version" *)
            let (id, version) = match String.split_on_char '@' ref with
              | [id; ver] -> (id, Some ver)
              | [id] -> (id, None)
              | _ -> (ref, None)
            in
            (match Prompt_registry.get ~id ?version () with
             | Some entry ->
                 (* Apply prompt_vars to the template *)
                 (match Prompt_registry.render_template ~template:entry.template ~vars:prompt_vars () with
                  | Ok rendered -> Ok rendered
                  | Error e -> Error (Printf.sprintf "Failed to render prompt_ref '%s': %s" ref e))
             | None ->
                 (* If prompt_ref not found, fall back to prompt field if present *)
                 match parse_string_opt model_json "prompt" with
                 | Some p -> Ok p
                 | None -> Error (Printf.sprintf "Prompt '%s' not found in registry and no fallback prompt" ref))
        | None ->
            require_string model_json "prompt"
      in
      Ok (Model { model; system; prompt; timeout; tools; prompt_ref; prompt_vars; thinking })

  | "tool" ->
      (* Support both flat and nested format:
         Flat:   {"type":"tool","name":"eslint","args":{...}}
         Nested: {"type":"tool","tool":{"server":"figma","name":"parse_url","args":{...}}}
      *)
      (match json |> member "tool" with
       | `Assoc _ as tool_obj ->
           (* Nested format: extract from "tool" object *)
           let server_opt = tool_obj |> member "server" |> to_string_option in
           let* name = require_string tool_obj "name" in
           let args = match tool_obj |> member "args" with
             | `Null -> `Assoc []
             | v -> v
           in
           (* Encode server in name if present: "figma:parse_url" *)
           let full_name = match server_opt with
             | Some s -> Printf.sprintf "%s:%s" s name
             | None -> name
           in
           Ok (Tool { name = full_name; args })
       | _ ->
           (* Flat format: direct fields *)
           let* name = require_string json "name" in
           let args = match json |> member "args" with
             | `Null -> `Assoc []
             | v -> v
           in
           Ok (Tool { name; args }))

  | "pipeline" ->
      let nodes_json = json |> member "nodes" |> to_list in
      let* nodes = parse_nodes nodes_json in
      Ok (Pipeline nodes)

  | "fanout" ->
      (* Try "branches" first, fallback to "nodes" *)
      let branches_json =
        match json |> member "branches" with
        | `List l -> l
        | _ -> parse_list_with_default json "nodes"
      in
      let* nodes = parse_nodes branches_json in
      Ok (Fanout nodes)

  | "quorum" ->
      (* P1.3: Support consensus modes - "consensus" field or fallback to "required" *)
      let consensus =
        match json |> member "consensus" with
        | `String s -> Chain_types.consensus_mode_of_string s
        | `Null ->
            (* Backward compat: use "required" as Count *)
            let required = json |> member "required" |> to_int in
            Chain_types.Count required
        | _ ->
            let required = json |> member "required" |> to_int in
            Chain_types.Count required
      in
      let weights =
        match json |> member "weights" with
        | `Assoc pairs ->
            List.filter_map (fun (k, v) ->
              match v with
              | `Float f -> Some (k, f)
              | `Int i -> Some (k, float_of_int i)
              | _ -> None
            ) pairs
        | _ -> []
      in
      (* Try "nodes" first, fallback to "inputs" *)
      let nodes_json =
        match json |> member "nodes" with
        | `List l -> l
        | _ -> parse_list_with_default json "inputs"
      in
      let* nodes = parse_nodes nodes_json in
      Ok (Quorum { consensus; nodes; weights })

  | "gate" ->
      let* condition = require_string json "condition" in
      (* Support both embedded node object (then/else) and string ID reference (then_node/else_node) *)
      let* then_node =
        match json |> member "then" with
        | `Null ->
            (* Try then_node as string ID *)
            (match json |> member "then_node" with
             | `String id -> Ok { id = "_ref_" ^ id; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
             | _ -> Error "Gate requires 'then' (node object) or 'then_node' (string ID)")
        | then_json -> parse_node then_json
      in
      let else_node =
        match json |> member "else" with
        | `Null ->
            (* Try else_node as string ID *)
            (match json |> member "else_node" with
             | `String id -> Some { id = "_ref_" ^ id; node_type = ChainRef id; input_mapping = []; output_key = None; depends_on = None }
             | _ -> None)
        | else_json ->
            (match parse_node else_json with
             | Ok n -> Some n
             | Error _ -> None)
      in
      Ok (Gate { condition; then_node; else_node })

  | "subgraph" ->
      let graph_json = json |> member "graph" in
      let* chain = parse_chain_inner graph_json in
      Ok (Subgraph chain)

  | "chain_ref" ->
      let* ref_id = require_string json "ref" in
      Ok (ChainRef ref_id)

  | "map" ->
      let* func = require_string json "func" in
      let inner_json = json |> member "inner" in
      let* inner = parse_node inner_json in
      Ok (Map { func; inner })

  | "bind" ->
      let* func = require_string json "func" in
      let inner_json = json |> member "inner" in
      let* inner = parse_node inner_json in
      Ok (Bind { func; inner })

  | "merge" ->
      let strategy_str = parse_string_with_default json "strategy" "concat" in
      let* strategy = parse_merge_strategy strategy_str in
      (* Try "nodes" first, fallback to "inputs" *)
      let nodes_json =
        match json |> member "nodes" with
        | `List l -> l
        | _ -> parse_list_with_default json "inputs"
      in
      let* nodes = parse_nodes nodes_json in
      Ok (Merge { strategy; nodes })

  | "threshold" ->
      let* metric = require_string json "metric" in
      let* operator_str = require_string json "operator" in
      let* operator = parse_threshold_op operator_str in
      let* value = require_float json "value" in  (* Now explicit error on missing/invalid *)
      let input_json = json |> member "input_node" in
      let* input_node = parse_node input_json in
      let on_pass =
        match json |> member "on_pass" with
        | `Null -> None
        | pass_json -> (match parse_node pass_json with Ok n -> Some n | Error _ -> None)
      in
      let on_fail =
        match json |> member "on_fail" with
        | `Null -> None
        | fail_json -> (match parse_node fail_json with Ok n -> Some n | Error _ -> None)
      in
      Ok (Threshold { metric; operator; value; input_node; on_pass; on_fail })

  | "goal_driven" ->
      let* goal_metric = require_string json "goal_metric" in
      let* goal_operator_str = require_string json "goal_operator" in
      let* goal_operator = parse_threshold_op goal_operator_str in
      let* goal_value = require_float json "goal_value" in  (* Explicit error on missing *)
      let action_json = json |> member "action_node" in
      let* action_node = parse_node action_json in
      let* measure_func = require_string json "measure_func" in
      let max_iterations = parse_int_with_default json "max_iterations" 10 in
      let strategy_hints = parse_string_assoc_opt json "strategy_hints" in
      let conversational = parse_bool_with_default json "conversational" false in
      let relay_models = parse_string_list_opt json "relay_models" in
      Ok (GoalDriven {
        goal_metric; goal_operator; goal_value;
        action_node; measure_func; max_iterations; strategy_hints;
        conversational; relay_models
      })

  | "evaluator" ->
      (* Support both top-level fields AND nested evaluator_config for consistency with feedback_loop *)
      let config = match json |> member "evaluator_config" with
        | `Null -> json  (* fallback to top-level fields *)
        | cfg -> cfg
      in
      (* Candidates can be either:
         - String array: ["node_id1", "node_id2"] -> ChainRef nodes
         - Node object array: [{...}, {...}] -> parse as nodes *)
      let candidates_json = match config |> member "candidates" with
        | `List l -> l | `Null -> [] | _ -> []
      in
      let* candidates =
        let is_string_list = List.for_all (function `String _ -> true | _ -> false) candidates_json in
        if is_string_list then
          (* Convert string IDs to ChainRef nodes *)
          Ok (List.filter_map (function
            | `String id -> Some { id = id ^ "_ref"; node_type = ChainRef id;
                                   input_mapping = []; output_key = None; depends_on = None }
            | _ -> None
          ) candidates_json)
        else
          parse_nodes candidates_json
      in
      let* scoring_func = require_string config "scoring_func" in
      let scoring_prompt = match config |> member "scoring_prompt" with
        | `String s -> Some s | _ -> None
      in
      let select_strategy_json = match config |> member "select_strategy" with
        | `Null -> `String "best" | v -> v
      in
      let* select_strategy = parse_select_strategy select_strategy_json in
      let min_score = match config |> member "min_score" with
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | `String "threshold" -> (* support min_threshold alias *)
            (match config |> member "min_threshold" with
             | `Float f -> Some f
             | `Int i -> Some (float_of_int i)
             | _ -> None)
        | _ ->
            (* Also check min_threshold as alias *)
            (match config |> member "min_threshold" with
             | `Float f -> Some f
             | `Int i -> Some (float_of_int i)
             | _ -> None)
      in
      Ok (Evaluator { candidates; scoring_func; scoring_prompt; select_strategy; min_score })

  (* Resilience Nodes *)
  | "retry" ->
      let* input_node = parse_node (json |> member "node") in
      let max_attempts = parse_int_with_default json "max_attempts" 3 in
      let backoff = parse_backoff_strategy json in
      let retry_on = parse_string_list_opt json "retry_on" in
      Ok (Retry { node = input_node; max_attempts; backoff; retry_on })

  | "fallback" ->
      let* primary = parse_node (json |> member "primary") in
      let fallbacks_json = match json |> member "fallbacks" with
        | `List l -> l | _ -> []
      in
      let* fallbacks = parse_nodes fallbacks_json in
      Ok (Fallback { primary; fallbacks })

  | "race" ->
      let nodes_json = match json |> member "nodes" with
        | `List l -> l | _ -> []
      in
      let* nodes = parse_nodes nodes_json in
      let timeout = match json |> member "timeout" with
        | `Float f -> Some f
        | `Int i -> Some (float_of_int i)
        | _ -> None
      in
      Ok (Race { nodes; timeout })

  | "chain_exec" | "chainexec" | "meta" ->
      (* Meta-chain: execute a dynamically generated chain *)
      let chain_source = match json |> member "chain_source" with
        | `String s -> s
        | `Null -> (match json |> member "source" with `String s -> s | _ -> "{{input}}")
        | _ -> "{{input}}"
      in
      let validate = parse_bool_with_default json "validate" true in
      let max_depth = parse_int_with_default json "max_depth" 3 in
      let sandbox = parse_bool_with_default json "sandbox" true in
      let context_inject = parse_string_assoc_opt json "context_inject" in
      let pass_outputs = parse_bool_with_default json "pass_outputs" true in
      Ok (ChainExec { chain_source; validate; max_depth; sandbox; context_inject; pass_outputs })

  (* Data Transformation Node *)
  | "adapter" ->
      (* input_ref is optional, defaults to "input" *)
      let input_ref = parse_string_with_default json "input_ref" "input" in
      let* transform = parse_adapter_transform (json |> member "transform") in
      let on_error =
        match json |> member "on_error" with
        | `String "fail" -> `Fail
        | `String "passthrough" -> `Passthrough
        | `String s when String.length s > 8 && String.sub s 0 8 = "default:" ->
            `Default (String.sub s 8 (String.length s - 8))
        | `Assoc [("default", `String s)] -> `Default s
        | _ -> `Fail
      in
      Ok (Adapter { input_ref; transform; on_error })

  (* Performance Optimization Nodes *)
  | "cache" ->
      let key_expr = parse_string_with_default json "key_expr" "{{input}}" in
      let ttl_seconds = parse_int_with_default json "ttl_seconds" 0 in
      let* inner = parse_node (json |> member "inner") in
      Ok (Cache { key_expr; ttl_seconds; inner })

  | "batch" ->
      let batch_size = parse_int_with_default json "batch_size" 10 in
      let parallel = parse_bool_with_default json "parallel" false in
      let* inner = parse_node (json |> member "inner") in
      let collect_strategy = match parse_string_opt json "collect_strategy" with
        | Some "concat" -> `Concat
        | Some "first" -> `First
        | Some "last" -> `Last
        | _ -> `List
      in
      Ok (Batch { batch_size; parallel; inner; collect_strategy })

  | "spawn" ->
      (* Clean Context Spawn - execute inner with isolated context *)
      let clean = parse_bool_with_default json "clean" true in  (* default: clean *)
      let* inner = parse_node (json |> member "inner") in
      let pass_vars = match json |> member "pass_vars" with
        | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> []
      in
      let inherit_cache = parse_bool_with_default json "inherit_cache" true in
      Ok (Spawn { clean; inner; pass_vars; inherit_cache })

  | "mcts" ->
      (* MCTS - Monte Carlo Tree Search for multi-strategy exploration *)
      let strategies_json = parse_list_with_default json "strategies" in
      let* strategies = parse_nodes strategies_json in
      let* simulation = parse_node (json |> member "simulation") in
      let evaluator = parse_string_with_default json "evaluator" "model_judge" in
      let evaluator_prompt = parse_string_opt json "evaluator_prompt" in
      let* policy = parse_mcts_policy (json |> member "policy") in
      let max_iterations = parse_int_with_default json "max_iterations" 10 in
      let max_depth = parse_int_with_default json "max_depth" 5 in
      let expansion_threshold = parse_int_with_default json "expansion_threshold" 3 in
      let early_stop = parse_float_opt json "early_stop" in
      let parallel_sims = parse_int_with_default json "parallel_sims" 1 in
      Ok (Mcts {
        strategies; simulation; evaluator; evaluator_prompt; policy;
        max_iterations; max_depth; expansion_threshold; early_stop; parallel_sims
      })

  | "stream_merge" ->
      (* StreamMerge - progressive result processing from parallel nodes *)
      let nodes_json = parse_list_with_default json "nodes" in
      let* nodes = parse_nodes nodes_json in
      let reducer = match json |> member "reducer" with
        | `String "first" -> First
        | `String "last" -> Last
        | `String "concat" -> Concat
        | `String "weighted_avg" -> WeightedAvg
        | `Assoc pairs -> (
            match List.assoc_opt "name" pairs with
            | Some (`String name) -> Custom name
            | _ -> Concat  (* default *)
          )
        | `String s -> Custom s  (* treat unknown as custom *)
        | _ -> Concat
      in
      let initial = parse_string_with_default json "initial" "" in
      let min_results = parse_int_opt json "min_results" in
      let timeout = parse_float_opt json "timeout" in
      Ok (StreamMerge { nodes; reducer; initial; min_results; timeout })

  | "feedback_loop" ->
      (* FeedbackLoop - iterative quality improvement with evaluator feedback *)
      let generator_json = json |> member "generator" in
      let* generator = parse_node generator_json in
      (* Parse evaluator_config *)
      let evaluator_config_json = json |> member "evaluator_config" in
      let scoring_func = parse_string_with_default evaluator_config_json "scoring_func" "model_judge" in
      let scoring_prompt = parse_string_opt evaluator_config_json "scoring_prompt" in
      let select_strategy = match evaluator_config_json |> member "select_strategy" with
        | `String "best" -> Best
        | `String "worst" -> Worst
        | `String "weighted_random" -> WeightedRandom
        | `List [`String "above_threshold"; `Float t] -> AboveThreshold t
        | `List [`String "above_threshold"; `Int t] -> AboveThreshold (float_of_int t)
        | _ -> Best  (* default *)
      in
      let evaluator_config = { scoring_func; scoring_prompt; select_strategy } in
      let improver_prompt = parse_string_with_default json "improver_prompt"
        "Improve the output based on this feedback: {{feedback}}\n\nPrevious output: {{previous_output}}" in
      let max_iterations = parse_int_with_default json "max_iterations" 3 in
      (* score_threshold + score_operator (backward compatible: default gte) *)
      let score_threshold = Option.value (parse_float_opt json "score_threshold")
        ~default:(Option.value (parse_float_opt json "min_score") ~default:0.7) in
      let score_operator_str = parse_string_with_default json "score_operator" "gte" in
      let* score_operator = parse_threshold_op score_operator_str in
      let conversational = parse_bool_with_default json "conversational" false in
      let relay_models = parse_string_list_opt json "relay_models" in
      Ok (FeedbackLoop {
        generator; evaluator_config; improver_prompt;
        max_iterations; score_threshold; score_operator;
        conversational; relay_models
      })

  (* MASC Coordination Nodes *)
  | "masc_broadcast" ->
      let* message = require_string json "message" in
      let room = parse_string_opt json "room" in
      let mention = parse_string_list_opt json "mention" in
      Ok (Masc_broadcast { message; room; mention })

  | "masc_listen" ->
      let filter = parse_string_opt json "filter" in
      let timeout_sec = Option.value (parse_float_opt json "timeout_sec") ~default:30.0 in
      let room = parse_string_opt json "room" in
      Ok (Masc_listen { filter; timeout_sec; room })

  | "masc_claim" ->
      let task_id = parse_string_opt json "task_id" in
      let room = parse_string_opt json "room" in
      Ok (Masc_claim { task_id; room })

  | "cascade" ->
      let open Yojson.Safe.Util in
      let default_threshold = match parse_float_opt json "default_threshold" with Some v -> v | None -> 0.7 in
      let tiers_json = json |> member "tiers" |> to_list in
      let* tiers =
        let parse_tier (j : Yojson.Safe.t) (idx : int) : (Chain_types.cascade_tier, string) result =
          (* Backward-compatible with Chain_parser.chain_to_json output (derived yojson). *)
          match Chain_types.cascade_tier_of_yojson j with
          | Ok t -> Ok t
          | Error _ ->
              (* Chain file format: tier_node is a regular node object with "type" (not "node_type"). *)
              let* tier_node =
                match j |> member "tier_node" with
                | `Null -> Error "Missing required field 'tier_node'"
                | tn ->
                    (match tn |> member "type" with
                     | `String _ -> parse_node tn
                     | _ ->
                         (match Chain_types.node_of_yojson tn with
                          | Ok n -> Ok n
                          | Error e -> Error (Printf.sprintf "Invalid tier_node: %s" e)))
              in
              let tier_index = parse_int_with_default j "tier_index" idx in
              let confidence_threshold =
                match parse_float_opt j "confidence_threshold" with
                | Some f -> f
                | None -> default_threshold
              in
              let cost_weight =
                match parse_float_opt j "cost_weight" with
                | Some f -> f
                | None -> 0.0
              in
              let pass_context = parse_bool_with_default j "pass_context" true in
              Ok { Chain_types.tier_node; tier_index; confidence_threshold; cost_weight; pass_context }
        in
        let rec aux acc idx = function
          | [] -> Ok (List.rev acc)
          | j :: rest ->
              (match parse_tier j idx with
               | Ok t -> aux (t :: acc) (idx + 1) rest
               | Error e -> Error (Printf.sprintf "Invalid cascade tier: %s" e))
        in
        aux [] 0 tiers_json
      in
      let confidence_prompt = parse_string_opt json "confidence_prompt" in
      let max_escalations = parse_int_with_default json "max_escalations" 2 in
      let context_mode =
        match parse_string_opt json "context_mode" with
        | Some s -> Chain_types.context_mode_of_string s
        | None -> Chain_types.CM_Summary
      in
      let task_hint = parse_string_opt json "task_hint" in
      Ok (Cascade { tiers; confidence_prompt; max_escalations; context_mode; task_hint; default_threshold })

  | unknown ->
      Error (Printf.sprintf "Unknown node type: %s" unknown)

(** Parse a list of nodes *)
and parse_nodes (json_list : Yojson.Safe.t list) : (node list, string) result =
  let rec aux acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
        match parse_node json with
        | Ok node -> aux (node :: acc) rest
        | Error e -> Error e
  in
  aux [] json_list

(** Parse inner chain (for subgraph) *)
and parse_chain_inner (json : Yojson.Safe.t) : (chain, string) result =
  let open Yojson.Safe.Util in
  try
    let id =
      parse_string_with_default json "id"
        (Printf.sprintf "subgraph_%d" (Random.State.int parser_rng 10000))
    in
    let nodes_json = json |> member "nodes" |> to_list in
    let* nodes = parse_nodes nodes_json in
    let* output = require_string json "output" in
    let config =
      match json |> member "config" with
      | `Null -> default_config
      | cfg -> parse_config cfg
    in
    (* Extract optional preset metadata fields *)
    let name = match json |> member "name" with
      | `String s -> Some s | _ -> None in
    let description = match json |> member "description" with
      | `String s -> Some s | _ -> None in
    let version = match json |> member "version" with
      | `String s -> Some s | _ -> None in
    let input_schema = match json |> member "input_schema" with
      | `Null -> None | v -> Some v in
    let output_schema = match json |> member "output_schema" with
      | `Null -> None | v -> Some v in
    let metadata = match json |> member "metadata" with
      | `Null -> None | v -> Some v in
    Ok { id; nodes; output; config; name; description; version;
         input_schema; output_schema; metadata }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
      Error (Printf.sprintf "Chain JSON type error: %s" msg)
  | exn ->
      Error (Printf.sprintf "Chain parse error: %s" (Printexc.to_string exn))

(** Main entry point: Parse complete chain from JSON *)
let parse_chain (json : Yojson.Safe.t) : (chain, string) result =
  parse_chain_inner json

