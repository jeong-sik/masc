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
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  ; cache_system_prompt : bool
  ; context : Context.t
  ; mcp_sessions : Mcp_session.info list
  ; working_context : Yojson.Safe.t option
  ; pending_input : Agent_input_request.pending option
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
  | Replace_pending_input of Agent_input_request.pending option

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
    when a manually constructed value violates the v12 contract. *)
val to_json : t -> Yojson.Safe.t

(** Serialize an exact current checkpoint to JSON without raising when a
    manually constructed value violates the v12 contract. *)
val to_json_result : t -> (Yojson.Safe.t, Error.t) result

(** [drop_unencodable_json cp] is the recovery copy for a checkpoint whose
    encoding is refused: every json payload that cannot be canonically
    encoded is removed (a required payload field becomes an empty object),
    the text around it stays. Returns [None] when the checkpoint already
    encodes or when nothing droppable explains the refusal. The codec still
    rejects the original — see {!to_json_result}. Pending request ownership,
    including its schema, is preserved exactly rather than discarded. *)
val drop_unencodable_json : t -> t option

(** Deserialize only the exact current v12 checkpoint schema. Every other
    version is rejected. *)
val of_json : Yojson.Safe.t -> (t, Error.t) result

(** Serialize checkpoint to a JSON string. *)
val to_string : t -> string

val content_block_to_json_result :
  scope:string -> Types.content_block -> (Yojson.Safe.t, Error.t) result
(** Encode one block under the current checkpoint content contract, including
    failure provenance and nested media. [scope] names the diagnostic context.
    The checkpoint wire does not retain [ToolResult.json]; callers needing that
    optional parsed value must retain it separately. The unretained value is
    not inspected, so a duplicate key or a non-finite number in it does not
    refuse the encoding. *)

val content_block_of_json : Yojson.Safe.t -> (Types.content_block, Error.t) result
(** Decode one canonical checkpoint block. Duplicate/invalid JSON values,
    unknown fields, unsupported variants and malformed provenance are errors. *)

(** The JSON one message is written as inside a checkpoint's [messages]: the
    same encoder {!to_json} maps over them, for a caller that needs one
    message's durable bytes (a digest of it, say) without a checkpoint
    around it. Unlike {!to_json_result} it does not validate [json]
    payloads. *)
val message_to_json : Types.message -> Yojson.Safe.t

val message_of_json : Yojson.Safe.t -> (Types.message, Error.t) result
(** Decode one canonical checkpoint message under the current message contract.
    Malformed JSON values return serialization errors. *)

(** For each message record of one checkpoint lineage that a save wrote or a
    read decoded: the validated bytes it is written as, and the message
    {!of_string} gives for those bytes. One memo serves one sequence of saves;
    it is not safe to use from two saves at once. *)
type encoding_memo

val create_encoding_memo : unit -> encoding_memo

(** [to_pieces_with_encoding_memo memo cp] returns a checkpoint document for
    [cp] split into consecutive pieces, and what {!of_string} gives for those
    bytes. It raises [Invalid_argument] where {!to_json} does.

    A message the memo holds is written as the bytes held for it, with no
    encode, validation or decode. That is a record the previous successful call
    wrote, the decode that call returned for it, or a record
    {!of_string_with_encoding_memo} read. Every other message is encoded,
    validated against the v12 contract, and decoded once from the bytes written
    for it. After a success, [memo] holds the messages of [cp] and their
    decodes.

    The document is [to_string cp] when each held message encodes to the bytes
    held for it, that is, when encoding a decoded message gives back the bytes
    it was decoded from. Either way {!of_string} reads it as the returned
    checkpoint.

    The returned checkpoint is [None] when the call fell back to encoding the
    whole document. It can differ from [cp], as a load does: the wire does not
    carry [ToolResult.json]. Its [context] is decoded from the written bytes,
    so it is a table no one else holds.

    The caller appends the pieces in order. The live canonical checkpoints
    measured 2026-09-16 were 111MB and 107MB, so joining the pieces into one
    string would allocate that whole document again on every save. *)
val to_pieces_with_encoding_memo : encoding_memo -> t -> string list * t option

(** {!of_string} together with a memo that holds each decoded message whose
    encoding, with the checks a save runs, is the document's own JSON for it.
    The next {!to_pieces_with_encoding_memo} call writes those messages without
    encoding or decoding them again. A message the encoder writes differently
    -- a document from an older build or another writer -- or one the checks
    refuse is left out, so that call encodes it as it would with an empty
    memo. *)
val of_string_with_encoding_memo : string -> (t * encoding_memo, Error.t) result

(** Deserialize checkpoint from a JSON string under the same current-only
    contract as {!of_json}. *)
val of_string : string -> (t, Error.t) result

(** Serialize a checkpoint delta sidecar to JSON. *)
val delta_to_json : delta -> Yojson.Safe.t

(** Deserialize a checkpoint delta sidecar from JSON. *)
val delta_of_json : Yojson.Safe.t -> (delta, Error.t) result

(** Compute a delta from a base checkpoint to a target checkpoint. *)
val compute_delta : t -> t -> delta

(** Apply a delta to a base checkpoint. Both the base and resulting checkpoint
    must satisfy the exact current v12 contract. *)
val apply_delta : t -> delta -> (t, Error.t) result

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
val usage_of_json : Yojson.Safe.t -> (Types.usage_stats, Error.t) result
