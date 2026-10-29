(** Checkpoint build/restore logic extracted from Agent.

    Takes explicit parameters to avoid circular dependency with Agent.t.
    Caller wraps results into Agent.t. *)

open Types

type resume_error =
  | Invalid_checkpoint_version of { expected : int; got : int }
  | Invalid_checkpoint_binding of string
  | Replay_rejected of Llm_provider.Reasoning_history_projection.error

let resume_error_to_string = function
  | Invalid_checkpoint_version {expected; got} ->
    Printf.sprintf "checkpoint version %d does not match current version %d" got expected
  | Invalid_checkpoint_binding detail -> "invalid checkpoint producer binding: " ^ detail
  | Replay_rejected error -> Llm_provider.Reasoning_history_projection.error_to_string error
;;

type binding_disposition =
  | Unconfigured_target
  | Unrecorded_producer
  | Identical_source
  | Declared_endpoint_rotation
  | Rebound_without_replay_loss
  | Replay_disabled_by_caller
  | Rebound_pending_dispatch of
      Llm_provider.Reasoning_history_projection.reasoning_replay_drop list

let binding_disposition_to_string = function
  | Unconfigured_target -> "unconfigured_target"
  | Unrecorded_producer -> "unrecorded_producer"
  | Identical_source -> "identical_source"
  | Declared_endpoint_rotation -> "declared_endpoint_rotation"
  | Rebound_without_replay_loss -> "rebound_without_replay_loss"
  | Replay_disabled_by_caller -> "replay_disabled_by_caller"
  | Rebound_pending_dispatch _ -> "rebound_pending_dispatch"
;;

type resume_state =
  { state : agent_state
  ; context : Context.t
  ; provider_config : Llm_provider.Provider_config.t option
  ; binding_disposition : binding_disposition
  }

(** Build restored state from a checkpoint.
    Returns state + context; the caller wraps these into Agent.t. *)
let build_resume ~(checkpoint : Checkpoint.t)
    ?(source_change_policy = Llm_provider.Reasoning_history_projection.Reject_incompatible)
    ?(eio_context = false) ?config ?provider_config ?context () =
  let open Result.Syntax in
  let* () =
    if checkpoint.version = Checkpoint.checkpoint_version then Ok ()
    else Error (Invalid_checkpoint_version
      {expected=Checkpoint.checkpoint_version; got=checkpoint.version}) in
  let* () = match checkpoint.provider_binding with
    | None -> Ok ()
    | Some source -> Reasoning_source.of_yojson (Reasoning_source.to_yojson source)
        |> Result.map (fun _ -> ())
        |> Result.map_error (fun detail -> Invalid_checkpoint_binding detail) in
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
      ; reasoning_effort = checkpoint.reasoning_effort
      ; tool_choice = checkpoint.tool_choice
      ; disable_parallel_tool_use = checkpoint.disable_parallel_tool_use
      ; cache_system_prompt = checkpoint.cache_system_prompt
      }
  in
  let* provider_config, binding_disposition =
    match provider_config with
    | None -> Ok (None, Unconfigured_target)
    | Some provider ->
      let provider = Agent_turn.provider_config_with_agent_config ~config:restored_config provider
        |> Llm_provider.Provider_config.freeze_for_request in
      (* The validator reads block kinds, roles and metadata, so restore
         checks the history as it is and reads no media. *)
      let* admission = Llm_provider.Reasoning_history_projection.validate_replay_continuity_for_provider_config
        ~source_change_policy ~boundary:Checkpoint_restore provider checkpoint.messages
        |> Result.map_error (fun error -> Replay_rejected error) in
      let capability = admission.capability in
      let disposition = match admission.disposition, checkpoint.provider_binding with
        | Llm_provider.Reasoning_history_projection.Caller_excluded_reasoning, _ -> Replay_disabled_by_caller
        | Source_change_admitted drops, _ -> Rebound_pending_dispatch drops
        | Preserve_reasoning, None -> Unrecorded_producer
        | Preserve_reasoning, Some stored ->
          if Reasoning_source.equal stored capability.target then Identical_source
          else if Reasoning_source.rotation_admits ~rotation_policy:capability.rotation
              ~stored ~target:capability.target then Declared_endpoint_rotation
          else Rebound_without_replay_loss
      in
      Ok (Some provider, disposition)
  in
  let state =
    { config = restored_config
    ; provider_binding = checkpoint.provider_binding
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
  Ok { state; context = ctx; provider_config; binding_disposition }
;;

(** Build a checkpoint from explicit state parameters.
    The caller extracts fields from Agent.t before calling this. *)
let build_checkpoint
      ?(session_id = "")
      ?working_context
      ~pending_input
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
  ; provider_binding = state.provider_binding
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
  ; reasoning_effort = state.config.reasoning_effort
  ; cache_system_prompt = state.config.cache_system_prompt
  ; context = Context.copy context
  ; mcp_sessions = Mcp_session.capture_all mcp_clients
  ; working_context
  ; pending_input
  }
;;
