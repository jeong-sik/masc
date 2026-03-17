(** Chain Orchestrator - Integration Layer (Eio)

    This module bridges the Neural Layer (Composer) with the Symbolic Layer (Conductor).
    It orchestrates the full lifecycle:

    1. Design: Composer analyzes tasks → generates Chain DSL
    2. Compile: Parser + Compiler → Execution Plan
    3. Execute: Conductor runs the plan with Eio fibers
    4. Verify: Composer evaluates completion
    5. Decide: Continue / Replan / Complete / Abort

    Architecture:
    ┌─────────────────────────────────────────────────────────────┐
    │                 ORCHESTRATOR (Integration Layer)            │
    │  ┌─────────────────────────────────────────────────────┐   │
    │  │                 orchestrate_session                  │   │
    │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐ │   │
    │  │  │ Design  │→ │ Compile │→ │ Execute │→ │ Verify │ │   │
    │  │  │(Composer)│  │(Compiler)│  │(Conduct)│  │(Compos)│ │   │
    │  │  └─────────┘  └─────────┘  └─────────┘  └────────┘ │   │
    │  │        ↑                                     │       │   │
    │  │        └──────── Replan Loop ←───────────────┘       │   │
    │  └─────────────────────────────────────────────────────┘   │
    └─────────────────────────────────────────────────────────────┘
*)

open Chain_types
open Chain_composer
open Chain_evaluator

(** LLM call function type - provided by caller *)
type llm_call = prompt:string -> string

(** Tool execution function type *)
type tool_exec = name:string -> args:Yojson.Safe.t -> Yojson.Safe.t

(** Orchestration result *)
type orchestration_result = {
  success: bool;
  final_metrics: chain_metrics option;
  verification: verification_result option;
  total_replans: int;
  summary: string;
  chain_id: string option;
  run_id: string option;
}
[@@deriving yojson]

(** Orchestration error *)
type orchestration_error =
  | DesignFailed of string
  | CompileFailed of string
  | ExecutionFailed of string
  | VerificationFailed of string
  | MaxReplansExceeded
  | Timeout
[@@deriving yojson]

(** Orchestration configuration *)
type orchestration_config = {
  max_replans: int;           (** Maximum re-planning attempts *)
  timeout_ms: int;            (** Overall timeout *)
  trace_enabled: bool;        (** Enable execution tracing *)
  verify_on_complete: bool;   (** Run LLM verification on completion *)
}

let default_config = {
  max_replans = 3;
  timeout_ms = 300_000;  (* 5 minutes *)
  trace_enabled = true;
  verify_on_complete = true;
}

(** Parse chain design from LLM response *)
let parse_chain_design (response: string) : (chain, string) result =
  (* Try to extract Mermaid graph or JSON from response anywhere in the text *)
  (* NOTE: Must use regular string for \n to be interpreted as newline *)
  let mermaid_pattern = Str.regexp "```mermaid\n\\(graph[^`]+\\)```" in
  let json_pattern = Str.regexp "```json\n\\([^`]+\\)```" in
  let extract_template_vars (s : string) =
    let re = Str.regexp "{{\\([^}]+\\)}}" in
    let rec loop pos acc =
      try
        let _ = Str.search_forward re s pos in
        let var = Str.matched_group 1 s |> String.trim in
        loop (Str.match_end ()) (var :: acc)
      with Not_found -> List.rev acc
    in
    loop 0 []
  in
  let rec collect_template_vars_json acc (json : Yojson.Safe.t) =
    match json with
    | `String s -> extract_template_vars s @ acc
    | `List items -> List.fold_left collect_template_vars_json acc items
    | `Assoc fields ->
        List.fold_left (fun acc' (_, value) -> collect_template_vars_json acc' value) acc fields
    | _ -> acc
  in
  let validate_designed_dataflow (chain : chain) =
    let starts_with ~prefix s =
      let prefix_len = String.length prefix in
      String.length s >= prefix_len && String.sub s 0 prefix_len = prefix
    in
    let missing_refs =
      List.filter_map
        (fun (node : node) ->
          let upstream_inputs =
            node.input_mapping
            |> List.filter_map (fun (key, source) ->
                if starts_with ~prefix:"_dep_" key then None else Some (key, source))
          in
          let referenced_vars =
            match node.node_type with
            | Llm { prompt; system; _ } ->
                let vars = extract_template_vars prompt in
                let vars =
                  match system with
                  | Some text -> vars @ extract_template_vars text
                  | None -> vars
                in
                List.sort_uniq String.compare vars
            | Tool { args; _ } ->
                collect_template_vars_json [] args |> List.sort_uniq String.compare
            | _ -> []
          in
          if upstream_inputs = [] || referenced_vars = [] && not (match node.node_type with Llm _ | Tool _ -> true | _ -> false) then
            None
          else
            let missing =
              upstream_inputs
              |> List.filter_map (fun (key, source) ->
                  if List.mem key referenced_vars || List.mem source referenced_vars then None
                  else Some key)
            in
            match missing with
            | [] -> None
            | _ ->
                Some
                  (Printf.sprintf "Node '%s' does not reference upstream inputs %s. Use template variables like {{%s}} in the prompt/args."
                     node.id
                     (String.concat ", " missing)
                     (List.hd missing))
        )
        chain.nodes
    in
    match missing_refs with
    | [] -> Ok ()
    | _ ->
        Error
          ("Designed chain has disconnected dataflow:\n- "
           ^ String.concat "\n- " missing_refs)
  in
  let validate_designed_chain (chain : chain) =
    match Chain_parser.validate_chain_strict chain with
    | Ok () ->
        (match validate_designed_dataflow chain with
        | Ok () -> Ok chain
        | Error e ->
            Error (Printf.sprintf "Designed chain failed semantic validation: %s" e))
    | Error e ->
        Error (Printf.sprintf "Designed chain failed strict validation: %s" e)
  in
  let try_parse_mermaid code =
    match Chain_mermaid_parser.parse_chain code with
    | Ok chain -> validate_designed_chain chain
    | Error e -> Error (Printf.sprintf "Mermaid parse error: %s" e)
  in
  let try_parse_json json_str =
    try
      match Yojson.Safe.from_string json_str |> Chain_parser.parse_chain with
      | Ok chain -> validate_designed_chain chain
      | Error e -> Error (Printf.sprintf "JSON parse error: %s" e)
    with Yojson.Json_error e -> Error (Printf.sprintf "Invalid JSON: %s" e)
  in

  try
    let _ = Str.search_forward mermaid_pattern response 0 in
    let mermaid_code = Str.matched_group 1 response in
    try_parse_mermaid mermaid_code
  with Not_found ->
    try
      let _ = Str.search_forward json_pattern response 0 in
      let json_str = Str.matched_group 1 response in
      try_parse_json json_str
    with Not_found ->
      let trimmed = String.trim response in
      match try_parse_json trimmed with
      | Ok chain -> Ok chain
      | Error _ ->
          let json_fallback =
            match (String.index_opt response '{', String.rindex_opt response '}') with
            | (Some l, Some r) when r > l ->
                Some (String.sub response l (r - l + 1))
            | _ -> None
          in
          (match json_fallback with
          | Some json_str -> (match try_parse_json json_str with
              | Ok chain -> Ok chain
              | Error _ ->
                  let graph_idx =
                    try Some (Str.search_forward (Str.regexp "graph") response 0)
                    with Not_found -> None
                  in
                  (match graph_idx with
                  | Some idx ->
                      let mermaid_code = String.sub response idx (String.length response - idx) in
                      try_parse_mermaid mermaid_code
                  | None ->
                      let snippet = String.sub response 0 (min 400 (String.length response)) in
                      Error (Printf.sprintf "No valid chain format found in LLM response. Snippet: %s" snippet)))
          | None ->
              let snippet = String.sub response 0 (min 400 (String.length response)) in
              Error (Printf.sprintf "No valid chain format found in LLM response. Snippet: %s" snippet))

(** Calculate chain parallelization efficiency:
    Ratio of parallel_groups to total_nodes (0.0 = fully sequential, 1.0 = maximally parallel) *)
let calc_parallelization_efficiency ~parallel_groups ~total_nodes =
  if total_nodes <= 1 then 1.0
  else float_of_int parallel_groups /. float_of_int (total_nodes - 1) |> min 1.0

(** Convert chain execution result to metrics *)
let result_to_metrics ~(chain_id: string) ~(goal: string) ~(started_at: float)
    ~(max_depth: int) ?(chain: chain option = None)
    (result: Chain_executor_eio.chain_result) : chain_metrics =
  let now = Time_compat.now () in
  let node_metrics =
    match (result.trace, chain) with
    | ([], Some c) ->
        let status = if result.success then Succeeded else Failed in
        List.map (fun (n: node) ->
          {
            node_id = n.id;
            node_type = Chain_types.node_type_name n.node_type;
            status;
            started_at = None;
            completed_at = None;
            duration_ms = 0;
            estimated_duration_ms = None;
            retry_count = 0;
            error_message = None;
            output_preview = None;
          }
        ) c.nodes
    | _ ->
        List.map (fun (entry: Chain_types.trace_entry) ->
          {
            node_id = entry.node_id;
            node_type = entry.node_type_name;
            status = (match entry.status with
              | `Success -> Succeeded
              | `Failure -> Failed
              | `Skipped -> Skipped);
            started_at = Some entry.start_time;
            completed_at = Some entry.end_time;
            duration_ms = int_of_float ((entry.end_time -. entry.start_time) *. 1000.0);
            estimated_duration_ms = None;
            retry_count = 0;  (* trace_entry doesn't track retries *)
            error_message = entry.error;
            output_preview = (match entry.output_preview with
              | Some o -> Some (String.sub o 0 (min 200 (String.length o)))
              | None -> None);
          }
        ) result.trace
  in

  let succeeded = List.length (List.filter (fun n -> n.status = Succeeded) node_metrics) in
  let failed = List.length (List.filter (fun n -> n.status = Failed) node_metrics) in
  let skipped = List.length (List.filter (fun n -> n.status = Skipped) node_metrics) in
  let total = List.length node_metrics in

  {
    chain_id;
    goal;
    started_at;
    completed_at = Some now;
    total_duration_ms = int_of_float ((now -. started_at) *. 1000.0);
    total_nodes = total;
    nodes_succeeded = succeeded;
    nodes_failed = failed;
    nodes_skipped = skipped;
    nodes_pending = 0;
    parallel_groups = (match chain with
      | Some c -> Chain_types.count_chain_parallel_groups c
      | None -> 0);
    max_depth;
    success_rate = if total > 0 then float_of_int succeeded /. float_of_int total else 0.0;
    parallelization_efficiency = (match chain with
      | Some c ->
          let groups = Chain_types.count_chain_parallel_groups c in
          calc_parallelization_efficiency ~parallel_groups:groups ~total_nodes:total
      | None -> 1.0);
    estimation_accuracy = 1.0;
    node_metrics;
    verification = None;
  }

(** Main orchestration function *)
let orchestrate
    ~sw
    ~clock
    ~(config: orchestration_config)
    ~(llm_call: llm_call)
    ~(tool_exec: tool_exec)
    ~(on_chain_designed : chain -> unit)
    ~(goal: string)
    ~(tasks: masc_task list)
    ~(initial_chain : chain option)
    : (orchestration_result, orchestration_error) result =

  let session_id = Printf.sprintf "orch-%d" (int_of_float (Time_compat.now () *. 1000.0)) in
  let state = ref (init_state ~session_id ~goal ~tasks ~max_replans:config.max_replans) in
  let started_at = Time_compat.now () in
  let execution_refs (chain: chain) (result: Chain_executor_eio.chain_result) =
    (Some chain.id, List.assoc_opt "run_id" result.metadata)
  in
  let notify_chain_designed (chain : chain) =
    try on_chain_designed chain
    with exn ->
      Chain_log.warn "orchestrator" "on_chain_designed failed for %s: %s"
        chain.id (Printexc.to_string exn)
  in

  (* Design phase: Get chain from LLM (or use provided initial chain once) *)
  let pending_chain = ref initial_chain in
  Chain_log.info "orchestrator" "Initialized pending_chain=%s"
    (match initial_chain with Some c -> Printf.sprintf "Some(id=%s)" c.id | None -> "None");
  let design_chain () =
    match !pending_chain with
    | Some chain ->
        Chain_log.info "orchestrator" "design_chain: Using pre-loaded chain (id=%s)" chain.id;
        pending_chain := None;
        Ok chain
    | None ->
        Chain_log.info "orchestrator" "design_chain: No pending_chain, calling LLM...";
        let context = get_design_context !state in
        let response = llm_call ~prompt:context in
        parse_chain_design response
  in

  (* Execute phase: Run chain with Conductor *)
  let execute_chain (chain: chain) : (Chain_executor_eio.chain_result, string) result =
    match Chain_compiler.compile chain with
    | Error e -> Error (Printf.sprintf "Compile error: %s" e)
    | Ok plan ->
      (* Create execution function for LLM nodes *)
      let timeout_sec = max 1 (config.timeout_ms / 1000) in
      let starts_with ~prefix s =
        let prefix_len = String.length prefix in
        String.length s >= prefix_len && String.sub s 0 prefix_len = prefix
      in
      let exec_via_tool ~name ~args =
        let json = tool_exec ~name ~args:(`Assoc args) in
        match json with
        | `Assoc fields -> (match List.assoc_opt "error" fields with
            | Some (`String msg) -> Error msg
            | _ -> Ok (Yojson.Safe.to_string json))
        | `String s -> Ok s
        | _ -> Ok (Yojson.Safe.to_string json)
      in
      (* exec_fn with automatic retry for recoverable errors (rate limits, timeouts) *)
      let exec_fn ~model ?system ~prompt ?tools ?thinking () =
        let base_args = [
          ("prompt", `String prompt);
          ("timeout", `Int timeout_sec);
        ] in
        let args = match system with
          | Some s -> ("system_prompt", `String s) :: base_args
          | None -> base_args
        in
        let args = match tools with
          | Some t -> ("tools", t) :: args
          | None -> args
        in
        let args = match thinking with
          | Some true -> ("thinking", `Bool true) :: args
          | _ -> args
        in
        let lowered = String.lowercase_ascii model in
        let is_gemini_model m =
          m = "gemini" ||
          m = "pro" || m = "flash" || m = "flash-lite" ||
          m = "3-pro" || m = "3-flash" ||
          starts_with ~prefix:"gemini-" m
        in
        (* Wrap LLM calls with retry for recoverable errors *)
        let exec_with_retry name args_with_model =
          let result = Chain_executor_retry.execute_llm_with_retry ~clock ~provider:name (fun () ->
            match exec_via_tool ~name ~args:args_with_model with
            | Ok v -> Ok v
            | Error msg -> Error (Chain_executor_retry.classify_error msg)
          ) in
          match result.Chain_retry.value with
          | Ok v -> Ok v
          | Error e -> Error (Chain_error.to_string e)
        in
        match lowered with
        | "stub" | "mock" -> Ok (Printf.sprintf "[stub]%s" prompt)
        | "codex" ->
            exec_with_retry "codex" (("model", `String Env_config_governance.OpenAI.default_model) :: args)
        | m when starts_with ~prefix:"gpt-" m ->
            exec_with_retry "codex" (("model", `String model) :: args)
        | "claude" | "claude-cli" | "opus" | "sonnet" | "haiku" ->
            exec_with_retry "claude" (("model", `String model) :: args)
        | "ollama" ->
            Error (Provider_adapter.bare_ollama_migration_message ())
        | "llama" ->
            exec_with_retry "llama" args
        | m when starts_with ~prefix:"llama:" m ->
            exec_with_retry "llama" (("model", `String model) :: args)
        | m when is_gemini_model m ->
            exec_with_retry "gemini" (("model", `String model) :: args)
        | _ ->
            let default_gemini = Env_config_governance.Gemini.default_model in
            let fallback_args =
              if default_gemini <> "" then ("model", `String default_gemini) :: args
              else args
            in
            exec_with_retry "gemini" fallback_args
      in

      (* Create tool execution wrapper *)
      let tool_exec_fn ~name ~args =
        let result = tool_exec ~name ~args in
        Ok (Yojson.Safe.to_string result)
      in

      Ok (Chain_executor_eio.execute
        ~sw ~clock
        ~timeout:(config.timeout_ms / 1000)
        ~trace:config.trace_enabled
        ~exec_fn
        ~tool_exec:tool_exec_fn
        ~input:goal
        plan)
  in

  (* Verify phase: Check completion with LLM *)
  let verify_completion (metrics: chain_metrics) =
    if not config.verify_on_complete then
      None
    else begin
      let context = get_verification_context !state metrics in
      let response = llm_call ~prompt:context in
      Some (parse_verification_response response)
    end
  in

  (* Main orchestration loop *)
  let rec loop () =
    (* Check timeout *)
    let elapsed = Time_compat.now () -. started_at in
    if elapsed *. 1000.0 > float_of_int config.timeout_ms then
      Error Timeout
    else begin
      (* Design *)
      match design_chain () with
      | Error e -> Error (DesignFailed e)
      | Ok chain ->
        state := set_chain !state chain;
        notify_chain_designed chain;

        (* Execute *)
        match execute_chain chain with
        | Error e -> Error (ExecutionFailed e)
        | Ok exec_result ->
          let max_depth = chain.config.max_depth in
          let metrics = result_to_metrics ~chain_id:session_id ~goal ~started_at ~max_depth ~chain:(Some chain) exec_result in

          if not exec_result.success && metrics.nodes_failed > 0 then begin
          (* Execution had failures - check if we should replan *)
          let verification = verify_completion metrics in
          let decision = decide_next_action ~state:!state ~metrics ~verification in

          match decision with
          | Replan reason when !state.replan_count < config.max_replans ->
            (* Only replan if within max_replans limit *)
            state := increment_replan !state;
            state := add_checkpoint !state
              ~trigger:OnFailure
              ~metrics
              ~decision:`Replan
              ~reason:(Printf.sprintf "Replanning due to: %s"
                (match reason with
                 | TaskFailed id -> Printf.sprintf "Task %s failed" id
                 | GoalNotAchieved -> "Goal not achieved"
                 | NewTaskAdded id -> Printf.sprintf "New task %s" id
                 | ContextChanged -> "Context changed"
                 | TimeoutApproaching -> "Timeout approaching"));
            loop ()  (* Retry with new design *)

          | Replan _ ->
            (* Hit max_replans limit, abort *)
            Error (ExecutionFailed (Printf.sprintf "Execution failed and max_replans (%d) exceeded" config.max_replans))

          | Abort reason ->
            Error (ExecutionFailed reason)

          | Complete final_metrics ->
            let chain_id, run_id = execution_refs chain exec_result in
            Ok {
              success = true;
              final_metrics = Some final_metrics;
              verification;
              total_replans = !state.replan_count;
              summary = generate_summary !state;
              chain_id;
              run_id;
            }

          | Continue ->
            (* Shouldn't happen after failure, but handle gracefully *)
            loop ()
        end
        else begin
          (* Success or no failures - verify completion *)
          let verification = verify_completion metrics in
          let decision = decide_next_action ~state:!state ~metrics ~verification in

          match decision with
          | Complete final_metrics ->
            state := finalize !state final_metrics;
            let chain_id, run_id = execution_refs chain exec_result in
            Ok {
              success = true;
              final_metrics = Some final_metrics;
              verification;
              total_replans = !state.replan_count;
              summary = generate_summary !state;
              chain_id;
              run_id;
            }

          | Replan reason when !state.replan_count < config.max_replans ->
            state := increment_replan !state;
            state := add_checkpoint !state
              ~trigger:OnChainComplete
              ~metrics
              ~decision:`Replan
              ~reason:(Printf.sprintf "Replanning: %s"
                (match reason with
                 | TaskFailed id -> Printf.sprintf "Task %s failed" id
                 | GoalNotAchieved -> "Goal not achieved despite execution success"
                 | _ -> "Unknown reason"));
            loop ()

          | Replan _ ->
            Error MaxReplansExceeded

          | Abort reason ->
            Error (ExecutionFailed reason)

          | Continue ->
            (* Partial completion - continue monitoring *)
            let chain_id, run_id = execution_refs chain exec_result in
            Ok {
              success = metrics.success_rate >= 0.8;
              final_metrics = Some metrics;
              verification;
              total_replans = !state.replan_count;
              summary = generate_summary !state;
              chain_id;
              run_id;
            }
        end
    end
  in

  loop ()

(** Simplified orchestration for quick tasks *)
let orchestrate_quick
    ~sw
    ~clock
    ~(llm_call: llm_call)
    ~(tool_exec: tool_exec)
    ~(on_chain_designed : chain -> unit)
    ~(goal: string)
    ~(tasks: masc_task list)
    : (orchestration_result, orchestration_error) result =
  orchestrate ~sw ~clock ~config:default_config ~llm_call ~tool_exec
    ~on_chain_designed ~goal ~tasks ~initial_chain:None

(** Create MASC tasks from simple string descriptions *)
let tasks_from_strings (descriptions: string list) : masc_task list =
  List.mapi (fun i desc ->
    {
      task_id = Printf.sprintf "task-%03d" (i + 1);
      title = desc;
      description = None;
      priority = i + 1;
      status = "todo";
      assignee = None;
      metadata = [];
    }
  ) descriptions

(** Pretty print orchestration result *)
let pp_result (result: orchestration_result) : string =
  Printf.sprintf {|
╔══════════════════════════════════════════════════════════════╗
║                 ORCHESTRATION RESULT                          ║
╠══════════════════════════════════════════════════════════════╣
║ Success: %s                                                   ║
║ Replans: %d                                                   ║
╠══════════════════════════════════════════════════════════════╣
%s
╠══════════════════════════════════════════════════════════════╣
%s
╚══════════════════════════════════════════════════════════════╝
|}
    (if result.success then "YES ✅" else "NO ❌")
    result.total_replans
    (match result.final_metrics with
     | Some m -> Printf.sprintf "║ Nodes: %d total | %d ✅ | %d ❌ | %d ⏭️"
         m.total_nodes m.nodes_succeeded m.nodes_failed m.nodes_skipped
     | None -> "║ (no metrics)")
    (match result.verification with
     | Some v -> Printf.sprintf "║ Verified: %s (%.0f%% confidence)\n║ %s"
         (if v.is_complete then "YES" else "NO")
         (v.confidence *. 100.0)
         v.reason
     | None -> "║ (not verified)")
