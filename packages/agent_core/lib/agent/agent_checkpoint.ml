(** Checkpoint build/restore logic extracted from Agent.

    Takes explicit parameters to avoid circular dependency with Agent.t.
    Caller wraps results into Agent.t. *)

open Types

type resume_state =
  { state : agent_state
  ; context : Context.t
  }

(** Build restored state from a checkpoint.
    Returns state + context; the caller wraps these into Agent.t. *)
let build_resume ~(checkpoint : Checkpoint.t) ?(eio_context = false) ?config ?context () =
  let restored_config =
    match config with
    | Some caller_config -> caller_config
    | None ->
      { (default_config ~model:checkpoint.model) with
        name = checkpoint.agent_name
      ; system_prompt = checkpoint.system_prompt
      ; temperature = checkpoint.temperature
      ; top_p = checkpoint.top_p
      ; top_k = checkpoint.top_k
      ; min_p = checkpoint.min_p
      ; enable_thinking = checkpoint.enable_thinking
      ; preserve_thinking = checkpoint.preserve_thinking
      ; response_format = checkpoint.response_format
      ; thinking_budget = checkpoint.thinking_budget
      ; reasoning_effort = checkpoint.reasoning_effort
      ; tool_choice = checkpoint.tool_choice
      ; disable_parallel_tool_use = checkpoint.disable_parallel_tool_use
      ; cache_system_prompt = checkpoint.cache_system_prompt
      }
  in
  let state =
    { config = restored_config
    ; messages = checkpoint.messages
    ; turn_count = checkpoint.turn_count
    ; usage = checkpoint.usage
    }
  in
  let ctx =
    match context with
    | Some c -> c
    | None -> Context.copy ~eio:eio_context checkpoint.context
  in
  { state; context = ctx }
;;

(** Build a checkpoint from explicit state parameters.
    The caller extracts fields from Agent.t before calling this. *)
let build_checkpoint
      ?(session_id = "")
      ?working_context
      ~(state : agent_state)
      ~(tools : Tool_set.t)
      ~(context : Context.t)
      ~(mcp_clients : Mcp.managed list)
      ()
  =
  let tool_list = Tool_set.to_list tools in
  { Checkpoint.version = Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = state.config.name
  ; model = state.config.model
  ; system_prompt = state.config.system_prompt
  ; messages = state.messages
  ; usage = state.usage
  ; turn_count = state.turn_count
  ; created_at = Unix.gettimeofday ()
  ; tools = List.map (fun (t : Tool.t) -> t.schema) tool_list
  ; tool_choice = state.config.tool_choice
  ; disable_parallel_tool_use = state.config.disable_parallel_tool_use
  ; temperature = state.config.temperature
  ; top_p = state.config.top_p
  ; top_k = state.config.top_k
  ; min_p = state.config.min_p
  ; enable_thinking = state.config.enable_thinking
  ; preserve_thinking = state.config.preserve_thinking
  ; response_format = state.config.response_format
  ; thinking_budget = state.config.thinking_budget
  ; reasoning_effort = state.config.reasoning_effort
  ; cache_system_prompt = state.config.cache_system_prompt
  ; context = Context.copy context
  ; mcp_sessions = Mcp_session.capture_all mcp_clients
  ; working_context
  }
;;
