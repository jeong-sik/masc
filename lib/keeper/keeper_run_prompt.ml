(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, and appends the user message.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; memory_context : string
  ; temporal_context : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; history_messages : Agent_sdk.Types.message list
  ; ctx_work : Keeper_context_runtime.working_context
  }

type extra_system_context_assembly =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  }

let normalize_memory_fragment = Inference_utils.sanitize_text_utf8
let sanitize_user_message = Inference_utils.sanitize_text_utf8

let append_extra_system_context ctx text =
  match ctx with
  | None -> Some text
  | Some existing -> Some (existing ^ "\n\n" ^ text)

let assembled_extra_system_context
      ~(existing_extra_system_context : string option)
      ~(included_blocks : (Prompt_block_id.t * string) list) =
  List.fold_left
    (fun ctx (_, text) -> append_extra_system_context ctx text)
    existing_extra_system_context
    included_blocks

let assemble_extra_system_context
      ~(existing_extra_system_context : string option)
      ~(blocks : (Prompt_block_id.t * string) list)
  : extra_system_context_assembly =
  { extra_system_context =
      assembled_extra_system_context
        ~existing_extra_system_context
        ~included_blocks:blocks
  ; blocks
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
  (* 6. Append user message and persist. A world-state prompt supersedes the
     previous one instead of accumulating (#25193): the block is a turn-scoped
     observation, and the jsonl replay path already drops this channel
     ([classify_history_entry] -> [Drop_line]), so keeping every copy in the
     live context was pure duplication — a live checkpoint measured 180
     near-identical copies (50.8% of its bytes). The injected message is
     stamped with typed metadata provenance, and prior stamped copies are
     removed by exact metadata equality before the new one is appended;
     message content is never inspected, so operator-authored text that
     merely looks like a world-state block is untouched (as are legacy
     pre-tag copies, which compaction owns). *)
  let is_world_state_prompt_turn =
    Keeper_types_support.is_prompt_history_source history_user_source
  in
  let user_msg =
    let plain = Agent_sdk.Types.user_msg user_message in
    if is_world_state_prompt_turn
    then
      Keeper_types_support.tag_message_history_source
        ~source:Keeper_types_support.world_state_prompt_history_source plain
    else plain
  in
  let history_messages =
    let all = Keeper_context_runtime.messages_of_context ctx_work in
    if is_world_state_prompt_turn
    then
      List.filter
        (fun message ->
          not (Keeper_types_support.message_is_world_state_prompt message))
        all
    else all
  in
  let ctx_work =
    { ctx_work with
      checkpoint =
        { ctx_work.checkpoint with
          Agent_sdk.Checkpoint.messages = history_messages
        }
    }
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
  ; ctx_work
  }
