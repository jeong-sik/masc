open Types

let checkpoint_version = 10

type t =
  { version : int
  ; session_id : string
  ; agent_name : string
  ; model : model
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
  ; thinking_budget : int option
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; cache_system_prompt : bool
  ; context : Context.t
  ; mcp_sessions : Mcp_session.info list
  ; working_context : Yojson.Safe.t option
  }

type message_splice =
  { start_index : int
  ; delete_count : int
  ; insert : message list
  }

type identity_patch =
  { session_id : string
  ; agent_name : string
  ; model : model
  ; created_at : float
  }

type sampling_patch =
  { temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; thinking_budget : int option
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  }

type limits_patch =
  { disable_parallel_tool_use : bool
  ; response_format : response_format
  ; cache_system_prompt : bool
  }

type delta_op =
  | Replace_identity of identity_patch
  | Replace_system_prompt of string option
  | Splice_messages of message_splice
  | Replace_usage of usage_stats
  | Replace_turn_count of int
  | Replace_tools of tool_schema list
  | Replace_tool_choice of tool_choice option
  | Replace_sampling of sampling_patch
  | Replace_limits of limits_patch
  | Patch_context of Context.diff
  | Replace_mcp_sessions of Mcp_session.info list
  | Replace_working_context of Yojson.Safe.t option

type delta =
  { delta_version : int
  ; base_checkpoint_version : int
  ; base_checkpoint_hash : string
  ; result_checkpoint_hash : string
  ; created_at : float
  ; operations : delta_op list
  }
