(** Chain Executor Leaf Nodes - Non-recursive node executors.

    Contains all leaf-level execution functions (MODEL, Tool, Adapter,
    MASC broadcast/listen/claim) that do not participate in the mutual
    recursion of {!Chain_executor_eio.execute_node}.

    Also includes MCTS tree types, UCB1, cascade helpers, and
    context summarization used by the recursive layer. *)

(** Re-export all helper types and functions *)
include Chain_executor_helpers

(** Execute a single MODEL node *)
let execute_model_node ctx ~clock ~(exec_fn : exec_fn) ~(node : node) (model : node_type) : (string, string) result =
  match model with
  | Model { model; system; prompt; timeout; tools; prompt_ref; prompt_vars = _; thinking } ->
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
        lower_model <> "stub"
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
          ~node_type:"model"
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
      record_start ctx node.id ~node_type:"model";
      let start = Time_compat.now () in

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
              ~node_type:"model"
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
                ~node_type:"model"
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
            record_complete ctx node.id ~duration_ms ~success:false ~node_type:"model";
            record_error ctx node.id ~node_type:"model"
              (Printf.sprintf "Empty response after %d retries" max_empty_retries);
            Error (Printf.sprintf "MODEL returned empty response after %d retries" max_empty_retries)
        | Ok output ->
            (* Valid non-empty response *)
            let prompt_tokens =
              Agent_sdk.Context_reducer.estimate_char_tokens prompt_to_use
              + (match final_system with Some s -> Agent_sdk.Context_reducer.estimate_char_tokens s | None -> 0) in
            let completion_tokens = Agent_sdk.Context_reducer.estimate_char_tokens output in
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
                ~node_type:"model"
                ~model:effective_model
                ~success:true
                ~extra:[
                  ("attempts_needed", string_of_int attempt);
                ]
                ();

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

            record_complete ctx node.id ~duration_ms ~success:true ~node_type:"model";
            store_node_output ctx node output;
            Ok output
        | Error msg ->
            (* Pass through MODEL errors as before *)
            Error msg
      in
      let final_result =
        let run () = try_with_empty_guard ~attempt:1 ~prompt_to_use:prompt_with_context in
        match timeout with
        | Some secs when secs > 0 ->
            let timeout_s = float_of_int secs in
            (match Eio.Time.with_timeout clock timeout_s (fun () -> Ok (run ())) with
             | Ok r -> r
             | Error `Timeout ->
                 let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
                 record_complete ctx node.id ~duration_ms ~success:false ~node_type:"model";
                 record_error ctx node.id ~node_type:"model"
                   (Printf.sprintf "MODEL node timed out after %ds" secs);
                 Error (Printf.sprintf "MODEL node timed out after %ds" secs))
        | _ -> run ()
      in
      (match final_result with
      | Ok output -> Ok output
      | Error msg ->
          (* Calculate duration for error case *)
          let error_duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in

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

          record_complete ctx node.id ~duration_ms:error_duration_ms ~success:false ~node_type:"model";
          record_error ctx node.id ~node_type:"model" msg;
          Error msg)
  | _ -> Error "execute_model_node called with non-MODEL node"

(** Get MASC agent name from env or default *)
let masc_agent_name () =
  Env_config.Chain.agent_name

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
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)
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

(** Execute MASC task-acquire node.
    Legacy [masc_claim] inputs are normalized to canonical tool calls:
    - specific task -> [masc_transition action=claim]
    - queue claim   -> [masc_claim_next] *)
let execute_masc_claim ctx ~tool_exec (node : node) ~task_id ~room : (string, string) result =
  record_start ctx node.id ~node_type:"masc_claim";
  let start = Time_compat.now () in
  let _ = room in
  (* Choose canonical tool based on whether task_id is provided. *)
  let tool_name, args = match task_id with
    | Some tid ->
        ("masc.masc_transition", `Assoc ([
          ("agent_name", `String (masc_agent_name ()));
          ("task_id", `String tid);
          ("action", `String "claim");
        ]))
    | None ->
        ("masc.masc_claim_next", `Assoc ([
          ("agent_name", `String (masc_agent_name ()));
        ]))
  in
  let result =
    try tool_exec ~name:tool_name ~args
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)
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
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)
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

(** Parse confidence level from MODEL output. Returns (confidence_level, cleaned_output) *)
let confidence_re = Re.Pcre.re ~flags:[`CASELESS] {|[Cc]onfidence:[ \t]*(High|Medium|Low)|} |> Re.compile
let confidence_line_re = Re.Pcre.re ~flags:[`CASELESS] {|[Cc]onfidence:[ \t]*(High|Medium|Low)\n?|} |> Re.compile

let parse_confidence_from_output (output : string) : (Chain_types.confidence_level * string) =
  match Re.exec_opt confidence_re output with
  | Some group ->
    let level_str = Re.Group.get group 1 in
    let level = Chain_types.confidence_of_string level_str in
    (* Remove the confidence line from output *)
    let cleaned = Re.replace_string confidence_line_re ~by:"" output in
    (level, String.trim cleaned)
  | None ->
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
