(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, appends the user message, and estimates input tokens.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; memory_context : string
  ; temporal_context : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; history_messages : Agent_sdk.Types.message list
  ; estimated_input_tokens : int
  ; ctx_work : Keeper_context_runtime.working_context
  }

type tool_schema_context_estimate =
  { tool_count : int
  ; tool_schema_tokens : int
  ; estimated_input_tokens_with_tools : int
  }

type context_window_observation =
  { observed_estimated_input_tokens : int
  ; observed_context_window : int
  ; observed_remaining_context_tokens : int
  ; observed_over_context_tokens : int
  ; observed_context_usage_ratio : float
  }

type extra_system_context_assembly =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  ; hook_extra_system_context_estimated_tokens : int
  ; post_hook_estimated_input_tokens : int
  ; post_hook_context_window_observation : context_window_observation
  }

let normalize_memory_fragment = Inference_utils.sanitize_text_utf8
let sanitize_user_message = Inference_utils.sanitize_text_utf8

let estimate_input_tokens
    ~(system_prompt : string)
    ~(dynamic_context : string)
    ~(memory_context : string)
    ~(temporal_context : string)
    ~(user_message : string)
    ~(history_messages : Agent_sdk.Types.message list) : int =
  List.fold_left
    (fun total text ->
      total + Keeper_context_core_accessors.estimate_char_tokens text)
    0
    [ system_prompt; dynamic_context; memory_context; temporal_context; user_message ]
  + List.fold_left
      (fun total message -> total + Keeper_context_core.msg_tokens message)
      0
      history_messages

let estimate_tool_schema_context
    ~(estimated_input_tokens : int)
    ~(tools : Agent_sdk.Tool.t list) : tool_schema_context_estimate =
  let tool_schema_tokens =
    tools
    |> List.map Agent_sdk.Tool.schema_to_json
    |> List.fold_left
         (fun acc json ->
            acc
            + Keeper_context_core_accessors.estimate_char_tokens
                (Yojson.Safe.to_string json))
         0
  in
  { tool_count = List.length tools
  ; tool_schema_tokens
  ; estimated_input_tokens_with_tools =
      estimated_input_tokens + tool_schema_tokens
  }

let prompt_block_accounted_in_preflight ~preflight_accounted_blocks block =
  List.exists (Prompt_block_id.equal block) preflight_accounted_blocks

let estimate_unaccounted_extra_system_context_tokens
      ~(preflight_accounted_blocks : Prompt_block_id.t list)
      blocks =
  List.fold_left
    (fun acc (block, text) ->
       if prompt_block_accounted_in_preflight ~preflight_accounted_blocks block
       then acc
       else acc + Keeper_context_core_accessors.estimate_char_tokens text)
    0
    blocks

let append_extra_system_context ctx text =
  match ctx with
  | None -> Some text
  | Some existing -> Some (existing ^ "\n\n" ^ text)

let estimate_extra_system_context_tokens = function
  | None -> 0
  | Some text -> Keeper_context_core_accessors.estimate_char_tokens text

let estimate_preflight_accounted_extra_system_context_tokens
      ~(preflight_accounted_blocks : Prompt_block_id.t list)
      blocks =
  List.fold_left
    (fun acc (block, text) ->
       if prompt_block_accounted_in_preflight ~preflight_accounted_blocks block
       then acc + Keeper_context_core_accessors.estimate_char_tokens text
       else acc)
    0
    blocks

let assembled_extra_system_context
      ~(existing_extra_system_context : string option)
      ~(included_blocks : (Prompt_block_id.t * string) list) =
  List.fold_left
    (fun ctx (_, text) -> append_extra_system_context ctx text)
    existing_extra_system_context
    included_blocks

let estimate_unaccounted_assembled_extra_context_tokens
      ~(existing_extra_system_context : string option)
      ~(preflight_accounted_blocks : Prompt_block_id.t list)
      ~(included_blocks : (Prompt_block_id.t * string) list) =
  let assembled_tokens =
    assembled_extra_system_context ~existing_extra_system_context ~included_blocks
    |> estimate_extra_system_context_tokens
  in
  let preflight_accounted_tokens =
    estimate_preflight_accounted_extra_system_context_tokens
      ~preflight_accounted_blocks
      included_blocks
  in
  max 0 (assembled_tokens - preflight_accounted_tokens)

let observe_context_window ~(estimated_input_tokens : int) ~(max_context : int)
  : context_window_observation =
  let observed_remaining_context_tokens =
    max 0 (max_context - estimated_input_tokens)
  in
  let observed_over_context_tokens =
    max 0 (estimated_input_tokens - max_context)
  in
  let observed_context_usage_ratio =
    if max_context > 0
    then Float.of_int estimated_input_tokens /. Float.of_int max_context
    else 0.0
  in
  { observed_estimated_input_tokens = estimated_input_tokens
  ; observed_context_window = max_context
  ; observed_remaining_context_tokens
  ; observed_over_context_tokens
  ; observed_context_usage_ratio
  }

let assemble_extra_system_context
      ~(estimated_input_tokens_with_tools : int)
      ~(max_context : int)
      ~(existing_extra_system_context : string option)
      ~(preflight_accounted_blocks : Prompt_block_id.t list)
      ~(blocks : (Prompt_block_id.t * string) list)
  : extra_system_context_assembly =
  let post_hook_estimate blocks =
    estimated_input_tokens_with_tools
    + estimate_unaccounted_assembled_extra_context_tokens
        ~existing_extra_system_context
        ~preflight_accounted_blocks
        ~included_blocks:blocks
  in
  let hook_extra_system_context_estimated_tokens =
    estimate_unaccounted_extra_system_context_tokens
      ~preflight_accounted_blocks
      blocks
  in
  let post_hook_estimated_input_tokens = post_hook_estimate blocks in
  { extra_system_context =
      assembled_extra_system_context
        ~existing_extra_system_context
        ~included_blocks:blocks
  ; blocks
  ; hook_extra_system_context_estimated_tokens
  ; post_hook_estimated_input_tokens
  ; post_hook_context_window_observation =
      observe_context_window
        ~estimated_input_tokens:post_hook_estimated_input_tokens
        ~max_context
  }

let build_turn_context
      ~(ctx : Keeper_run_context.run_context)
      ~(build_turn_prompt :
           base_system_prompt:string
        -> messages:Agent_sdk.Types.message list
        -> Keeper_agent_prompt_metrics.turn_prompt)
      ~(user_message : string)
      ~config:(_ : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(history_user_source : string)
      ~(is_retry : bool)
      ~(start_turn_count : int)
  : turn_prompt_context
  =
  let base_system_prompt = ctx.Keeper_run_context.base_system_prompt in
  let ctx_work = ctx.Keeper_run_context.ctx_work in
  let session = ctx.Keeper_run_context.session in
  let shared_context = ctx.Keeper_run_context.shared_context in
  (* 5. Build final turn system prompt via caller callback. *)
  let { Keeper_agent_prompt_metrics.system_prompt = turn_system_prompt
      ; dynamic_context
      } =
    build_turn_prompt
      ~base_system_prompt
      ~messages:(Keeper_context_runtime.messages_of_context ctx_work)
  in
  let memory_context = "" in
  let temporal_context =
    Masc_context_injector.render_temporal_summary shared_context
    |> Option.value ~default:""
  in
  let prompt_metrics =
    Keeper_agent_prompt_metrics.build_prompt_metrics
      ~system_prompt:turn_system_prompt
      ~dynamic_context
      ~user_message
  in
  (* [substrate:system_prompt] observability *)
  (let segment = prompt_metrics.Keeper_agent_prompt_metrics.system_prompt_segment in
   let hash16 =
     match segment.Keeper_agent_prompt_metrics.fingerprint with
     | Some hex when String.length hex >= 16 -> String.sub hex 0 16
     | Some hex -> hex
     | None -> "empty"
   in
   Log.Keeper.routine
     "[substrate:system_prompt] agent=%s turn=%d length=%d hash=%s"
     meta.agent_name (start_turn_count + 1) segment.Keeper_agent_prompt_metrics.bytes hash16);
  (* [substrate:task_assignment] observability *)
  (let user_seg = prompt_metrics.Keeper_agent_prompt_metrics.user_message_segment in
   let dyn_seg = prompt_metrics.Keeper_agent_prompt_metrics.dynamic_context_segment in
   let pick_hash16 (segment : Keeper_agent_prompt_metrics.prompt_segment_metrics) =
     match segment.Keeper_agent_prompt_metrics.fingerprint with
     | Some hex when String.length hex >= 16 -> String.sub hex 0 16
     | Some hex -> hex
     | None -> "empty"
   in
   Log.Keeper.routine
     "[substrate:task_assignment] agent=%s turn=%d user_length=%d \
      user_hash=%s dyn_length=%d dyn_hash=%s"
     meta.agent_name (start_turn_count + 1) user_seg.Keeper_agent_prompt_metrics.bytes
     (pick_hash16 user_seg) dyn_seg.Keeper_agent_prompt_metrics.bytes (pick_hash16 dyn_seg));
  (* 6. Append user message and persist. *)
  let user_msg = Agent_sdk.Types.user_msg user_message in
  let history_messages =
    Keeper_context_runtime.messages_of_context ctx_work
    |> Keeper_context_core.repair_broken_tool_call_pairs
  in
  let ctx_work =
    { ctx_work with
      checkpoint = { ctx_work.checkpoint with messages = history_messages }
    }
  in
  let estimated_input_tokens =
    estimate_input_tokens
      ~system_prompt:turn_system_prompt
      ~dynamic_context
      ~memory_context
      ~temporal_context
      ~user_message
      ~history_messages
  in
  let ctx_work = Keeper_context_runtime.append ctx_work user_msg in
  if not is_retry
  then
    Keeper_context_runtime.persist_message
      ~source:history_user_source session user_msg;
  { turn_system_prompt
  ; dynamic_context
  ; memory_context
  ; temporal_context
  ; prompt_metrics
  ; history_messages
  ; estimated_input_tokens
  ; ctx_work
  }
