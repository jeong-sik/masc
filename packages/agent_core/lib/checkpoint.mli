(** Agent state checkpoint -- versioned JSON serialization.

    Captures conversation state, usage, and the configuration fields represented
    by the checkpoint schema as a pure value for persist/restore. This module
    handles serialization only; file I/O is left to the caller.

    @stability Stable
    @since 0.93.1 *)

(** {1 Version} *)

(** Current checkpoint format version. *)
val checkpoint_version : int

(** {1 Checkpoint type} *)

type t =
  { version : int
  ; session_id : string
  ; agent_name : string
  ; model : Types.model
  ; system_prompt : string option
  ; messages : Types.message list
  ; usage : Types.usage_stats
  ; turn_count : int
  ; created_at : float
  ; tools : Types.tool_schema list
  ; tool_choice : Types.tool_choice option
  ; disable_parallel_tool_use : bool
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; response_format : Types.response_format
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
  ; insert : Types.message list
  }

type identity_patch =
  { session_id : string
  ; agent_name : string
  ; model : Types.model
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
  ; response_format : Types.response_format
  ; cache_system_prompt : bool
  }

type delta_op =
  | Replace_identity of identity_patch
  | Replace_system_prompt of string option
  | Splice_messages of message_splice
  | Replace_usage of Types.usage_stats
  | Replace_turn_count of int
  | Replace_tools of Types.tool_schema list
  | Replace_tool_choice of Types.tool_choice option
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

(** {1 Serialization} *)

(** Serialize an exact current checkpoint to JSON. Raises [Invalid_argument]
    when a manually constructed value violates the v10 contract. *)
val to_json : t -> Yojson.Safe.t

(** Deserialize only the exact current v10 checkpoint schema. Every other
    version is rejected. *)
val of_json : Yojson.Safe.t -> (t, Error.sdk_error) result

(** Serialize checkpoint to a JSON string. *)
val to_string : t -> string

(** Deserialize checkpoint from a JSON string under the same current-only
    contract as {!of_json}. *)
val of_string : string -> (t, Error.sdk_error) result

(** Serialize a checkpoint delta sidecar to JSON. *)
val delta_to_json : delta -> Yojson.Safe.t

(** Deserialize a checkpoint delta sidecar from JSON. *)
val delta_of_json : Yojson.Safe.t -> (delta, Error.sdk_error) result

(** Compute a delta from a base checkpoint to a target checkpoint. *)
val compute_delta : t -> t -> delta

(** Apply a delta to a base checkpoint. Both the base and resulting checkpoint
    must satisfy the exact current v10 contract. *)
val apply_delta : t -> delta -> (t, Error.sdk_error) result

(** {1 Queries} *)

(** Number of messages in the checkpoint. *)
val message_count : t -> int

(** Usage stats from the checkpoint. *)
val token_usage : t -> Types.usage_stats

(** {1 Usage stats JSON helpers} *)

(** Serialize usage_stats to JSON. Reusable by downstream modules
    (e.g., checkpoint telemetry). *)
val usage_to_json : Types.usage_stats -> Yojson.Safe.t

(** Deserialize exact current usage stats from JSON. Legacy fields are
    rejected explicitly. *)
val usage_of_json : Yojson.Safe.t -> (Types.usage_stats, Error.sdk_error) result
