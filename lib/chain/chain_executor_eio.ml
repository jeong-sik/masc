(** Chain Executor - Eio-based Parallel Execution Engine

    Executes compiled Chain DSL plans using Eio fibers for concurrency.
    Supports recursive subgraph execution and trace generation.

    Key features:
    - Parallel execution of independent nodes (Fanout, Merge)
    - Sequential pipeline execution
    - N/K quorum consensus
    - Conditional gate execution
    - Recursive subgraph execution
    - Trace generation for debugging

    Types, context management, trace helpers, input resolution, and
    substitution utilities are in {!Chain_executor_helpers}.
*)

(** Re-export all helper types, functions, and leaf node executors *)
include Chain_executor_leaf

(** Forward declaration for recursive execution *)
let rec execute_node ctx ~sw ~clock ~exec_fn ~tool_exec (node : node) : (string, string) result =
  match node.node_type with
  | Model _ -> execute_model_node ctx ~clock ~exec_fn ~node node.node_type
  | Tool _ -> execute_tool_node ctx ~tool_exec ~node node.node_type
  | Pipeline nodes -> execute_pipeline ctx ~sw ~clock ~exec_fn ~tool_exec node nodes
  | Fanout nodes -> execute_fanout ctx ~sw ~clock ~exec_fn ~tool_exec node nodes
  | Quorum { consensus; nodes; weights } -> execute_quorum ctx ~sw ~clock ~exec_fn ~tool_exec node ~consensus ~weights nodes
  | Gate { condition; then_node; else_node } ->
      execute_gate ctx ~sw ~clock ~exec_fn ~tool_exec node ~condition ~then_node ~else_node
  | Subgraph chain -> execute_subgraph ctx ~sw ~clock ~exec_fn ~tool_exec node chain
  | ChainRef ref_id ->
      (* Look up chain in registry and execute as subgraph *)
      (match Chain_registry.lookup ref_id with
       | Some referenced_chain ->
           execute_subgraph ctx ~sw ~clock ~exec_fn ~tool_exec node referenced_chain
       | None ->
           record_error ctx node.id (Printf.sprintf "ChainRef '%s' not found in registry" ref_id);
           Error (Printf.sprintf "ChainRef '%s' not found in registry" ref_id))
  | Map { func; inner } -> execute_map ctx ~sw ~clock ~exec_fn ~tool_exec node ~func inner
  | Bind { func; inner } -> execute_bind ctx ~sw ~clock ~exec_fn ~tool_exec node ~func inner
  | Merge { strategy; nodes } -> execute_merge ctx ~sw ~clock ~exec_fn ~tool_exec node ~strategy nodes
  | Threshold { metric; operator; value; input_node; on_pass; on_fail } ->
      execute_threshold ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~metric ~operator ~value ~input_node ~on_pass ~on_fail
  | GoalDriven { goal_metric; goal_operator; goal_value; action_node; measure_func; max_iterations; strategy_hints; conversational; relay_models } ->
      execute_goal_driven ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~goal_metric ~goal_operator ~goal_value ~action_node ~measure_func ~max_iterations ~strategy_hints ~conversational ~relay_models
  | Evaluator { candidates; scoring_func; scoring_prompt; select_strategy; min_score } ->
      execute_evaluator ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~candidates ~scoring_func ~scoring_prompt ~select_strategy ~min_score
  (* Resilience Nodes *)
  | Retry { node = inner_node; max_attempts; backoff; retry_on } ->
      execute_retry ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~inner_node ~max_attempts ~backoff ~retry_on
  | Fallback { primary; fallbacks } ->
      execute_fallback ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~primary ~fallbacks
  | Race { nodes = race_nodes; timeout } ->
      execute_race ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~nodes:race_nodes ~timeout
  (* Meta-Chain: Execute a dynamically generated chain *)
  | ChainExec { chain_source; validate; max_depth; sandbox = _; context_inject; pass_outputs } ->
      execute_chain_exec ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~chain_source ~validate ~max_depth ~context_inject ~pass_outputs
  (* Data Transformation Node *)
  | Adapter { input_ref; transform; on_error } ->
      execute_adapter ctx node ~input_ref ~transform ~on_error
  (* Caching Node *)
  | Cache { key_expr; ttl_seconds; inner } ->
      execute_cache ctx ~sw ~clock ~exec_fn ~tool_exec node ~key_expr ~ttl_seconds inner
  (* Batch Processing Node *)
  | Batch { batch_size; parallel; inner; collect_strategy } ->
      execute_batch ctx ~sw ~clock ~exec_fn ~tool_exec node ~batch_size ~parallel ~collect_strategy inner
  (* Clean Context Spawn Node *)
  | Spawn { clean; inner; pass_vars; inherit_cache } ->
      execute_spawn ctx ~sw ~clock ~exec_fn ~tool_exec node ~clean ~pass_vars ~inherit_cache inner
  (* Monte Carlo Tree Search Node *)
  | Mcts { strategies; simulation; evaluator; evaluator_prompt; policy;
           max_iterations; max_depth; expansion_threshold; early_stop; parallel_sims } ->
      execute_mcts ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~strategies ~simulation ~evaluator ~evaluator_prompt ~policy
        ~max_iterations ~max_depth ~expansion_threshold ~early_stop ~parallel_sims
  (* StreamMerge: Progressive result processing as nodes complete *)
  | StreamMerge { nodes = stream_nodes; reducer; initial; min_results; timeout } ->
      execute_stream_merge ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~nodes:stream_nodes ~reducer ~initial ~min_results ~timeout
  (* FeedbackLoop: Iterative quality improvement with evaluator feedback *)
  | FeedbackLoop { generator; evaluator_config; improver_prompt; max_iterations; score_threshold; score_operator; conversational; relay_models } ->
      execute_feedback_loop ctx ~sw ~clock ~exec_fn ~tool_exec node
        ~generator ~evaluator_config ~improver_prompt ~max_iterations ~score_threshold ~score_operator
        ~conversational ~relay_models
  (* MASC coordination nodes *)
  | Masc_broadcast { message; room; mention } ->
      execute_masc_broadcast ctx ~tool_exec node ~message ~room ~mention
  | Masc_listen { filter; timeout_sec; room } ->
      execute_masc_listen ctx ~clock ~tool_exec node ~filter ~timeout_sec ~room
  | Masc_claim { task_id; room } ->
      execute_masc_claim ctx ~tool_exec node ~task_id ~room
  (* Cascade: tiered MODEL execution with confidence-based escalation *)
  | Cascade { tiers; confidence_prompt; max_escalations; context_mode; task_hint; default_threshold = _ } ->
      execute_cascade ctx ~sw ~clock ~exec_fn ~tool_exec node tiers ~confidence_prompt max_escalations context_mode task_hint

(** Execute Cascade node: tiered MODEL execution with confidence-based escalation *)

(** {1 Complex node delegations} *)

and execute_cascade ctx ~sw ~clock ~exec_fn ~tool_exec node
    tiers ~confidence_prompt max_escalations context_mode task_hint =
  Chain_executor_complex.execute_cascade ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec node
    tiers ~confidence_prompt max_escalations context_mode task_hint
and execute_goal_driven ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~goal_metric ~goal_operator ~goal_value ~action_node ~measure_func ~max_iterations ~strategy_hints ~conversational ~relay_models =
  Chain_executor_complex.execute_goal_driven ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~goal_metric ~goal_operator ~goal_value ~action_node ~measure_func ~max_iterations ~strategy_hints ~conversational ~relay_models
and execute_feedback_loop ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~generator ~evaluator_config ~improver_prompt ~max_iterations ~score_threshold ~score_operator
    ~conversational ~relay_models =
  Chain_executor_complex.execute_feedback_loop ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~generator ~evaluator_config ~improver_prompt ~max_iterations ~score_threshold ~score_operator
    ~conversational ~relay_models
and execute_stream_merge ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~nodes ~reducer ~initial ~min_results ~timeout =
  Chain_executor_complex.execute_stream_merge ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~nodes ~reducer ~initial ~min_results ~timeout
and execute_mcts ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~strategies ~simulation ~evaluator ~evaluator_prompt ~policy
    ~max_iterations ~max_depth ~expansion_threshold ~early_stop ~parallel_sims =
  Chain_executor_search.execute_mcts ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~strategies ~simulation ~evaluator ~evaluator_prompt ~policy
    ~max_iterations ~max_depth ~expansion_threshold ~early_stop ~parallel_sims
and execute_evaluator ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~candidates ~scoring_func ~scoring_prompt ~select_strategy ~min_score =
  Chain_executor_search.execute_evaluator ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~candidates ~scoring_func ~scoring_prompt ~select_strategy ~min_score
and execute_cache ctx ~sw ~clock ~exec_fn ~tool_exec node ~key_expr ~ttl_seconds inner =
  Chain_executor_resilience.execute_cache ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec node ~key_expr ~ttl_seconds inner
and execute_batch ctx ~sw ~clock ~exec_fn ~tool_exec node ~batch_size ~parallel ~collect_strategy inner =
  Chain_executor_resilience.execute_batch ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec node ~batch_size ~parallel ~collect_strategy inner
and execute_spawn ctx ~sw ~clock ~exec_fn ~tool_exec node ~clean ~pass_vars ~inherit_cache inner =
  Chain_executor_resilience.execute_spawn ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec node ~clean ~pass_vars ~inherit_cache inner
and execute_chain_exec ctx ~sw ~clock ~exec_fn ~tool_exec node
    ~chain_source ~validate ~max_depth ~context_inject ~pass_outputs =
  Chain_executor_resilience.execute_chain_exec ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec node
    ~chain_source ~validate ~max_depth ~context_inject ~pass_outputs
and execute_retry ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~inner_node ~max_attempts ~backoff ~retry_on =
  Chain_executor_resilience.execute_retry ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~inner_node ~max_attempts ~backoff ~retry_on
and execute_fallback ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~primary ~fallbacks =
  Chain_executor_resilience.execute_fallback ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~primary ~fallbacks
and execute_race ctx ~sw ~clock ~exec_fn ~tool_exec parent
    ~nodes ~timeout =
  Chain_executor_resilience.execute_race ctx ~sw ~clock ~exec_fn ~execute_node ~tool_exec parent
    ~nodes ~timeout

(** {1 Structural execution nodes} *)

and execute_sequential ctx ~sw ~clock ~exec_fn ~tool_exec (nodes : node list) : (string, string) result =
  let rec loop last_output = function
    | [] -> Ok last_output
    | node :: rest ->
        match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node with
        | Ok output -> loop output rest
        | Error msg -> Error msg
  in
  loop "" nodes

(** Execute nodes in sequence (Pipeline container node) *)
and execute_pipeline ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) (nodes : node list) : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let result = execute_sequential ctx ~sw ~clock ~exec_fn ~tool_exec nodes in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  (match result with
   | Ok output ->
       store_node_output ctx parent output;
       record_complete ctx parent.id ~duration_ms ~success:true
   | Error msg ->
       record_complete ctx parent.id ~duration_ms ~success:false;
       record_error ctx parent.id msg);
  result

(** Execute nodes in parallel (Fanout) *)
and execute_fanout ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) (nodes : node list) : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Collect results from parallel execution via Eio.Stream *)
  let n = List.length nodes in
  let stream = Eio.Stream.create n in

  Eio.Fiber.all (List.map (fun node ->
    fun () ->
      let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node in
      Eio.Stream.add stream (node.id, result)
  ) nodes);

  let results = List.init n (fun _ -> Eio.Stream.take stream) in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  (* Check if all succeeded *)
  let outputs = List.filter_map (fun (id, r) ->
    match r with Ok o -> Some (id, o) | Error _ -> None
  ) results in

  if List.length outputs = List.length nodes then begin
    let combined = String.concat "\n---\n"
      (List.map (fun (id, o) -> Printf.sprintf "[%s]: %s" id o) outputs) in
    record_complete ctx parent.id ~duration_ms ~success:true;
    store_node_output ctx parent combined;
    Ok combined
  end else begin
    let errors = List.filter_map (fun (id, r) ->
      match r with Error e -> Some (Printf.sprintf "%s: %s" id e) | Ok _ -> None
    ) !results in
    let msg = String.concat "; " errors in
    record_complete ctx parent.id ~duration_ms ~success:false;
    record_error ctx parent.id msg;
    Error msg
  end

(** Execute quorum with consensus algorithm (P1.3)

    In Mermaid DAG: J1 --> V{Quorum:majority}, J2 --> V, J3 --> V
    - J1, J2, J3 execute BEFORE V (topological order)
    - V aggregates already-computed outputs from ctx.outputs
    - Consensus modes: Count(n), Majority, Unanimous, Weighted(threshold)
*)
and execute_quorum ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) ~consensus ~weights (nodes : node list) : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Collect results from already-executed nodes or ChainRef lookups *)
  let successes = ref [] in
  let failures = ref [] in

  List.iter (fun (node : node) ->
    (* For ChainRef nodes (created by mermaid parser for Quorum inputs),
       look up the referenced node's output in ctx.outputs *)
    let result = match node.node_type with
      | ChainRef ref_id ->
          (match Hashtbl.find_opt ctx.outputs ref_id with
           | Some output -> Ok output
           | None -> Error (Printf.sprintf "Input node '%s' not yet executed" ref_id))
      | _ ->
          (* For non-ChainRef nodes, try to execute (backward compat) *)
          execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node
    in
    match result with
    | Ok output -> successes := (node.id, output) :: !successes
    | Error msg -> failures := (node.id, msg) :: !failures
  ) nodes;

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  let total = List.length nodes in
  let success_count = List.length !successes in

  (* P1.3: Evaluate consensus based on mode *)
  let consensus_met = match consensus with
    | Chain_types.Count required ->
        success_count >= required
    | Chain_types.Majority ->
        success_count > total / 2
    | Chain_types.Unanimous ->
        success_count = total
    | Chain_types.Weighted threshold ->
        (* Calculate weighted sum of successes *)
        let get_weight node_id =
          match List.assoc_opt node_id weights with
          | Some w -> w
          | None -> 1.0  (* default weight *)
        in
        let total_weight = List.fold_left (fun acc (n : node) ->
          acc +. get_weight n.id
        ) 0.0 nodes in
        let success_weight = List.fold_left (fun acc (id, _) ->
          acc +. get_weight id
        ) 0.0 !successes in
        if total_weight > 0.0 then
          (success_weight /. total_weight) >= threshold
        else
          false
  in

  if consensus_met then begin
    let combined = String.concat "\n---\n"
      (List.map (fun (id, o) -> Printf.sprintf "[%s]: %s" id o) (List.rev !successes)) in
    record_complete ctx parent.id ~duration_ms ~success:true;
    store_node_output ctx parent combined;
    Ok combined
  end else begin
    let mode_str = Chain_types.consensus_mode_to_string consensus in
    let msg = Printf.sprintf "Consensus not met (%s): got %d/%d successes"
      mode_str success_count total in
    record_complete ctx parent.id ~duration_ms ~success:false;
    record_error ctx parent.id msg;
    Error msg
  end

(** Execute conditional gate *)
and execute_gate ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) ~condition ~then_node ~else_node : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Simple condition evaluation: check if referenced output is truthy *)
  let condition_met =
    let inputs = resolve_inputs ctx parent.input_mapping in
    match List.assoc_opt "condition" inputs with
    | Some "true" | Some "1" | Some "yes" -> true
    | Some "false" | Some "0" | Some "no" -> false
    | Some s when String.length s > 0 -> true
    | _ ->
        (* Fallback: evaluate condition string *)
        condition = "true" || String.length condition = 0
  in

  let result =
    if condition_met then
      execute_node ctx ~sw ~clock ~exec_fn ~tool_exec then_node
    else
      match else_node with
      | Some node -> execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node
      | None -> Ok ""  (* No else branch, return empty *)
  in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  (match result with
  | Ok output ->
      record_complete ctx parent.id ~duration_ms ~success:true;
      store_node_output ctx parent output;
      Ok output
  | Error msg ->
      record_complete ctx parent.id ~duration_ms ~success:false;
      record_error ctx parent.id msg;
      Error msg)

(** Execute a single parallel group (nodes that can run concurrently) *)
and execute_parallel_group ctx ~sw ~clock ~exec_fn ~tool_exec (group : string list) (node_map : (string, node) Hashtbl.t) : (string, string) result =
  if List.length group = 1 then
    (* Single node - execute directly *)
    match list_hd_opt group with
    | None -> Error "empty execution group: received single-element group with no elements"
    | Some node_id ->
    match Hashtbl.find_opt node_map node_id with
    | Some node -> execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node
    | None -> Error (Printf.sprintf "Node '%s' not found in subgraph" node_id)
  else
    (* Multiple nodes - execute in parallel via Eio.Stream *)
    let n = List.length group in
    let stream = Eio.Stream.create n in

    Eio.Fiber.all (List.map (fun node_id ->
      fun () ->
        match Hashtbl.find_opt node_map node_id with
        | Some node ->
            let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node in
            Eio.Stream.add stream (node_id, result)
        | None ->
            Eio.Stream.add stream
              (node_id, Error (Printf.sprintf "Node '%s' not found" node_id))
    ) group);

    let results = List.init n (fun _ -> Eio.Stream.take stream) in
    let has_error = List.find_map (fun (_, r) ->
      match r with Error msg -> Some msg | Ok _ -> None
    ) results in

    (* Return first error if any, otherwise success with last output *)
    match has_error with
    | Some msg -> Error msg
    | None ->
        let outputs = List.filter_map (fun (_, r) ->
          match r with Ok o -> Some o | Error _ -> None
        ) !results in
        Ok (String.concat "\n" outputs)

(** Execute inline subgraph with dependency-based parallelization *)
and execute_subgraph ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) (chain : chain) : (string, string) result =
  record_start ctx parent.id;
  let mermaid_dsl = Some (Chain_mermaid_parser.chain_to_mermaid chain) in
  add_trace ctx parent.id (ChainStart { chain_id = chain.id; mermaid_dsl });
  let start = Time_compat.now () in

  (* Compile chain to get parallel groups *)
  let result = match Chain_compiler.compile chain with
  | Error msg ->
      (* Fallback to sequential if compilation fails *)
      Log.Chain.error "Compilation failed, falling back to sequential: %s" msg;
      execute_sequential ctx ~sw ~clock ~exec_fn ~tool_exec chain.nodes
  | Ok plan ->
      (* Build node lookup map *)
      let node_map = Hashtbl.create (List.length chain.nodes) in
      List.iter (fun (n : node) -> Hashtbl.add node_map n.id n) chain.nodes;

      (* Execute parallel groups sequentially (groups are independent within, dependent between) *)
      let parallel_groups = plan.parallel_groups in
      Log.Chain.info "Executing %d parallel groups for chain '%s'"
        (List.length parallel_groups) chain.id;

      let rec execute_groups groups =
        match groups with
        | [] -> Ok ""
        | group :: rest ->
            Log.Chain.info "Group [%s] (%d nodes)"
              (String.concat ", " group) (List.length group);
            match execute_parallel_group ctx ~sw ~clock ~exec_fn ~tool_exec group node_map with
            | Error msg -> Error msg
            | Ok _ -> execute_groups rest
      in
      execute_groups parallel_groups
  in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  let success = Result.is_ok result in
  add_trace ctx parent.id (ChainComplete { chain_id = chain.id; success });
  record_complete ctx parent.id ~duration_ms ~success;

  (match result with
  | Ok _ ->
      (* Get output from specified output node *)
      let final = match Hashtbl.find_opt ctx.outputs chain.output with
        | Some o -> o
        | None -> ""
      in
      store_node_output ctx parent final;
      Ok final
  | Error msg -> Error msg)

(** Execute map (transform output) *)
and execute_map ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) ~func (inner : node) : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  (match result with
  | Ok output ->
      (* Apply transformation function *)
      let transformed = match func with
        | "uppercase" -> String.uppercase_ascii output
        | "lowercase" -> String.lowercase_ascii output
        | "trim" -> String.trim output
        | "identity" | _ -> output
      in
      record_complete ctx parent.id ~duration_ms ~success:true;
      store_node_output ctx parent transformed;
      Ok transformed
  | Error msg ->
      record_complete ctx parent.id ~duration_ms ~success:false;
      record_error ctx parent.id msg;
      Error msg)

(** Execute bind (dynamic routing based on output) *)
and execute_bind ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) ~func:_ (inner : node) : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Bind executes inner, then could route to another node based on output *)
  (* For now, just execute inner and return *)
  let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  (match result with
  | Ok output ->
      record_complete ctx parent.id ~duration_ms ~success:true;
      store_node_output ctx parent output;
      Ok output
  | Error msg ->
      record_complete ctx parent.id ~duration_ms ~success:false;
      record_error ctx parent.id msg;
      Error msg)

(** Execute merge (combine parallel results) *)
and execute_merge ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node) ~strategy (nodes : node list) : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Execute all nodes in parallel via Eio.Stream, handling ChainRef nodes specially *)
  let n = List.length nodes in
  let stream = Eio.Stream.create n in

  Eio.Fiber.all (List.map (fun (node : node) ->
    fun () ->
      (* For ChainRef nodes, look up in ctx.outputs instead of executing *)
      let result = match node.node_type with
        | ChainRef ref_id ->
            (match Hashtbl.find_opt ctx.outputs ref_id with
             | Some output -> Ok output
             | None -> Error (Printf.sprintf "Input node '%s' not yet executed" ref_id))
        | _ ->
            (* For non-ChainRef nodes, execute normally *)
            execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node
      in
      Eio.Stream.add stream (node.id, result)
  ) nodes);

  let results = List.init n (fun _ -> Eio.Stream.take stream) in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  (* Merge results based on strategy *)
  let outputs = List.filter_map (fun (id, r) ->
    match r with Ok o -> Some (id, o) | Error _ -> None
  ) results in

  match outputs with
  | [] ->
    record_complete ctx parent.id ~duration_ms ~success:false;
    Error "All merge inputs failed"
  | first :: _ ->
    let merged = match strategy with
      | First -> snd first
      | Last -> (match list_last_opt outputs with Some (_, o) -> o | None -> "")
      | Concat -> String.concat "\n" (List.map snd outputs)
      | WeightedAvg ->
          (* Weighted average - for now just concatenate with equal weights *)
          String.concat "\n---\n" (List.map (fun (id, o) ->
            Printf.sprintf "[%s]:\n%s" id o
          ) outputs)
      | Custom func_name ->
          (* Custom merge - for now just annotate with function name *)
          Printf.sprintf "Custom merge '%s':\n%s" func_name
            (String.concat "\n---\n" (List.map snd outputs))
    in
    record_complete ctx parent.id ~duration_ms ~success:true;
    store_node_output ctx parent merged;
    Ok merged

(** Execute threshold node - conditional branching based on metric value *)
and execute_threshold ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~metric ~operator ~value ~input_node ~on_pass ~on_fail : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* First, execute the input node to get the value *)
  match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec input_node with
  | Error msg ->
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error (Printf.sprintf "Threshold input node failed: %s" msg)
  | Ok input_output ->
      (* Extract numeric value from output based on metric *)
      let extracted_value = match metric with
        | "confidence" | "score" | "coverage" | "latency" ->
            (* Try to parse a float from the output *)
            (try Some (float_of_string (String.trim input_output))
             with Failure _ -> None)
        | _ -> None
      in
      (match extracted_value with
       | None ->
           let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
           record_complete ctx parent.id ~duration_ms ~success:false;
           Error (Printf.sprintf "Could not extract metric '%s' from output" metric)
       | Some v ->
           (* Compare value against threshold *)
           let passes = match operator with
             | Gt -> v > value
             | Gte -> v >= value
             | Lt -> v < value
             | Lte -> v <= value
             | Eq -> v = value
             | Neq -> v <> value
           in
           (* Execute appropriate branch *)
           let branch_result =
             if passes then
               match on_pass with
               | Some n -> execute_node ctx ~sw ~clock ~exec_fn ~tool_exec n
               | None -> Ok input_output  (* No pass branch, return input *)
             else
               match on_fail with
               | Some n -> execute_node ctx ~sw ~clock ~exec_fn ~tool_exec n
               | None -> Ok input_output  (* No fail branch, return input *)
           in
           let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
           (match branch_result with
            | Ok output ->
                record_complete ctx parent.id ~duration_ms ~success:true;
                store_node_output ctx parent output;
                Ok output
            | Error msg ->
                record_complete ctx parent.id ~duration_ms ~success:false;
                Error msg))

(** Execute goal-driven iterative node - repeat until goal is met *)

(** {1 Execution Steps and Run Chain} *)


(** Execution step - either single node or parallel group *)
type execution_step =
  | Sequential of node
  | Parallel of node list

(** Convert parallel_groups to execution steps *)
let plan_to_steps (plan : execution_plan) : execution_step list =
  let get_node id =
    List.find_opt (fun (n : node) -> n.id = id) plan.chain.Chain_types.nodes
  in
  List.filter_map (fun group ->
    let nodes = List.filter_map get_node group in
    match nodes with
    | [] -> None
    | [node] -> Some (Sequential node)
    | nodes -> Some (Parallel nodes)
  ) plan.parallel_groups

(** {1 Main Execution Entry Point} *)

(** Execute a compiled execution plan *)
let execute ~sw ~(clock : _ Eio.Time.clock) ~timeout ~trace ~(exec_fn : exec_fn) ~(tool_exec : tool_exec) ?input ?checkpoint (plan : execution_plan) : chain_result =
  let start_time = Time_compat.now () in

  (* Create Langfuse trace for observability if enabled *)
  let langfuse_trace =
    if Langfuse.is_enabled () then
      Some (Langfuse.create_trace
        ~name:plan.chain.Chain_types.id
        ~metadata:[("type", "chain"); ("nodes", string_of_int (List.length plan.chain.Chain_types.nodes))]
        ())
    else None
  in

  let ctx = make_context ~start_time ~trace_enabled:trace ~timeout ~chain_id:plan.chain.Chain_types.id ?langfuse_trace ?checkpoint ()  in

  (* Inject chain.run input as a reserved output key *)
  (match input with
   | Some s -> Hashtbl.replace ctx.outputs "input" s
   | None -> ());

  (* Restore state from checkpoint if resuming *)
  (match ctx.checkpoint.resume_from with
   | Some _ ->
       let _ = restore_from_checkpoint ctx ~chain_id:plan.chain.Chain_types.id in
       ()  (* Outputs are now restored *)
   | None -> ());

  (* Record chain start with mermaid visualization *)
  let mermaid_dsl = Some (Chain_mermaid_parser.chain_to_mermaid plan.chain) in
  List.iter (fun (n : node) -> set_node_status ctx n.id Planned) plan.chain.Chain_types.nodes;
  add_trace ctx plan.chain.Chain_types.id (ChainStart { chain_id = plan.chain.Chain_types.id; mermaid_dsl });

  (* Helper to build chain_result *)
  let make_result ~success ~output =
    let duration_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
    let trace_raw = traces_to_entries (List.rev !(ctx.traces)) in
    let trace = Chain_run_store.enrich_trace_entries ~chain:plan.chain ~outputs:ctx.outputs trace_raw in

    (* End Langfuse trace if enabled *)
    (match langfuse_trace with
     | Some t ->
         (* Update trace metadata with final status *)
         t.Langfuse.metadata <- [
           ("success", string_of_bool success);
           ("duration_ms", string_of_int duration_ms);
           ("output_length", string_of_int (String.length output));
         ];
         Langfuse.end_trace t
     | None -> ());

    let run_id = ctx.checkpoint.run_id in
    Chain_run_store.record
      ~run_id
      ~chain:plan.chain
      ~plan
      ~trace
      ~outputs:ctx.outputs
      ~success
      ~duration_ms
      ~started_at:start_time;

    {
      Chain_types.chain_id = plan.chain.Chain_types.id;
      output;
      success;
      trace;
      token_usage = Chain_types.empty_token_usage;
      duration_ms;
      metadata = [("run_id", run_id)];
    }
  in

  (* Execute each step in the plan with checkpoint support *)
  let rec execute_steps () = function
    | [] ->
        (* Get output from the designated output node *)
        let output = match Hashtbl.find_opt ctx.outputs plan.chain.Chain_types.output with
          | Some o -> o
          | None -> ""
        in
        add_trace ctx plan.chain.Chain_types.id (ChainComplete { chain_id = plan.chain.Chain_types.id; success = true });
        make_result ~success:true ~output
    | step :: rest ->
        let result = match step with
          | Sequential node ->
              (* Skip if node already completed in checkpoint *)
              if node_completed_in_checkpoint ctx node.Chain_types.id then begin
                set_node_status ctx node.Chain_types.id Skipped;
                match Hashtbl.find_opt ctx.outputs node.Chain_types.id with
                | Some v -> Ok v
                | None -> Error "Node marked completed but output missing"
              end
              else begin
                let r = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node in
                (* Save checkpoint after successful node completion *)
                (match r with
                 | Ok _ -> save_checkpoint ctx ~chain_id:plan.chain.Chain_types.id ~node_id:node.Chain_types.id
                 | Error e -> Log.Chain.debug "node %s failed, skipping checkpoint: %s" node.Chain_types.id e);
                r
              end
          | Parallel nodes ->
              (* Filter out already-completed nodes *)
              let nodes_to_execute = List.filter (fun (n : node) ->
                not (node_completed_in_checkpoint ctx n.id)
              ) nodes in
              if List.length nodes_to_execute = 0 then begin
                List.iter (fun (n : node) -> set_node_status ctx n.id Skipped) nodes;
                Ok ""  (* All nodes already completed *)
              end
              else begin
                (* Execute remaining nodes in parallel via Eio.Stream *)
                let n_exec = List.length nodes_to_execute in
                let stream = Eio.Stream.create n_exec in
                Eio.Fiber.all (List.map (fun (node : node) ->
                  fun () ->
                    let r = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node in
                    Eio.Stream.add stream (node.id, r)
                ) nodes_to_execute);
                let results = List.init n_exec (fun _ -> Eio.Stream.take stream) in
                (* Save checkpoint for all successfully completed parallel nodes *)
                List.iter (fun (node_id, r) ->
                  match r with
                  | Ok _ -> save_checkpoint ctx ~chain_id:plan.chain.Chain_types.id ~node_id
                  | Error e -> Log.Chain.debug "parallel node %s failed, skipping checkpoint: %s" node_id e
                ) results;
                (* Check all succeeded *)
                let errors = List.filter_map (fun (id, r) ->
                  match r with Error e -> Some (id ^ ": " ^ e) | Ok _ -> None
                ) results in
                if List.length errors = 0 then Ok ""
                else Error (String.concat "; " errors)
              end
        in
        match result with
        | Ok _ ->
            execute_steps () rest
        | Error msg ->
            add_trace ctx plan.chain.Chain_types.id (ChainComplete { chain_id = plan.chain.Chain_types.id; success = false });
            make_result ~success:false ~output:msg
  in

  (* Execute with timeout using Eio.Time.with_timeout *)
  let timeout_secs = Float.of_int timeout in
  match Eio.Time.with_timeout clock timeout_secs (fun () ->
    Ok (execute_steps () (plan_to_steps plan))
  ) with
  | Ok result -> result
  | Error `Timeout ->
      add_trace ctx plan.chain.Chain_types.id (ChainComplete { chain_id = plan.chain.Chain_types.id; success = false });
      make_result ~success:false ~output:(Printf.sprintf "Execution timeout after %d seconds" timeout)
