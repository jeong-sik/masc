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
  ; history_messages : Oas.Types.message list
  ; estimated_input_tokens : int
  ; ctx_work : Keeper_exec_context.working_context
  }

let build_turn_context
      ~(ctx : Keeper_run_context.run_context)
      ~(build_turn_prompt :
           base_system_prompt:string
        -> messages:Oas.Types.message list
        -> Keeper_agent_prompt_metrics.turn_prompt)
      ~(user_message : string)
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
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
      ~messages:(Keeper_exec_context.messages_of_context ctx_work)
  in
  let memory_episode_limit = 30 in
  let memory_procedure_limit = 10 in
  let memory_context =
    Memory_hooks.render_memory_context
      ~agent_name:meta.agent_name
      ~config
      ~episode_limit:memory_episode_limit
      ~procedure_limit:memory_procedure_limit
      ()
    |> Option.value ~default:""
  in
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
   Log.Keeper.info
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
   Log.Keeper.info
     "[substrate:task_assignment] agent=%s turn=%d user_length=%d \
      user_hash=%s dyn_length=%d dyn_hash=%s"
     meta.agent_name (start_turn_count + 1) user_seg.Keeper_agent_prompt_metrics.bytes
     (pick_hash16 user_seg) dyn_seg.Keeper_agent_prompt_metrics.bytes (pick_hash16 dyn_seg));
  (* 6. Append user message and persist. *)
  let user_msg = Oas.Types.user_msg user_message in
  let history_messages =
    Keeper_context_core.repair_broken_tool_call_pairs
      (Keeper_exec_context.messages_of_context ctx_work)
  in
  let estimated_input_tokens =
    let composition =
      Keeper_agent_prompt_metrics.build_ctx_composition_metrics
        ~system_prompt:turn_system_prompt
        ~dynamic_context
        ~memory_context
        ~temporal_context
        ~user_message
        ~history_messages
        ~actual_input_tokens:0
    in
    max prompt_metrics.Keeper_agent_prompt_metrics.estimated_total_tokens
        composition.Keeper_agent_prompt_metrics.display_total_tokens
  in
  let ctx_work = Keeper_exec_context.append ctx_work user_msg in
  if not is_retry
  then
    Keeper_exec_context.persist_message
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
