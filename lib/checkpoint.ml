(** Agent state checkpoint — versioned JSON serialization.

    Captures the full conversation state (messages, usage, config) as a
    pure value for callers that want to persist and later restore agent
    state. This module only handles serialization; file I/O and resume
    orchestration are left to the caller. *)

open Types

type t = Checkpoint_types.t =
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

type message_splice = Checkpoint_types.message_splice =
  { start_index : int
  ; delete_count : int
  ; insert : message list
  }

type identity_patch = Checkpoint_types.identity_patch =
  { session_id : string
  ; agent_name : string
  ; model : model
  ; created_at : float
  }

type sampling_patch = Checkpoint_types.sampling_patch =
  { temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; thinking_budget : int option
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  }

type limits_patch = Checkpoint_types.limits_patch =
  { disable_parallel_tool_use : bool
  ; response_format : response_format
  ; cache_system_prompt : bool
  }

type delta_op = Checkpoint_types.delta_op =
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

type delta = Checkpoint_types.delta =
  { delta_version : int
  ; base_checkpoint_version : int
  ; base_checkpoint_hash : string
  ; result_checkpoint_hash : string
  ; created_at : float
  ; operations : delta_op list
  }

let checkpoint_version = Checkpoint_types.checkpoint_version
let usage_to_json = Checkpoint_codec.usage_to_json
let usage_of_json = Checkpoint_codec.usage_of_json
let to_json = Checkpoint_codec.to_json
let of_json = Checkpoint_codec.of_json
let to_string = Checkpoint_codec.to_string
let of_string = Checkpoint_codec.of_string
let delta_to_json = Checkpoint_codec.delta_to_json
let delta_of_json = Checkpoint_codec.delta_of_json
let compute_delta = Checkpoint_delta.compute_delta
let apply_delta = Checkpoint_delta.apply_delta
let message_count cp = List.length cp.messages
let token_usage cp = cp.usage
