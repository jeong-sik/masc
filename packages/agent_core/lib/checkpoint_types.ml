open Types

let checkpoint_version = 17

type t =
  { version : int
  ; session_id : string
  ; agent_name : string
  ; model : model
  ; provider_binding : Llm_provider.Types.Reasoning_source.t option
  ; system_prompt : string option
  ; messages : message list
  ; usage : usage_stats
  ; turn_count : int
  ; created_at : float
  ; tools : tool_schema list
  ; tool_choice : tool_choice option
  ; disable_parallel_tool_use : bool
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; response_format : response_format
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; cache_system_prompt : bool
  ; context : Context.t
  ; mcp_sessions : Mcp_session.info list
  ; working_context : Yojson.Safe.t option
  ; pending_input : Agent_input_request.pending option
  }

