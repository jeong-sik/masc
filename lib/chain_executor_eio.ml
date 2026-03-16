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

(** Re-export all helper types and functions for backward compatibility *)
include Chain_executor_helpers

(** Execute a single LLM node *)
let execute_llm_node ctx ~(exec_fn : exec_fn) ~(node : node) (llm : node_type) : (string, string) result =
  match llm with
  | Llm { model; system; prompt; timeout = _; tools; prompt_ref; prompt_vars = _; thinking } ->
      let inputs = resolve_inputs ctx node.input_mapping in
      let resolved_prompt = substitute_prompt prompt inputs in
      (* Apply iteration variable substitution if in GoalDriven context *)
      let final_prompt = substitute_iteration_vars resolved_prompt ctx.iteration_ctx in

      (* Also resolve system instruction if present *)
      let resolved_system = Option.map (fun s -> substitute_prompt s inputs) system in
      let final_system = Option.map (fun s -> substitute_iteration_vars s ctx.iteration_ctx) resolved_system in
      let iteration = match ctx.iteration_ctx with
        | Some it -> it.iteration
        | None -> 0
      in
      let (prompt_with_context, conv_opt, effective_model) =
        match ctx.conversation with
        | None -> (final_prompt, None, model)
        | Some conv ->
            maybe_summarize_and_rotate ~exec_fn conv;
            let context_prompt = build_context_prompt conv in
            let merged_prompt =
              if context_prompt = "" then final_prompt
              else context_prompt ^ "\n\n" ^ final_prompt
            in
            add_message conv ~role:"user" ~content:final_prompt ~iteration ~model:conv.current_model;
            (merged_prompt, Some conv, conv.current_model)
      in
      let (tools_count, tools_shape, tools_invalid) =
        match tools with
        | None -> (0, "none", false)
        | Some (`List items) -> (List.length items, "list", false)
        | Some _ -> (0, "invalid", true)
      in
      let lower_model = String.lowercase_ascii effective_model in
      let supports_tools =
        (lower_model = "llama" ||
         (String.length lower_model > 6 && String.sub lower_model 0 6 = "llama:"))
      in
      let tools_enabled = tools_count > 0 && (not tools_invalid) && supports_tools in
      let tool_choice_reason =
        if tools = None then "no_tools"
        else if tools_invalid then "invalid_schema"
        else if tools_count = 0 then "empty_tools"
        else if not supports_tools then "model_unsupported"
        else "enabled"
      in
      let tools_arg = if tools_enabled then tools else None in
      if Run_log_eio.enabled () then
        Run_log_eio.record_event
          ~event:"tool_choice"
          ~run_id:ctx.checkpoint.run_id
          ~chain_id:ctx.chain_id
          ~node_id:node.id
          ~node_type:"llm"
          ~model:effective_model
          ~success:tools_enabled
          ?error_class:(if tools_count > 0 && not tools_enabled then Some "tools_disabled" else None)
          ~extra:[
            ("tools_count", string_of_int tools_count);
            ("tools_enabled", string_of_bool tools_enabled);
            ("tools_shape", tools_shape);
            ("tools_invalid", string_of_bool tools_invalid);
            ("supports_tools", string_of_bool supports_tools);
            ("decision_reason", tool_choice_reason);
          ]
          ()
      else
        ();
      record_start ctx node.id ~node_type:"llm";
      let start = Time_compat.now () in

      (* Create Langfuse generation if tracing is enabled *)
      let langfuse_gen = match ctx.langfuse_trace with
        | Some trace ->
            let input_str = match final_system with
              | Some sys -> Printf.sprintf "[system] %s\n[user] %s" sys prompt_with_context
              | None -> prompt_with_context
            in
            Some (Langfuse.create_generation ~trace ~name:node.id ~model:effective_model ~input:input_str ())
        | None -> None
      in

      (* Phase 6: GLM thinking auto-activation
         Enable thinking for GLM models when:
         - Node explicitly requests thinking=true, OR
         - Model is GLM variant AND prompt is complex (length>500, code blocks, multi-step) *)
      let effective_thinking =
        if thinking then true  (* Explicitly requested *)
        else if is_glm_model effective_model && is_complex_prompt prompt_with_context then
          (if Run_log_eio.enabled () then
            Run_log_eio.record_event
              ~event:"glm_thinking_auto"
              ~run_id:ctx.checkpoint.run_id
              ~chain_id:ctx.chain_id
              ~node_id:node.id
              ~node_type:"llm"
              ~model:effective_model
              ~success:true
              ~extra:[("reason", "complex_prompt_detected")]
              ();
           true)
        else false
      in
      let thinking_arg = if effective_thinking then Some true else None in

      (* Empty response guard: retry with enhanced prompt on empty output *)
      let rec try_with_empty_guard ~attempt ~prompt_to_use =
        let result = exec_fn ~model:effective_model ?system:final_system ~prompt:prompt_to_use ?tools:tools_arg ?thinking:thinking_arg () in
        let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
        match result with
        | Ok output when is_empty_response output && attempt < max_empty_retries ->
            (* Empty response detected - log and retry with enhanced prompt *)
            if Run_log_eio.enabled () then
              Run_log_eio.record_event
                ~event:"empty_response_retry"
                ~run_id:ctx.checkpoint.run_id
                ~chain_id:ctx.chain_id
                ~node_id:node.id
                ~node_type:"llm"
                ~model:effective_model
                ~success:false
                ~extra:[
                  ("attempt", string_of_int attempt);
                  ("max_retries", string_of_int max_empty_retries);
                  ("action", "retrying_with_enhanced_prompt");
                ]
                ();
            (* Retry with enhanced prompt *)
            let enhanced_prompt = prompt_to_use ^ empty_retry_suffix in
            try_with_empty_guard ~attempt:(attempt + 1) ~prompt_to_use:enhanced_prompt
        | Ok output when is_empty_response output ->
            (* Max retries exhausted - return error *)
            record_complete ctx node.id ~duration_ms ~success:false ~node_type:"llm";
            record_error ctx node.id ~node_type:"llm"
              (Printf.sprintf "Empty response after %d retries" max_empty_retries);
            Error (Printf.sprintf "LLM returned empty response after %d retries" max_empty_retries)
        | Ok output ->
            (* Valid non-empty response *)
            let prompt_tokens = (String.length prompt_to_use + (match final_system with Some s -> String.length s | None -> 0)) / 4 in
            let completion_tokens = String.length output / 4 in
            let node_tokens = {
              Chain_category.prompt_tokens;
              completion_tokens;
              total_tokens = prompt_tokens + completion_tokens;
              estimated_cost_usd = 0.0;
            } in
            ctx.total_tokens <- Chain_category.Token_monoid.concat ctx.total_tokens node_tokens;

            (* Log if retry was needed *)
            if attempt > 1 && Run_log_eio.enabled () then
              Run_log_eio.record_event
                ~event:"empty_response_recovered"
                ~run_id:ctx.checkpoint.run_id
                ~chain_id:ctx.chain_id
                ~node_id:node.id
                ~node_type:"llm"
                ~model:effective_model
                ~success:true
                ~extra:[
                  ("attempts_needed", string_of_int attempt);
                ]
                ();

            (* End Langfuse generation with success *)
            (match langfuse_gen with
             | Some gen -> Langfuse.end_generation gen ~output ~prompt_tokens ~completion_tokens
             | None -> ());

            (* Update Prompt Registry metrics if prompt_ref was used *)
            (match prompt_ref with
             | Some ref ->
                 let (id, version) = match String.split_on_char '@' ref with
                   | [id; ver] -> (id, ver)
                   | [id] ->
                       (match Prompt_registry.get ~id () with
                        | Some entry -> (id, entry.version)
                        | None -> (id, "1.0"))
                   | _ -> (ref, "1.0")
                 in
                 let score = min 1.0 (float_of_int (String.length output) /. 500.0) in
                 Prompt_registry.update_metrics ~id ~version ~score ()
             | None -> ());

            (match conv_opt with
            | Some conv -> add_message conv ~role:"assistant" ~content:output ~iteration ~model
             | None -> ());

            record_complete ctx node.id ~duration_ms ~success:true ~node_type:"llm";
            store_node_output ctx node output;
            Ok output
        | Error msg ->
            (* Pass through LLM errors as before *)
            Error msg
      in
      let final_result = try_with_empty_guard ~attempt:1 ~prompt_to_use:prompt_with_context in
      (match final_result with
      | Ok output -> Ok output
      | Error msg ->
          (* Calculate duration for error case *)
          let error_duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

          (* End Langfuse generation with error *)
          (match langfuse_gen with
           | Some gen -> Langfuse.error_generation gen ~message:msg
           | None -> ());

          (* Update Prompt Registry metrics with low score on error *)
          (match prompt_ref with
           | Some ref ->
               let (id, version) = match String.split_on_char '@' ref with
                 | [id; ver] -> (id, ver)
                 | [id] ->
                     (match Prompt_registry.get ~id () with
                      | Some entry -> (id, entry.version)
                      | None -> (id, "1.0"))
                 | _ -> (ref, "1.0")
               in
               Prompt_registry.update_metrics ~id ~version ~score:0.0 ()
           | None -> ());

          record_complete ctx node.id ~duration_ms:error_duration_ms ~success:false ~node_type:"llm";
          record_error ctx node.id ~node_type:"llm" msg;
          Error msg)
  | _ -> Error "execute_llm_node called with non-LLM node"

(** MASC MCP endpoint - configurable via MASC_MCP_URL env var *)
let _masc_mcp_url () =
  Option.value ~default:(Env_config.masc_http_base_url () ^ "/mcp") (Sys.getenv_opt "MASC_MCP_URL")

(** Get MASC agent name from env or default *)
let masc_agent_name () =
  Option.value ~default:"local-worker" (Sys.getenv_opt "MASC_AGENT_NAME")

(** Execute MASC broadcast node - calls masc.masc_broadcast via tool_exec *)
let execute_masc_broadcast ctx ~tool_exec (node : node) ~message ~room ~mention : (string, string) result =
  record_start ctx node.id ~node_type:"masc_broadcast";
  let start = Time_compat.now () in
  let inputs = Hashtbl.fold (fun k v acc -> (k, v) :: acc) ctx.outputs [] in
  let resolved_message = substitute_prompt message inputs in
  let mentions_str = if mention = [] then "" else " " ^ String.concat " " mention in
  let full_message = resolved_message ^ mentions_str in
  (* Build MASC arguments *)
  let args = `Assoc ([
    ("agent_name", `String (masc_agent_name ()));
    ("message", `String full_message);
    ("format", `String "verbose");
  ] @ (match room with Some r -> [("room", `String r)] | None -> []))
  in
  (* Call masc.masc_broadcast via tool_exec *)
  let result =
    try tool_exec ~name:"masc.masc_broadcast" ~args
    with exn -> Error (Printexc.to_string exn)
  in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  match result with
  | Ok output ->
      record_complete ctx node.id ~duration_ms ~success:true ~node_type:"masc_broadcast";
      store_node_output ctx node output;
      Ok output
  | Error msg ->
      record_error ctx node.id msg;
      record_complete ctx node.id ~duration_ms ~success:false ~node_type:"masc_broadcast";
      Error msg

(** Execute MASC listen node - polls masc.masc_messages with timeout *)
let execute_masc_listen ctx ~clock ~tool_exec (node : node) ~filter ~timeout_sec ~room : (string, string) result =
  record_start ctx node.id ~node_type:"masc_listen";
  let start = Time_compat.now () in
  let poll_interval = 0.5 in (* Poll every 500ms *)
  let filter_re = Option.map Re.Pcre.regexp filter in

  (* Poll loop with timeout *)
  let rec poll_loop ~since_seq ~collected =
    let elapsed = Time_compat.now () -. start in
    if elapsed >= timeout_sec then begin
      (* Timeout reached, return collected messages *)
      let messages_json = Printf.sprintf "[%s]" (String.concat "," (List.rev collected)) in
      let result_json = Printf.sprintf {|{"listened": true, "filter": %s, "timeout_sec": %.1f, "room": %s, "messages": %s}|}
        (match filter with Some f -> Printf.sprintf {|"%s"|} (String.escaped f) | None -> "null")
        timeout_sec
        (match room with Some r -> Printf.sprintf {|"%s"|} r | None -> "null")
        messages_json
      in
      Ok result_json
    end else begin
      (* Build arguments for masc_messages *)
      let args = `Assoc ([
        ("since_seq", `Int since_seq);
        ("limit", `Int 20);
      ] @ (match room with Some r -> [("room", `String r)] | None -> []))
      in
      match tool_exec ~name:"masc.masc_messages" ~args with
      | Error msg -> Error msg
      | Ok output ->
          (* Parse messages and filter if needed *)
          let open Yojson.Safe.Util in
          (try
            let json = Yojson.Safe.from_string output in
            let messages = json |> member "messages" |> to_list in
            let max_seq =
              List.fold_left (fun acc m ->
                max acc (m |> member "seq" |> to_int_option |> Option.value ~default:acc)
              ) since_seq messages
            in
            let filtered = match filter_re with
              | None -> messages
              | Some re -> List.filter (fun m ->
                  let content = m |> member "content" |> to_string_option |> Option.value ~default:"" in
                  Re.execp re content
                ) messages
            in
            let new_collected = List.fold_left (fun acc m ->
              (Yojson.Safe.to_string m) :: acc
            ) collected filtered in
            (* If we got messages matching filter, we can return early *)
            if filtered <> [] then begin
              let messages_json = Printf.sprintf "[%s]" (String.concat "," (List.rev new_collected)) in
              let result_json = Printf.sprintf {|{"listened": true, "filter": %s, "timeout_sec": %.1f, "room": %s, "messages": %s}|}
                (match filter with Some f -> Printf.sprintf {|"%s"|} (String.escaped f) | None -> "null")
                timeout_sec
                (match room with Some r -> Printf.sprintf {|"%s"|} r | None -> "null")
                messages_json
              in
              Ok result_json
            end else begin
              (* Wait and poll again *)
              Eio.Time.sleep clock poll_interval;
              poll_loop ~since_seq:max_seq ~collected:new_collected
            end
          with
          | Yojson.Json_error _ | Yojson.Safe.Util.Type_error (_, _) ->
            (* Parse error, wait and retry *)
            Eio.Time.sleep clock poll_interval;
            poll_loop ~since_seq ~collected)
    end
  in
  let result = poll_loop ~since_seq:0 ~collected:[] in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  match result with
  | Ok output ->
      record_complete ctx node.id ~duration_ms ~success:true ~node_type:"masc_listen";
      store_node_output ctx node output;
      Ok output
  | Error msg ->
      record_error ctx node.id msg;
      record_complete ctx node.id ~duration_ms ~success:false ~node_type:"masc_listen";
      Error msg

(** Execute MASC claim node - calls masc.masc_claim or masc.masc_claim_next *)
let execute_masc_claim ctx ~tool_exec (node : node) ~task_id ~room : (string, string) result =
  record_start ctx node.id ~node_type:"masc_claim";
  let start = Time_compat.now () in
  (* Choose tool based on whether task_id is provided *)
  let tool_name, args = match task_id with
    | Some tid ->
        (* Specific task claim *)
        ("masc.masc_claim", `Assoc ([
          ("agent_name", `String (masc_agent_name ()));
          ("task_id", `String tid);
        ] @ (match room with Some r -> [("room", `String r)] | None -> [])))
    | None ->
        (* Claim next available task *)
        ("masc.masc_claim_next", `Assoc ([
          ("agent_name", `String (masc_agent_name ()));
        ] @ (match room with Some r -> [("room", `String r)] | None -> [])))
  in
  let result =
    try tool_exec ~name:tool_name ~args
    with exn -> Error (Printexc.to_string exn)
  in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  match result with
  | Ok output ->
      record_complete ctx node.id ~duration_ms ~success:true ~node_type:"masc_claim";
      store_node_output ctx node output;
      Ok output
  | Error msg ->
      record_error ctx node.id msg;
      record_complete ctx node.id ~duration_ms ~success:false ~node_type:"masc_claim";
      Error msg

(** Execute a tool node *)
let execute_tool_node ctx ~tool_exec ~(node : node) (tool : node_type) : (string, string) result =
  match tool with
  | Tool { name; args } ->
      record_start ctx node.id ~node_type:"tool";
      let start = Time_compat.now () in
      let resolved_args = substitute_json ctx args in
      let result =
        try tool_exec ~name ~args:resolved_args
        with exn -> Error (Printexc.to_string exn)
      in
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      (match result with
      | Ok output ->
          record_complete ctx node.id ~duration_ms ~success:true ~node_type:"tool";
          store_node_output ctx node output;
          Ok output
      | Error msg ->
          record_complete ctx node.id ~duration_ms ~success:false ~node_type:"tool";
          record_error ctx node.id ~node_type:"tool" msg;
          Error msg)
  | _ -> Error "execute_tool_node called with non-Tool node"

(** Apply adapter transformation to input value - delegated to Chain_adapter_eio *)
let apply_adapter_transform = Chain_adapter_eio.apply_adapter_transform


(** Execute an adapter node *)
let execute_adapter ctx (node : node) ~input_ref ~transform ~on_error : (string, string) result =
  record_start ctx node.id ~node_type:"adapter";
  let start = Time_compat.now () in
  let finalize ~success ~duration_ms output =
    record_complete ctx node.id ~duration_ms ~success ~node_type:"adapter";
    store_node_output ctx node output;
    output
  in
  (* Resolve input reference *)
  let input_value = resolve_single_input ctx input_ref in
  if input_value = "" then begin
    let msg = Printf.sprintf "Adapter: empty input from '%s'" input_ref in
    let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
    match on_error with
    | `Fail ->
        record_error ctx node.id ~node_type:"adapter" msg;
        record_complete ctx node.id ~duration_ms ~success:false ~node_type:"adapter";
        Error msg
    | `Passthrough ->
        Log.Chain.warn "%s (passthrough)" msg;
        Ok (finalize ~success:true ~duration_ms "")
    | `Default d ->
        Log.Chain.warn "%s (default)" msg;
        Ok (finalize ~success:true ~duration_ms d)
  end
  else
    (* Apply transformation *)
    let result = apply_adapter_transform transform input_value in
    let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
    match result with
    | Ok output ->
        Ok (finalize ~success:true ~duration_ms output)
    | Error msg ->
        record_error ctx node.id ~node_type:"adapter" msg;
        (match on_error with
         | `Fail ->
             record_complete ctx node.id ~duration_ms ~success:false ~node_type:"adapter";
             Error msg
         | `Passthrough ->
             Ok (finalize ~success:true ~duration_ms input_value)
         | `Default d ->
             Ok (finalize ~success:true ~duration_ms d))

(** {1 Recursive Execution} *)

(** MCTS Tree Node - mutable for backpropagation *)
type mcts_tree_node = {
  strategy_idx : int;                     (* Index into strategies list *)
  mutable visits : int;
  mutable total_score : float;
  mutable children : mcts_tree_node list;
  parent : mcts_tree_node option;
  depth : int;
  last_output : string ref;               (* Store simulation output for expansion *)
}

(** Calculate UCB1 value for node selection *)
let ucb1_value ~c (parent_visits : int) (node : mcts_tree_node) : float =
  if node.visits = 0 then Float.infinity
  else
    let exploitation = node.total_score /. float_of_int node.visits in
    let exploration = c *. sqrt (log (float_of_int parent_visits) /. float_of_int node.visits) in
    exploitation +. exploration

(** String helper - from Chain_utils *)
let string_contains = Chain_utils.string_contains

(** {2 Cascade helpers} *)

(** Parse confidence level from LLM output. Returns (confidence_level, cleaned_output) *)
let parse_confidence_from_output (output : string) : (Chain_types.confidence_level * string) =
  let re = Str.regexp_case_fold {|[Cc]onfidence:\s*\(High\|Medium\|Low\)|} in
  try
    ignore (Str.search_forward re output 0);
    let level_str = Str.matched_group 1 output in
    let level = Chain_types.confidence_of_string level_str in
    (* Remove the confidence line from output *)
    let cleaned = Str.global_replace (Str.regexp_case_fold {|[Cc]onfidence:\s*\(High\|Medium\|Low\)\n?|}) "" output in
    (level, String.trim cleaned)
  with Not_found ->
    (Low, output)

let build_confidence_system_prompt ~confidence_prompt task_hint =
  match confidence_prompt with
  | Some custom -> custom
  | None ->
    let hint = match task_hint with Some h -> Printf.sprintf " Task: %s." h | None -> "" in
    Printf.sprintf "After your response, on a new line, rate your confidence: 'Confidence: High', 'Confidence: Medium', or 'Confidence: Low'.%s" hint

let summarize_for_context output =
  let max_len = 500 in
  if String.length output <= max_len then output
  else String.sub output 0 max_len ^ "..."

(** Forward declaration for recursive execution *)
let rec execute_node ctx ~sw ~clock ~exec_fn ~tool_exec (node : node) : (string, string) result =
  match node.node_type with
  | Llm _ -> execute_llm_node ctx ~exec_fn ~node node.node_type
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
  (* Cascade: tiered LLM execution with confidence-based escalation *)
  | Cascade { tiers; confidence_prompt; max_escalations; context_mode; task_hint; default_threshold = _ } ->
      execute_cascade ctx ~sw ~clock ~exec_fn ~tool_exec node tiers ~confidence_prompt max_escalations context_mode task_hint

(** Execute Cascade node: tiered LLM execution with confidence-based escalation *)
and execute_cascade ctx ~sw ~clock ~exec_fn ~tool_exec (node : node)
    tiers ~confidence_prompt max_escalations context_mode task_hint =
  record_start ctx node.id ~node_type:"cascade";
  let start = Time_compat.now () in
  let sorted_tiers = List.sort (fun a b -> compare a.Chain_types.tier_index b.Chain_types.tier_index) tiers in
  let confidence_system = build_confidence_system_prompt ~confidence_prompt task_hint in
  let rec try_tier remaining escalations hard_failures prev_context =
    match remaining with
    | [] ->
      (* All tiers exhausted -- return last tier's output or error *)
      let last_output = match prev_context with Some c -> c | None -> "All cascade tiers exhausted" in
      Hashtbl.replace ctx.outputs "cascade_tier" "exhausted";
      Hashtbl.replace ctx.outputs "cascade_escalations" (string_of_int escalations);
      Hashtbl.replace ctx.outputs "cascade_hard_failures" (string_of_int hard_failures);
      Chain_stats.track_cascade ~resolved_tier:(List.length sorted_tiers - 1) ~escalations ~hard_failures;
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx node.id ~duration_ms ~success:true ~node_type:"cascade";
      store_node_output ctx node last_output;
      Ok last_output
    | tier :: rest ->
      if escalations >= max_escalations then begin
        let output = match prev_context with Some c -> c | None -> "Max escalations reached" in
        Hashtbl.replace ctx.outputs "cascade_tier" (string_of_int tier.Chain_types.tier_index);
        Hashtbl.replace ctx.outputs "cascade_escalations" (string_of_int escalations);
        Hashtbl.replace ctx.outputs "cascade_hard_failures" (string_of_int hard_failures);
        Chain_stats.track_cascade ~resolved_tier:tier.tier_index ~escalations ~hard_failures;
        let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
        record_complete ctx node.id ~duration_ms ~success:true ~node_type:"cascade";
        store_node_output ctx node output;
        Ok output
      end else begin
        (* Inject confidence prompt into tier's LLM system instruction *)
        let tier_node = match tier.tier_node.node_type with
          | Llm llm_config ->
            let augmented_system = match llm_config.system with
              | Some s -> Some (s ^ "\n\n" ^ confidence_system)
              | None -> Some confidence_system
            in
            { tier.tier_node with node_type = Llm { llm_config with system = augmented_system } }
          | _ -> tier.tier_node
        in
        (* Add context from previous tier if applicable *)
        let tier_node = match context_mode, prev_context with
          | Chain_types.CM_None, _ | _, None -> tier_node
          | CM_Summary, Some prev ->
            let summary = summarize_for_context prev in
            (match tier_node.node_type with
             | Llm llm_config ->
               let new_prompt = Printf.sprintf "Previous attempt (summarized): %s\n\n%s" summary llm_config.prompt in
               { tier_node with node_type = Llm { llm_config with prompt = new_prompt } }
             | _ -> tier_node)
          | CM_Full, Some prev ->
            (match tier_node.node_type with
             | Llm llm_config ->
               let new_prompt = Printf.sprintf "Previous attempt (full): %s\n\n%s" prev llm_config.prompt in
               { tier_node with node_type = Llm { llm_config with prompt = new_prompt } }
             | _ -> tier_node)
        in
        try
          match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec tier_node with
          | Ok raw_output ->
            let (confidence, cleaned) = parse_confidence_from_output raw_output in
            let score = Chain_types.confidence_to_float confidence in
            if score >= tier.confidence_threshold then begin
              Hashtbl.replace ctx.outputs "cascade_tier" (string_of_int tier.tier_index);
              Hashtbl.replace ctx.outputs "cascade_escalations" (string_of_int escalations);
              Hashtbl.replace ctx.outputs "cascade_hard_failures" (string_of_int hard_failures);
              Chain_stats.track_cascade ~resolved_tier:tier.tier_index ~escalations ~hard_failures;
              let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
              record_complete ctx node.id ~duration_ms ~success:true ~node_type:"cascade";
              store_node_output ctx node cleaned;
              Ok cleaned
            end else
              try_tier rest (escalations + 1) hard_failures (Some cleaned)
          | Error msg ->
            record_error ctx node.id msg;
            try_tier rest escalations (hard_failures + 1) prev_context
        with
        | Out_of_memory | Stack_overflow | Sys.Break as exn -> raise exn
        | exn ->
          record_error ctx node.id (Printexc.to_string exn);
          try_tier rest escalations (hard_failures + 1) prev_context
      end
  in
  try_tier sorted_tiers 0 0 None

(** Execute Monte Carlo Tree Search node *)
and execute_mcts ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~strategies ~simulation ~evaluator ~evaluator_prompt ~policy
    ~max_iterations ~max_depth ~expansion_threshold ~early_stop ~parallel_sims
    : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Get exploration constant from policy *)
  let exploration_c = match policy with
    | UCB1 c -> c
    | Greedy -> 0.0
    | EpsilonGreedy _ -> 1.414
    | Softmax _ -> 1.414
  in

  (* Create root node with initial strategies as children *)
  let root = {
    strategy_idx = -1;
    visits = 0;
    total_score = 0.0;
    children = [];
    parent = None;
    depth = 0;
    last_output = ref "";
  } in

  (* Initialize children for each strategy *)
  root.children <- List.mapi (fun i _ -> {
    strategy_idx = i;
    visits = 0;
    total_score = 0.0;
    children = [];
    parent = Some root;
    depth = 1;
    last_output = ref "";
  }) strategies;

  (* Selection phase: traverse tree using UCB1/policy to find node to expand.
     Returns (Ok node) on success, (Error msg) if tree is in an invalid state. *)
  let rec select (node : mcts_tree_node) : (mcts_tree_node, string) result =
    if node.children = [] || node.depth >= max_depth then Ok node
    else
      let parent_visits = max 1 node.visits in
      let selected = match policy with
        | UCB1 _ | EpsilonGreedy _ ->
            (* UCB1 or epsilon-greedy uses UCB1 for selection *)
            let with_scores = List.map (fun child ->
              (child, ucb1_value ~c:exploration_c parent_visits child)
            ) node.children in
            let sorted = List.sort (fun (_, s1) (_, s2) -> Float.compare s2 s1) with_scores in
            (match sorted with
             | (best, _) :: _ -> Ok best
             | [] -> Error "MCTS select: leaf node has no children to expand (UCB1)")
        | Greedy ->
            (* Pure exploitation: pick highest average score *)
            let with_avg = List.map (fun child ->
              let avg = if child.visits = 0 then 0.0 else child.total_score /. float_of_int child.visits in
              (child, avg)
            ) node.children in
            let sorted = List.sort (fun (_, s1) (_, s2) -> Float.compare s2 s1) with_avg in
            (match sorted with
             | (best, _) :: _ -> Ok best
             | [] -> Error "MCTS select: leaf node has no children to expand (Greedy)")
        | Softmax temp ->
            (* Softmax selection with temperature *)
            let scores = List.map (fun child ->
              if child.visits = 0 then 0.0 else child.total_score /. float_of_int child.visits
            ) node.children in
            let max_score = List.fold_left max Float.neg_infinity scores in
            let exp_scores = List.map (fun s -> exp ((s -. max_score) /. temp)) scores in
            let sum = List.fold_left (+.) 0.0 exp_scores in
            let probs = List.map (fun e -> e /. sum) exp_scores in
            (* Sample from distribution - using fiber-safe RNG *)
            let r = Random.State.float executor_rng 1.0 in
            let rec sample acc = function
              | [] ->
                  (match list_hd_opt node.children with
                   | Some c -> Ok c
                   | None -> Error "MCTS select: empty candidate group (Softmax sampling exhausted)")
              | (child, prob) :: rest ->
                  let acc' = acc +. prob in
                  if r < acc' then Ok child else sample acc' rest
            in
            sample 0.0 (List.combine node.children probs)
      in
      match selected with
      | Error _ as e -> e
      | Ok s -> select s
  in

  (* Expansion phase: add new child nodes if visits exceed threshold *)
  let expand (node : mcts_tree_node) : (mcts_tree_node, string) result =
    if node.visits >= expansion_threshold && node.depth < max_depth && node.children = [] then begin
      (* Create children by re-using all strategies (exploring different paths) *)
      node.children <- List.mapi (fun i _ -> {
        strategy_idx = i;
        visits = 0;
        total_score = 0.0;
        children = [];
        parent = Some node;
        depth = node.depth + 1;
        last_output = ref "";
      }) strategies;
      (* Return first unvisited child *)
      match node.children with
      | first :: _ -> Ok first
      | [] -> Error "MCTS expand: empty candidate group (no strategies to expand)"
    end
    else Ok node
  in

  (* Simulation phase: execute strategy and simulation in clean context *)
  let simulate (node : mcts_tree_node) : float =
    match list_nth_opt strategies node.strategy_idx with
    | None ->
        (* Invalid strategy index — treat as failed strategy *)
        Eio.traceln "[MCTS] invalid strategy index %d (strategies=%d)"
          node.strategy_idx (List.length strategies);
        0.0
    | Some strategy_node ->
    (* Execute strategy in current context first *)
    let strategy_result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec strategy_node in
    match strategy_result with
    | Error _ -> 0.0  (* Failed strategy gets 0 score *)
    | Ok strategy_output ->
        node.last_output := strategy_output;
        (* Store strategy output for simulation *)
        Hashtbl.replace ctx.outputs strategy_node.Chain_types.id strategy_output;
        (* Execute simulation in spawned clean context *)
        let sim_result = execute_spawn ctx ~sw ~clock ~exec_fn ~tool_exec simulation
          ~clean:true ~pass_vars:[strategy_node.Chain_types.id] ~inherit_cache:false simulation in
        match sim_result with
        | Error _ -> 0.0
        | Ok sim_output ->
            (* Score the simulation output *)
            let score = match evaluator with
            | "llm_judge" ->
                let prompt = match evaluator_prompt with
                  | Some p -> Printf.sprintf "%s\n\nOutput to evaluate:\n%s" p sim_output
                  | None -> Printf.sprintf "Rate this output from 0.0 to 1.0:\n%s" sim_output
                in
                (match exec_fn ~model:"gemini" ?system:None ~prompt ?tools:None () with
                 | Ok s ->
                     let raw = Safe_parse.float ~context:"llm_judge" ~default:0.5 (String.trim s) in
                     Float.min 1.0 (Float.max 0.0 raw)
                 | Error _ -> 0.5)
            | "exec_test" ->
                (* Parse test results: look for pass rate or coverage *)
                let regex = Str.regexp "\\([0-9]+\\)/\\([0-9]+\\)\\|coverage[: ]+\\([0-9.]+\\)" in
                (try
                  let _ = Str.search_forward regex sim_output 0 in
                  try
                    let passed = float_of_string (Str.matched_group 1 sim_output) in
                    let total = float_of_string (Str.matched_group 2 sim_output) in
                    passed /. total
                  with Failure _ | Not_found | Invalid_argument _ ->
                    float_of_string (Str.matched_group 3 sim_output)
                with Not_found -> 0.5)
            | "anti_fake" ->
                (* Hybrid heuristic + LLM scoring for code quality *)
                let heuristic_score =
                  let penalties = [
                    ("assert true", -0.3); ("let _ =", -0.2); ("(* TODO", -0.15);
                    ("skip", -0.1); ("ignore", -0.1);
                  ] in
                  let bonuses = [
                    ("assert_equal", 0.1); ("expect", 0.1); ("roundtrip", 0.15);
                    ("property", 0.1); ("quickcheck", 0.1);
                  ] in
                  let base = 0.5 in
                  let pen = List.fold_left (fun acc (pat, pen) ->
                    if string_contains ~substring:pat sim_output then acc +. pen else acc
                  ) 0.0 penalties in
                  let bon = List.fold_left (fun acc (pat, bon) ->
                    if string_contains ~substring:pat sim_output then acc +. bon else acc
                  ) 0.0 bonuses in
                  Float.min 1.0 (Float.max 0.0 (base +. pen +. bon))
                in
                (* LLM judge for semantic analysis *)
                let llm_score =
                  let prompt = Printf.sprintf
                    "Rate this code/test quality from 0.0 to 1.0. Check for: fake tests, missing assertions, incomplete coverage.\n\n%s"
                    sim_output
                  in
                  match exec_fn ~model:"gemini" ?system:None ~prompt ?tools:None () with
                  | Ok s -> Safe_parse.float ~context:"anti_fake:llm" ~default:0.5 (String.trim s)
                  | Error _ -> 0.5
                in
                (heuristic_score +. llm_score) /. 2.0
            | _ ->
                (* Default: try to parse as float or return 0.5 *)
                Safe_parse.float ~context:"score:default" ~default:0.5 (String.trim sim_output)
            in
            score
  in

  (* Backpropagation phase: update scores up the tree *)
  let rec backpropagate (node : mcts_tree_node) (score : float) : unit =
    node.visits <- node.visits + 1;
    node.total_score <- node.total_score +. score;
    match node.parent with
    | Some p -> backpropagate p score
    | None -> ()
  in

  (* Main MCTS loop *)
  let best_output = ref "" in
  let best_score = ref Float.neg_infinity in
  let tree_mutex = Eio.Mutex.create () in  (* Protect tree modifications *)

  let rec mcts_iteration iteration =
    if iteration >= max_iterations then ()
    else begin
      (* Run parallel simulations *)
      let sim_results = ref [] in
      let results_mutex = Eio.Mutex.create () in

      Eio.Fiber.all (List.init parallel_sims (fun _ ->
        fun () ->
          match select root with
          | Error msg ->
              Eio.traceln "[MCTS] select failed: %s" msg
          | Ok selected ->
          (* Protect expand with tree_mutex to prevent race on node.children *)
          let expand_result = Eio.Mutex.use_rw tree_mutex ~protect:true (fun () ->
            expand selected) in
          match expand_result with
          | Error msg ->
              Eio.traceln "[MCTS] expand failed: %s" msg
          | Ok expanded ->
          let score = simulate expanded in
          Eio.Mutex.use_rw results_mutex ~protect:true (fun () ->
            sim_results := (expanded, score) :: !sim_results;
            (* Track best result *)
            if score > !best_score then begin
              best_score := score;
              best_output := !(expanded.last_output)
            end
          )
      ));

      (* Backpropagate all results *)
      List.iter (fun (node, score) ->
        backpropagate node score
      ) !sim_results;

      (* Check early stopping *)
      match early_stop with
      | Some threshold when !best_score >= threshold ->
          ()  (* Early stop: found good enough solution *)
      | _ ->
          mcts_iteration (iteration + parallel_sims)
    end
  in

  mcts_iteration 0;

  (* Find best strategy based on final statistics *)
  let best_child =
    let sorted = List.sort (fun c1 c2 ->
      let avg1 = if c1.visits = 0 then 0.0 else c1.total_score /. float_of_int c1.visits in
      let avg2 = if c2.visits = 0 then 0.0 else c2.total_score /. float_of_int c2.visits in
      Float.compare avg2 avg1
    ) root.children in
    match sorted with best :: _ -> Some best | [] -> None
  in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  match best_child with
  | None ->
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error "MCTS: No strategies found"
  | Some best ->
      let result_json = Yojson.Safe.to_string (`Assoc [
        ("strategy_idx", `Int best.strategy_idx);
        ("visits", `Int best.visits);
        ("avg_score", `Float (best.total_score /. float_of_int (max 1 best.visits)));
        ("total_iterations", `Int root.visits);
        ("best_output", `String !best_output);
      ]) in
      store_node_output ctx parent result_json;
      record_complete ctx parent.id ~duration_ms ~success:true;
      Ok result_json

(** Execute cache node - check cache first, execute inner if miss *)
and execute_cache ctx ~sw ~clock ~exec_fn ~tool_exec (node : node)
    ~key_expr ~ttl_seconds (inner : node) : (string, string) result =
  record_start ctx node.id;
  let start = Time_compat.now () in

  (* Generate cache key by resolving the key expression *)
  let cache_key = resolve_single_input ctx key_expr in
  let full_key = Printf.sprintf "%s:%s" inner.id cache_key in

  (* Check cache *)
  let cached = match Hashtbl.find_opt ctx.cache full_key with
    | Some (result, timestamp) ->
        if ttl_seconds = 0 || Time_compat.now () -. timestamp < float_of_int ttl_seconds then
          Some result
        else begin
          (* Expired - remove from cache *)
          Hashtbl.remove ctx.cache full_key;
          None
        end
    | None -> None
  in

  let result = match cached with
    | Some cached_result ->
        (* Cache hit - return cached value *)
        Ok cached_result
    | None ->
        (* Cache miss - execute inner node *)
        let inner_result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in
        (match inner_result with
        | Ok output ->
            (* Store in cache *)
            Hashtbl.replace ctx.cache full_key (output, Time_compat.now ());
            Ok output
        | Error _ as e -> e)
  in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  let success = Result.is_ok result in
  record_complete ctx node.id ~duration_ms ~success;
  (match result with
  | Ok output -> store_node_output ctx node output
  | Error msg -> record_error ctx node.id msg);
  result

(** Execute batch node - process list items in batches *)
and execute_batch ctx ~sw ~clock ~exec_fn ~tool_exec (node : node)
    ~batch_size ~parallel ~collect_strategy (inner : node) : (string, string) result =
  record_start ctx node.id;
  let start = Time_compat.now () in

  (* Get input as JSON array *)
  let input_str = resolve_single_input ctx (Printf.sprintf "{{%s}}" node.id) in
  let items = try
    match Yojson.Safe.from_string input_str with
    | `List items -> Ok (List.map Yojson.Safe.to_string items)
    | `String s ->
        (* Try to parse as newline-separated items *)
        Ok (String.split_on_char '\n' s |> List.filter (fun s -> String.trim s <> ""))
    | _ -> Error "Batch input must be a JSON array or newline-separated text"
  with Yojson.Json_error _ ->
    (* Treat as newline-separated *)
    Ok (String.split_on_char '\n' input_str |> List.filter (fun s -> String.trim s <> ""))
  in

  match items with
  | Error msg ->
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx node.id ~duration_ms ~success:false;
      record_error ctx node.id msg;
      Error msg
  | Ok item_list ->
      (* Process items in batches - manual chunking *)
      let rec chunk_list n lst =
        if n <= 0 then [[]]
        else match lst with
        | [] -> []
        | _ ->
            let rec take n acc = function
              | [] -> (List.rev acc, [])
              | h :: t -> if n <= 0 then (List.rev acc, h :: t) else take (n - 1) (h :: acc) t
            in
            let (chunk, rest) = take n [] lst in
            chunk :: chunk_list n rest
      in
      let batches = chunk_list batch_size item_list in
      let all_results = ref [] in

      let process_batch batch_list =
        if parallel then begin
          (* Parallel execution within batch *)
          let mutex = Eio.Mutex.create () in
          Eio.Fiber.all (List.mapi (fun i item ->
            fun () ->
              (* Set item as input for inner node *)
              Hashtbl.replace ctx.outputs (Printf.sprintf "%s_item" node.id) item;
              let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in
              Eio.Mutex.use_rw mutex ~protect:true (fun () ->
                all_results := (i, result) :: !all_results
              )
          ) batch_list)
        end else begin
          (* Sequential execution within batch *)
          List.iteri (fun i item ->
            Hashtbl.replace ctx.outputs (Printf.sprintf "%s_item" node.id) item;
            let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in
            all_results := (i, result) :: !all_results
          ) batch_list
        end
      in

      List.iter process_batch batches;

      (* Sort results by index and collect *)
      let sorted_results = List.sort (fun (i1, _) (i2, _) -> compare i1 i2) !all_results in
      let outputs = List.filter_map (fun (_, r) ->
        match r with Ok o -> Some o | Error _ -> None
      ) sorted_results in

      let final_result = match collect_strategy with
        | `List -> Ok (Printf.sprintf "[%s]" (String.concat "," outputs))
        | `Concat -> Ok (String.concat "\n" outputs)
        | `First -> (match outputs with h :: _ -> Ok h | [] -> Error "No successful results")
        | `Last -> (match List.rev outputs with h :: _ -> Ok h | [] -> Error "No successful results")
      in

      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      let success = Result.is_ok final_result in
      record_complete ctx node.id ~duration_ms ~success;
      (match final_result with
      | Ok output -> store_node_output ctx node output
      | Error msg -> record_error ctx node.id msg);
      final_result

(** Execute spawn node - clean context execution for isolation

    When clean=true, creates a fresh context without prior outputs or conversation.
    This prevents "context contamination" where previous results pollute new analysis.

    Use cases:
    - Vision analysis: Ensure LLM sees only the image, not prior HTML/text
    - Multi-iteration loops: Each iteration starts fresh
    - Parallel independent tasks: No cross-contamination

    pass_vars allows selective passing of specific variables even when clean=true.
*)
and execute_spawn ctx ~sw ~clock ~exec_fn ~tool_exec (node : node)
    ~clean ~pass_vars ~inherit_cache (inner : node) : (string, string) result =
  record_start ctx node.id;
  let start = Time_compat.now () in

  match Chain_spawn_registry.try_start ~label:node.id with
  | Error msg ->
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx node.id ~duration_ms ~success:false;
      record_error ctx node.id msg;
      Error msg
  | Ok spawn_id ->
      (* Create spawned context based on clean flag *)
      let spawn_ctx = if clean then begin
        (* Clean context - fresh start *)
        let new_ctx = make_context
          ~start_time:ctx.start_time
          ~trace_enabled:ctx.trace_enabled
          ~timeout:ctx.timeout
          ~chain_id:ctx.chain_id
          ()
        in
        (* Optionally inherit cache *)
        if inherit_cache then
          Hashtbl.iter (fun k v -> Hashtbl.replace new_ctx.cache k v) ctx.cache;
        (* Pass only specified variables *)
        List.iter (fun var_name ->
          match Hashtbl.find_opt ctx.outputs var_name with
          | Some value -> Hashtbl.replace new_ctx.outputs var_name value
          | None -> ()  (* Variable not found - silently skip *)
        ) pass_vars;
        new_ctx
      end else begin
        (* Non-clean: inherit everything (basically just grouping) *)
        ctx
      end in

      (* Execute inner node in spawned context *)
      let result =
        try execute_node spawn_ctx ~sw ~clock ~exec_fn ~tool_exec inner
        with exn ->
          Error (Printf.sprintf "Spawn execution failed: %s" (Printexc.to_string exn))
      in

      (* Copy result back to parent context (for downstream nodes) *)
      (match result with
      | Ok output ->
          store_node_output ctx inner output;
          store_node_output ctx node output
      | Error msg ->
          Log.Chain.error "spawn failed for node %s: %s" node.id msg;
          store_node_output ctx node ("<spawn_error: " ^ msg ^ ">"));

      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      let success = Result.is_ok result in
      let error_msg =
        match result with
        | Ok _ -> None
        | Error msg -> Some msg
      in
      Chain_spawn_registry.finish ~id:spawn_id ~ok:success ~error:error_msg;
      record_complete ctx node.id ~duration_ms ~success;
      (match result with
      | Ok _ -> ()
      | Error msg -> record_error ctx node.id msg);
      result

(** Execute a dynamically generated chain (ChainExec node)

    Context Injection allows parent chain to pass data to generated chain:
    - pass_outputs: if true, all parent outputs are available as {{parent.node_id}}
    - context_inject: explicit mapping [(child_var, parent_source)] for {{var}} in child

    Depth tracking uses __chain_depth in outputs hashtable.
*)
and execute_chain_exec ctx ~sw ~clock ~exec_fn ~tool_exec (node : node)
    ~chain_source ~validate ~max_depth
    ~context_inject ~pass_outputs : (string, string) result =
  (* Check depth limit - stored in outputs table *)
  let current_depth = try
    int_of_string (Hashtbl.find ctx.outputs "__chain_depth")
  with Not_found | Failure _ -> 0
  in
  if current_depth >= max_depth then
    Error (Printf.sprintf "ChainExec depth limit exceeded: %d >= %d" current_depth max_depth)
  else begin
    (* Get chain JSON from source *)
    let chain_json_str = resolve_single_input ctx chain_source in
    if chain_json_str = "" then
      Error (Printf.sprintf "ChainExec: empty chain source from '%s'" chain_source)
    else
      (* Parse the chain JSON *)
      let chain_json = try
        Ok (Yojson.Safe.from_string chain_json_str)
      with exn ->
        Error (Printf.sprintf "ChainExec: invalid JSON from '%s': %s" chain_source (Printexc.to_string exn))
      in
      match chain_json with
      | Error msg -> Error msg
      | Ok json ->
          (* Parse chain *)
          (match Chain_parser.parse_chain json with
          | Error msg ->
              Error (Printf.sprintf "ChainExec: parse error: %s" msg)
          | Ok generated_chain ->
              (* Validate if required *)
              let validation = if validate then Chain_parser.validate_chain generated_chain else Ok () in
              (match validation with
              | Error msg -> Error (Printf.sprintf "ChainExec: validation error: %s" msg)
              | Ok () ->
                  (* Create new outputs table for child chain with incremented depth *)
                  let new_outputs = Hashtbl.create 16 in
                  Hashtbl.replace new_outputs "__chain_depth" (string_of_int (current_depth + 1));

                  (* Context Injection: pass_outputs - copy parent outputs with "parent." prefix *)
                  if pass_outputs then
                    Hashtbl.iter (fun k v ->
                      if not (String.equal k "__chain_depth") then
                        Hashtbl.replace new_outputs ("parent." ^ k) v
                    ) ctx.outputs;

                  (* Context Injection: explicit mappings - resolve and inject *)
                  List.iter (fun (child_var, parent_source) ->
                    let resolved = resolve_single_input ctx parent_source in
                    Hashtbl.replace new_outputs child_var resolved
                  ) context_inject;

                  let new_ctx = { ctx with outputs = new_outputs } in
                  (* Compile and execute the generated chain *)
                  (match Chain_compiler.compile generated_chain with
                  | Error msg -> Error (Printf.sprintf "ChainExec: compile error: %s" msg)
                  | Ok plan ->
                      (* Execute nodes in order using compiled plan *)
                      let rec exec_nodes = function
                        | [] ->
                            (* Get final output *)
                            (match Hashtbl.find_opt new_ctx.outputs generated_chain.Chain_types.output with
                            | Some output ->
                                store_node_output ctx node output;
                                Ok output
                            | None ->
                                Error (Printf.sprintf "ChainExec: output node '%s' not found" generated_chain.Chain_types.output))
                        | node_id :: rest ->
                            (match Chain_compiler.get_node generated_chain node_id with
                            | None -> Error (Printf.sprintf "ChainExec: node '%s' not found" node_id)
                            | Some child_node ->
                                (match execute_node new_ctx ~sw ~clock ~exec_fn ~tool_exec child_node with
                                | Ok _ -> exec_nodes rest
                                | Error msg -> Error msg))
                      in
                      exec_nodes plan.Chain_types.execution_order)))
  end

(** Execute nodes in sequence (internal helper, no output storage) *)
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

  (* Collect results from parallel execution *)
  let results = ref [] in
  let mutex = Eio.Mutex.create () in

  Eio.Fiber.all (List.map (fun node ->
    fun () ->
      let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node in
      Eio.Mutex.use_rw mutex ~protect:true (fun () ->
        results := (node.id, result) :: !results
      )
  ) nodes);

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  (* Check if all succeeded *)
  let outputs = List.filter_map (fun (id, r) ->
    match r with Ok o -> Some (id, o) | Error _ -> None
  ) !results in

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
    (* Multiple nodes - execute in parallel with Eio.Fiber.all *)
    let results = ref [] in
    let mutex = Eio.Mutex.create () in
    let has_error = ref None in

    Eio.Fiber.all (List.map (fun node_id ->
      fun () ->
        match Hashtbl.find_opt node_map node_id with
        | Some node ->
            let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node in
            Eio.Mutex.use_rw mutex ~protect:true (fun () ->
              results := (node_id, result) :: !results;
              match result with
              | Error msg when !has_error = None -> has_error := Some msg
              | _ -> ()
            )
        | None ->
            Eio.Mutex.use_rw mutex ~protect:true (fun () ->
              has_error := Some (Printf.sprintf "Node '%s' not found" node_id)
            )
    ) group);

    (* Return first error if any, otherwise success with last output *)
    match !has_error with
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

  (* Execute all nodes in parallel, handling ChainRef nodes specially *)
  let results = ref [] in
  let mutex = Eio.Mutex.create () in

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
      Eio.Mutex.use_rw mutex ~protect:true (fun () ->
        results := (node.id, result) :: !results
      )
  ) nodes);

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  (* Merge results based on strategy *)
  let outputs = List.filter_map (fun (id, r) ->
    match r with Ok o -> Some (id, o) | Error _ -> None
  ) !results in

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
and execute_goal_driven ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~goal_metric ~goal_operator ~goal_value ~action_node ~measure_func
    ~max_iterations ~strategy_hints ~conversational ~relay_models : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Initialize conversation context if conversational mode is enabled *)
  let prev_conversation = ctx.conversation in
  (if conversational then
     let models = if relay_models = [] then ["gemini"; "claude"; "codex"] else relay_models in
     ctx.conversation <- Some (make_conversation_ctx ~models ()));

  (* Get strategy hint based on current progress *)
  let get_strategy_hint current_value =
    (* strategy_hints format: [("below_50", "fast"), ("above_50", "accurate")] *)
    let pct = (current_value /. goal_value) *. 100.0 in
    List.find_opt (fun (condition, _) ->
      match String.split_on_char '_' condition with
      | ["below"; n] -> (try pct < float_of_string n with Failure _ -> false)
      | ["above"; n] -> (try pct >= float_of_string n with Failure _ -> false)
      | _ -> false
    ) strategy_hints
    |> Option.map snd
  in

  (* Measure metric from output using measure_func *)
  let measure output =
    match measure_func with
    | "parse_float" | "parse_json" ->
        (* Direct float parsing from output *)
        (try Some (float_of_string (String.trim output))
         with Failure _ ->
           (* Try JSON extraction *)
           try
             let json = Yojson.Safe.from_string output in
             let open Yojson.Safe.Util in
             Some (json |> member goal_metric |> to_float)
           with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
    | "exec_test" ->
        (* For test execution: extract coverage/pass rate from output *)
        (* Expected format: "coverage: 0.85" or JSON with metric field *)
        let regex = Str.regexp (goal_metric ^ "[: ]+\\([0-9.]+\\)") in
        (try
          let _ = Str.search_forward regex output 0 in
          Some (float_of_string (Str.matched_group 1 output))
        with Not_found ->
          try Some (float_of_string (String.trim output))
          with Failure _ -> None)
    | "call_api" ->
        (* For API calls: expect JSON response with metric *)
        (try
          let json = Yojson.Safe.from_string output in
          let open Yojson.Safe.Util in
          Some (json |> member goal_metric |> to_float)
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
    | "llm_judge" ->
        (* Use LLM to assess the metric *)
        let prompt = Printf.sprintf
          "Evaluate the following output for '%s' metric. Return ONLY a number between 0.0 and 1.0:\n\n%s"
          goal_metric output
        in
        let result = exec_fn ~model:"gemini" ?system:None ~prompt:prompt ?tools:None () in
        (match result with
         | Ok score_str ->
             (try Some (float_of_string (String.trim score_str))
              with Failure _ -> None)
         | Error _ -> None)
    | _ ->
        (* Default: try to extract any float *)
        (try Some (float_of_string (String.trim output))
         with Failure _ -> None)
  in

  let rec iterate iteration last_value =
    if iteration > max_iterations then begin
      ctx.iteration_ctx <- None;  (* Clear iteration context on completion *)
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error (Printf.sprintf "Goal not achieved after %d iterations (last value: %.2f, target: %.2f)"
               max_iterations last_value goal_value)
    end else begin
      (* Get current strategy hint *)
      let current_strategy = get_strategy_hint last_value in

      (* Calculate progress toward goal *)
      let progress = last_value /. (max 0.001 goal_value) in

      (* Set iteration context for variable substitution in prompts *)
      ctx.iteration_ctx <- Some {
        iteration;
        max_iterations;
        progress;
        last_value;
        goal_value;
        strategy = current_strategy;
      };

      (* Execute the action node *)
      match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec action_node with
      | Error msg ->
          let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
          record_complete ctx parent.id ~duration_ms ~success:false;
          Error (Printf.sprintf "Iteration %d failed: %s" iteration msg)
      | Ok output ->
          (* Update conversation context with this iteration's output when not a direct LLM node *)
          let should_record =
            match action_node.node_type with
            | Llm _ -> false
            | _ -> true
          in
          (match ctx.conversation, should_record with
           | Some conv, true ->
               add_message conv ~role:"assistant" ~content:output ~iteration ~model:conv.current_model;
               maybe_summarize_and_rotate ~exec_fn conv
           | _ -> ());

          (* Measure the metric *)
          (match measure output with
           | None ->
               (* Can't measure, keep trying with same last_value *)
               iterate (iteration + 1) last_value
           | Some v ->
               (* Check if goal is met *)
               let goal_met = match goal_operator with
                 | Gt -> v > goal_value
                 | Gte -> v >= goal_value
                 | Lt -> v < goal_value
                 | Lte -> v <= goal_value
                 | Eq -> abs_float (v -. goal_value) < 0.001
                 | Neq -> abs_float (v -. goal_value) >= 0.001
               in
               if goal_met then begin
                 ctx.iteration_ctx <- None;  (* Clear iteration context on completion *)
                 ctx.conversation <- None;   (* Clear conversation context on completion *)
                 let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
                 record_complete ctx parent.id ~duration_ms ~success:true;
                 store_node_output ctx parent output;
                 Ok output
               end else
                 iterate (iteration + 1) v)
    end
  in
  let result = iterate 1 0.0 in
  ctx.conversation <- prev_conversation;
  result

(** Execute evaluator node - score candidates and select based on strategy *)
and execute_evaluator ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~candidates ~scoring_func ~scoring_prompt ~select_strategy ~min_score : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Execute all candidates in parallel *)
  let results = ref [] in
  let mutex = Eio.Mutex.create () in

  Eio.Fiber.all (List.map (fun (candidate : node) ->
    fun () ->
      let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec candidate in
      Eio.Mutex.use_rw mutex ~protect:true (fun () ->
        results := (candidate.id, result) :: !results
      )
  ) candidates);

  (* Helper: LLM-based scoring using exec_fn *)
  let llm_score output =
    let prompt = match scoring_prompt with
      | Some p -> Printf.sprintf "%s\n\nCandidate output:\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" p output
      | None -> Printf.sprintf "Score this output from 0.0 to 1.0 for quality and correctness:\n\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" output
    in
    let result = exec_fn ~model:"gemini" ?system:None ~prompt:prompt ?tools:None () in
    match result with
    | Ok score_str ->
        (* Extract float from response *)
        let cleaned = String.trim score_str in
        (try
          let score = float_of_string cleaned in
          min 1.0 (max 0.0 score)  (* Clamp to [0, 1] *)
        with Failure _ ->
          (* Try to find a number in the response *)
          let regex = Str.regexp "[0-9]+\\.[0-9]+" in
          try
            let _ = Str.search_forward regex cleaned 0 in
            let found = Str.matched_string cleaned in
            min 1.0 (max 0.0 (float_of_string found))
          with Not_found | Failure _ -> 0.5)  (* Fallback *)
    | Error _ -> 0.5  (* Fallback on error *)
  in

  (* Score each successful result *)
  let scored = List.filter_map (fun (id, r) ->
    match r with
    | Error _ -> None
    | Ok output ->
        (* Score based on scoring_func *)
        let score = match scoring_func with
          | "regex_match" ->
              (* Simple: longer output = higher score (placeholder) *)
              float_of_int (String.length output) /. 1000.0
          | "json_schema" ->
              (* Check if valid JSON, bonus for more complete structure *)
              (try
                let json = Yojson.Safe.from_string output in
                let depth = ref 0 in
                let rec count_depth = function
                  | `Assoc fields ->
                      incr depth;
                      List.iter (fun (_, v) -> count_depth v) fields
                  | `List items ->
                      incr depth;
                      List.iter count_depth items
                  | _ -> ()
                in
                count_depth json;
                min 1.0 (0.5 +. (float_of_int !depth *. 0.1))
               with Yojson.Json_error _ -> 0.0)
          | "llm_judge" ->
              (* Use LLM to score the output *)
              llm_score output
          | "anti_fake" ->
              (* Anti-fake test detection: Hybrid (heuristic + LLM judge) *)
              let output_lower = String.lowercase_ascii output in
              (* Helper: check if haystack contains needle *)
              let contains_str needle haystack =
                let nl = String.length needle and hl = String.length haystack in
                if nl > hl then false
                else
                  let rec check i =
                    if i > hl - nl then false
                    else if String.sub haystack i nl = needle then true
                    else check (i + 1)
                  in check 0
              in
              (* Phase 1: Fast heuristic checks (0.0-0.5 range) *)
              let heuristic_score = ref 0.5 in
              (* Penalty patterns (fake tests) *)
              if contains_str "assert true" output_lower then
                heuristic_score := !heuristic_score -. 0.15;
              if contains_str "let _ =" output then
                heuristic_score := !heuristic_score -. 0.1;
              if contains_str "(* todo" output_lower then
                heuristic_score := !heuristic_score -. 0.05;
              (* Bonus patterns (real tests) *)
              let count_substr needle haystack =
                let nl = String.length needle and hl = String.length haystack in
                if nl > hl || nl = 0 then 0
                else
                  let rec aux i acc =
                    if i > hl - nl then acc
                    else if String.sub haystack i nl = needle then aux (i + 1) (acc + 1)
                    else aux (i + 1) acc
                  in aux 0 0
              in
              let real_asserts = count_substr "assert (" output in
              let alcotest_checks = count_substr "Alcotest.check" output in
              heuristic_score := !heuristic_score +. (float_of_int (real_asserts + alcotest_checks) *. 0.02);
              if contains_str "decode" output_lower && contains_str "encode" output_lower then
                heuristic_score := !heuristic_score +. 0.1;
              let h_score = max 0.0 (min 0.5 !heuristic_score) in

              (* Phase 2: LLM judge for semantic analysis (0.0-0.5 range) *)
              (* Few-shot examples for better accuracy *)
              let llm_prompt = Printf.sprintf {|Analyze this test code for fake test patterns.

## Few-Shot Examples:

FAKE (score: 0.2):
```
let test () = let _ = encode () in assert true
```
Reason: Ignores return value, empty assertion

FAKE (score: 0.3):
```
def test(): result = process(); assert True
```
Reason: Doesn't verify result

REAL (score: 0.85):
```
let test () = let encoded = encode x in let decoded = decode encoded in assert (decoded = x)
```
Reason: Roundtrip verification, real assertion

REAL (score: 0.8):
```
it('works', () => { expect(decode(encode(x))).toEqual(x); });
```
Reason: Roundtrip with proper expectation

## Score Scale:
- 0.0-0.3 = Fake test (assert true, ignores results)
- 0.4-0.6 = Partial test (some assertions, missing cases)
- 0.7-1.0 = Real test (meaningful assertions, tests behavior)

## Code to Analyze:
```
%s
```

Reply with ONLY a number between 0.0 and 1.0:|}
                (String.sub output 0 (min 1500 (String.length output)))
              in
              let llm_score =
                match exec_fn ~model:"gemini" ?system:None ~prompt:llm_prompt ?tools:None () with
                | Ok score_str ->
                    (try float_of_string (String.trim score_str) *. 0.5
                     with Failure _ -> 0.25)
                | Error _ -> 0.25  (* Default if LLM fails *)
              in
              (* Final: heuristic (50%) + LLM (50%) *)
              h_score +. llm_score
          | "custom" | _ ->
              (* For custom, try to parse score from output metadata *)
              (try
                let json = Yojson.Safe.from_string output in
                let open Yojson.Safe.Util in
                json |> member "score" |> to_float
               with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> 0.5)
        in
        Some (id, output, score)
  ) !results in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  if scored = [] then begin
    record_complete ctx parent.id ~duration_ms ~success:false;
    Error "No candidates succeeded"
  end else begin
    (* Filter by min_score if specified *)
    let filtered = match min_score with
      | None -> scored
      | Some threshold -> List.filter (fun (_, _, s) -> s >= threshold) scored
    in
    if filtered = [] then begin
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error (Printf.sprintf "No candidates met minimum score %.2f" (Option.value min_score ~default:0.0))
    end else begin
      (* Select based on strategy *)
      let selected = match select_strategy with
        | Best ->
            List.fold_left (fun best (id, out, sc) ->
              match best with
              | None -> Some (id, out, sc)
              | Some (_, _, best_sc) -> if sc > best_sc then Some (id, out, sc) else best
            ) None filtered
        | Worst ->
            List.fold_left (fun worst (id, out, sc) ->
              match worst with
              | None -> Some (id, out, sc)
              | Some (_, _, worst_sc) -> if sc < worst_sc then Some (id, out, sc) else worst
            ) None filtered
        | AboveThreshold t ->
            List.find_opt (fun (_, _, sc) -> sc >= t) filtered
        | WeightedRandom ->
            (* Simplified: just pick first (proper impl would use weighted random) *)
            (* Safe: filtered is non-empty due to guard at line 1397 *)
            match filtered with
            | first :: _ -> Some first
            | [] -> None  (* Unreachable but type-safe *)
      in
      match selected with
      | None ->
          record_complete ctx parent.id ~duration_ms ~success:false;
          Error "Selection strategy returned no result"
      | Some (_, output, _) ->
          record_complete ctx parent.id ~duration_ms ~success:true;
          store_node_output ctx parent output;
          Ok output
    end
  end

(** Execute FeedbackLoop node - iterative quality improvement with evaluator feedback *)
and execute_feedback_loop ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~generator ~(evaluator_config : Chain_types.evaluator_config)
    ~improver_prompt ~max_iterations ~score_threshold ~score_operator
    ~conversational ~relay_models : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let prev_conversation = ctx.conversation in
  (if conversational then
     let models = if relay_models = [] then ["gemini"; "claude"; "codex"] else relay_models in
     ctx.conversation <- Some (make_conversation_ctx ~models ()));

  (* Helper: Check if score passes threshold using operator *)
  let passes_threshold score =
    match score_operator with
    | Chain_types.Gt -> score > score_threshold
    | Chain_types.Gte -> score >= score_threshold
    | Chain_types.Lt -> score < score_threshold
    | Chain_types.Lte -> score <= score_threshold
    | Chain_types.Eq -> abs_float (score -. score_threshold) < 0.001
    | Chain_types.Neq -> abs_float (score -. score_threshold) >= 0.001
  in

  (* Helper: Format operator for error messages *)
  let op_str = match score_operator with
    | Chain_types.Gt -> ">" | Chain_types.Gte -> ">=" | Chain_types.Lt -> "<"
    | Chain_types.Lte -> "<=" | Chain_types.Eq -> "=" | Chain_types.Neq -> "!="
  in

  (* Helper: Score output using evaluator_config.scoring_func *)
  let score_output output =
    match evaluator_config.scoring_func with
    | "llm_judge" ->
        let prompt = match evaluator_config.scoring_prompt with
          | Some p -> Printf.sprintf "%s\n\nOutput to evaluate:\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" p output
          | None -> Printf.sprintf "Score this output from 0.0 to 1.0 for quality and correctness:\n\n%s\n\nRespond with ONLY a number between 0.0 and 1.0" output
        in
        (match exec_fn ~model:"gemini" ?system:None ~prompt ?tools:None () with
         | Ok score_str ->
             let cleaned = String.trim score_str in
             (try min 1.0 (max 0.0 (float_of_string cleaned))
              with Failure _ ->
                let regex = Str.regexp "[0-9]+\\.[0-9]+" in
                try
                  let _ = Str.search_forward regex cleaned 0 in
                  min 1.0 (max 0.0 (float_of_string (Str.matched_string cleaned)))
                with Not_found | Failure _ -> 0.5)
         | Error _ -> 0.5)
    | "regex_match" ->
        float_of_int (String.length output) /. 1000.0
    | "json_schema" ->
        (try
          let json = Yojson.Safe.from_string output in
          let depth = ref 0 in
          let rec count_depth = function
            | `Assoc fields -> incr depth; List.iter (fun (_, v) -> count_depth v) fields
            | `List items -> incr depth; List.iter count_depth items
            | _ -> ()
          in
          count_depth json;
          min 1.0 (0.5 +. (float_of_int !depth *. 0.1))
        with Yojson.Json_error _ -> 0.0)
    | _ ->
        (try
          let json = Yojson.Safe.from_string output in
          let open Yojson.Safe.Util in
          json |> member "score" |> to_float
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> 0.5)
  in

  (* Helper: Generate feedback for improvement *)
  let generate_feedback output score =
    let prompt = Printf.sprintf
      "The following output scored %.2f out of 1.0 for quality. Provide specific, actionable feedback on how to improve it:\n\n%s\n\nProvide 2-3 concrete suggestions for improvement:"
      score output
    in
    match exec_fn ~model:"gemini" ?system:None ~prompt ?tools:None () with
    | Ok feedback -> feedback
    | Error _ -> "Please improve the quality and accuracy of the output."
  in

  (* Helper: Substitute variables in improver_prompt *)
  let substitute_prompt template ~score ~feedback ~previous_output =
    template
    |> Str.global_replace (Str.regexp "{{score}}") (Printf.sprintf "%.2f" score)
    |> Str.global_replace (Str.regexp "{{feedback}}") feedback
    |> Str.global_replace (Str.regexp "{{previous_output}}") previous_output
  in

  (* Create a mutable copy of the generator for prompt updates *)
  let current_generator = ref generator in

  let rec iterate iteration =
    if iteration > max_iterations then begin
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx parent.id ~duration_ms ~success:false;
      Error (Printf.sprintf "FeedbackLoop: Max iterations (%d) reached without meeting threshold %s%.2f"
               max_iterations op_str score_threshold)
    end else begin
      (* Execute current generator *)
      match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec !current_generator with
      | Error msg ->
          let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
          record_complete ctx parent.id ~duration_ms ~success:false;
          Error (Printf.sprintf "FeedbackLoop iteration %d failed: %s" iteration msg)
      | Ok output ->
          (* Score the output *)
          let score = score_output output in

          (* Store feedback in outputs for reference *)
          Hashtbl.replace ctx.outputs (parent.id ^ ".feedback") "";

          if passes_threshold score then begin
            (* Success: score meets threshold *)
            let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
            record_complete ctx parent.id ~duration_ms ~success:true;
            store_node_output ctx parent output;
            Ok output
          end else begin
            (* Generate feedback and prepare for next iteration *)
            let feedback = generate_feedback output score in
            Hashtbl.replace ctx.outputs (parent.id ^ ".feedback") feedback;

            (* Update generator prompt with feedback *)
            let new_prompt = substitute_prompt improver_prompt ~score ~feedback ~previous_output:output in
            let updated_generator = match (!current_generator).node_type with
              | Llm llm_config ->
                  { !current_generator with
                    node_type = Llm { llm_config with prompt = new_prompt };
                    id = Printf.sprintf "%s_iter%d" generator.id iteration }
              | _ ->
                  (* For non-LLM generators, we can't easily update prompt *)
                  (* Just retry with same generator *)
                  !current_generator
            in
            current_generator := updated_generator;
            iterate (iteration + 1)
          end
    end
  in
  let result = iterate 1 in
  ctx.conversation <- prev_conversation;
  result

(* ════════════════════════════════════════════════════════════════════════════
   Resilience Nodes Implementation
   ════════════════════════════════════════════════════════════════════════════ *)

(** Calculate backoff delay in seconds *)
and calculate_backoff_delay (strategy : Chain_types.backoff_strategy) (attempt : int) : float =
  match strategy with
  | Chain_types.Constant secs -> secs
  | Chain_types.Exponential base -> base *. (2.0 ** float_of_int attempt)
  | Chain_types.Linear base -> base *. float_of_int (attempt + 1)
  | Chain_types.Jitter (min_sec, max_sec) ->
      min_sec +. Random.State.float executor_rng (max_sec -. min_sec)

(** Check if error matches retry patterns *)
and should_retry (retry_on : string list) (error_msg : string) : bool =
  match retry_on with
  | [] -> true
  | patterns ->
      List.exists (fun pattern ->
        try
          let regex = Str.regexp_case_fold pattern in
          Str.search_forward regex error_msg 0 >= 0
        with Failure _ | Not_found | Invalid_argument _ ->
          (* Regex failed or pattern not found: try prefix match *)
          String.sub error_msg 0 (min (String.length pattern) (String.length error_msg)) = pattern
      ) patterns

(** Execute retry node - retry on failure with backoff *)
and execute_retry ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~inner_node ~max_attempts ~backoff ~retry_on : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let rec attempt n last_error =
    if n > max_attempts then begin
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx parent.id ~duration_ms ~success:false;
      record_error ctx parent.id (Printf.sprintf "Max retries (%d) exceeded: %s" max_attempts last_error);
      Error (Printf.sprintf "Max retries (%d) exceeded: %s" max_attempts last_error)
    end else begin
      if n > 1 then Eio.Time.sleep clock (calculate_backoff_delay backoff (n - 2));
      match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner_node with
      | Ok output ->
          let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
          record_complete ctx parent.id ~duration_ms ~success:true;
          store_node_output ctx parent output;
          Ok output
      | Error msg ->
          if should_retry retry_on msg then attempt (n + 1) msg
          else begin
            let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
            record_complete ctx parent.id ~duration_ms ~success:false;
            record_error ctx parent.id msg;
            Error msg
          end
    end
  in
  attempt 1 ""

(** Execute fallback node - try primary, then fallbacks in order *)
and execute_fallback ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~primary ~fallbacks : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let rec try_nodes nodes errors =
    match nodes with
    | [] ->
        let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
        let msg = Printf.sprintf "All fallbacks failed: %s" (String.concat "; " (List.rev errors)) in
        record_complete ctx parent.id ~duration_ms ~success:false;
        record_error ctx parent.id msg;
        Error msg
    | node :: rest ->
        match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node with
        | Ok output ->
            let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
            record_complete ctx parent.id ~duration_ms ~success:true;
            store_node_output ctx parent output;
            Ok output
        | Error msg ->
            try_nodes rest ((node.id ^ ": " ^ msg) :: errors)
  in
  try_nodes (primary :: fallbacks) []

(** Execute race node - run all in parallel, first result wins (with timeout) *)
and execute_race ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~nodes ~timeout : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let winner = ref None in
  let winner_mutex = Eio.Mutex.create () in
  let winner_cond = Eio.Condition.create () in
  let all_errors = ref [] in
  let finished_count = ref 0 in
  let total_nodes = List.length nodes in

  (* Fork all race nodes in parallel *)
  List.iter (fun (node : node) ->
    Eio.Fiber.fork ~sw (fun () ->
      let already_won = Eio.Mutex.use_rw winner_mutex ~protect:true (fun () -> Option.is_some !winner) in
      if not already_won then begin
        match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node with
        | Ok output ->
            Eio.Mutex.use_rw winner_mutex ~protect:true (fun () ->
              if Option.is_none !winner then begin
                winner := Some (node.id, output);
                Eio.Condition.broadcast winner_cond
              end;
              incr finished_count)
        | Error msg ->
            Eio.Mutex.use_rw winner_mutex ~protect:true (fun () ->
              all_errors := (node.id ^ ": " ^ msg) :: !all_errors;
              incr finished_count;
              (* Wake up waiter if all have failed *)
              if !finished_count = total_nodes then
                Eio.Condition.broadcast winner_cond)
      end)
  ) nodes;

  (* Wait for winner with optional timeout *)
  let timeout_sec = match timeout with Some t -> t | None -> 300.0 in (* Default 5 min *)
  let wait_for_winner () =
    Eio.Mutex.use_rw winner_mutex ~protect:true (fun () ->
      while Option.is_none !winner && !finished_count < total_nodes do
        Eio.Condition.await winner_cond winner_mutex
      done;
      !winner)
  in

  let duration_ms = ref 0 in
  let result =
    try
      Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
        let r = wait_for_winner () in
        duration_ms := int_of_float ((Time_compat.now () -. start) *. 1000.0);
        match r with
        | Some (winner_id, output) ->
            record_complete ctx parent.id ~duration_ms:!duration_ms ~success:true;
            store_node_output ctx parent (Printf.sprintf "[winner: %s] %s" winner_id output);
            Ok output
        | None ->
            let msg = Printf.sprintf "All racers failed: %s" (String.concat "; " !all_errors) in
            record_complete ctx parent.id ~duration_ms:!duration_ms ~success:false;
            record_error ctx parent.id msg;
            Error msg)
    with Eio.Time.Timeout ->
      duration_ms := int_of_float ((Time_compat.now () -. start) *. 1000.0);
      let msg = Printf.sprintf "Race timeout after %.1fs" timeout_sec in
      record_complete ctx parent.id ~duration_ms:!duration_ms ~success:false;
      record_error ctx parent.id msg;
      Error msg
  in
  result

(** Execute StreamMerge node - process results progressively as they arrive *)
and execute_stream_merge ctx ~sw ~clock ~exec_fn ~tool_exec (parent : node)
    ~nodes ~reducer ~initial ~min_results ~timeout : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in

  (* Stream for progressive results: Some (id, output) or None for completion *)
  let stream = Eio.Stream.create (List.length nodes) in
  let completed_count = ref 0 in
  let total_count = List.length nodes in
  let count_mutex = Eio.Mutex.create () in

  (* Producer: Execute nodes in parallel, push results to stream as they complete *)
  Eio.Fiber.fork ~sw (fun () ->
    let is_cancelled exn =
      match exn with
      | Eio.Cancel.Cancelled _ -> true
      | _ -> false
    in
    let safe_stream_add value =
      try
        Eio.Stream.add stream value
      with exn ->
        if is_cancelled exn then raise exn;
        Log.Chain.error "stream add error: %s"
          (Printexc.to_string exn)
    in
    (try
       Eio.Fiber.all (List.map (fun (node : node) ->
         fun () ->
           try
             match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node with
             | Ok output ->
                 Eio.Mutex.use_rw count_mutex ~protect:true (fun () ->
                   incr completed_count;
                   Log.Chain.info "%s completed (%d/%d)"
                     node.id !completed_count total_count);
                 safe_stream_add (Some (node.id, Ok output))
             | Error msg ->
                 Eio.Mutex.use_rw count_mutex ~protect:true (fun () ->
                   incr completed_count);
                 safe_stream_add (Some (node.id, Error msg))
           with exn ->
             let err = Printexc.to_string exn in
             Eio.Mutex.use_rw count_mutex ~protect:true (fun () ->
               incr completed_count);
             safe_stream_add (Some (node.id, Error err))
       ) nodes)
     with exn ->
       if is_cancelled exn then raise exn;
       Log.Chain.info "producer crashed: %s"
         (Printexc.to_string exn));
    (* Signal completion after all producers done *)
    (try
       safe_stream_add None
     with exn ->
       if is_cancelled exn then raise exn;
       Log.Chain.error "completion signal error: %s"
         (Printexc.to_string exn))
  );

  (* Consumer: Process results progressively using reducer *)
  let acc = ref initial in
  let results_collected = ref 0 in
  let min_required = match min_results with Some n -> n | None -> total_count in
  let timeout_sec = match timeout with Some t -> t | None -> infinity in
  let deadline = start +. timeout_sec in

  let rec consume () =
    let now = Time_compat.now () in
    if now > deadline && !results_collected >= min_required then begin
      (* Timeout reached after min_results met *)
      Log.Chain.info "Timeout reached with %d results" !results_collected;
      Ok !acc
    end else begin
      match Eio.Stream.take stream with
      | None ->
          (* All producers finished *)
          Log.Chain.info "All %d nodes processed" !results_collected;
          Ok !acc
      | Some (id, Error msg) ->
          Log.Chain.error "%s failed: %s" id msg;
          consume ()  (* Skip failures, continue processing *)
      | Some (id, Ok output) ->
          incr results_collected;
          (* Apply reducer to accumulate result *)
          let new_acc = match reducer with
            | First -> if !acc = initial then output else !acc
            | Last -> output
            | Concat ->
                if !acc = initial then output
                else !acc ^ "\n" ^ output
            | WeightedAvg ->
                if !acc = initial then Printf.sprintf "[%s]: %s" id output
                else !acc ^ "\n---\n" ^ Printf.sprintf "[%s]: %s" id output
            | Custom func_name ->
                if !acc = initial then Printf.sprintf "[%s via %s]: %s" id func_name output
                else !acc ^ "\n---\n" ^ Printf.sprintf "[%s via %s]: %s" id func_name output
          in
          acc := new_acc;
          Log.Chain.info "Accumulated %s (%d collected)" id !results_collected;

          (* Check if we can return early (min_results met + optional timeout) *)
          if !results_collected >= min_required && timeout_sec < infinity then begin
            (* Wait briefly for more results or timeout *)
            let remaining = deadline -. Time_compat.now () in
            if remaining <= 0.0 then Ok !acc
            else consume ()  (* Keep consuming until timeout *)
          end else
            consume ()
    end
  in

  let result = consume () in
  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

  match result with
  | Ok output ->
      record_complete ctx parent.id ~duration_ms ~success:true;
      store_node_output ctx parent output;
      Ok output
  | Error msg ->
      record_complete ctx parent.id ~duration_ms ~success:false;
      record_error ctx parent.id msg;
      Error msg

(** {1 Execution Steps} *)

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
let execute ~sw ~clock ~timeout ~trace ~exec_fn ~tool_exec ?input ?checkpoint (plan : execution_plan) : chain_result =
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
                 | Error _ -> ());
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
                (* Execute remaining nodes in parallel *)
                let results = ref [] in
                let mutex = Eio.Mutex.create () in
                Eio.Fiber.all (List.map (fun (node : node) ->
                  fun () ->
                    let r = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node in
                    Eio.Mutex.use_rw mutex ~protect:true (fun () ->
                      results := (node.id, r) :: !results
                    )
                ) nodes_to_execute);
                (* Save checkpoint for all successfully completed parallel nodes *)
                List.iter (fun (node_id, r) ->
                  match r with
                  | Ok _ -> save_checkpoint ctx ~chain_id:plan.chain.Chain_types.id ~node_id
                  | Error _ -> ()
                ) !results;
                (* Check all succeeded *)
                let errors = List.filter_map (fun (id, r) ->
                  match r with Error e -> Some (id ^ ": " ^ e) | Ok _ -> None
                ) !results in
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
