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

let checkpoint_version = Checkpoint_types.checkpoint_version
let usage_to_json = Checkpoint_codec.usage_to_json
let usage_of_json = Checkpoint_codec.usage_of_json
let to_json = Checkpoint_codec.to_json
let to_json_result = Checkpoint_codec.to_json_result
let drop_unencodable_json = Checkpoint_codec.drop_unencodable_json
let of_json = Checkpoint_codec.of_json
let to_string = Checkpoint_codec.to_string

let content_block_to_json_result ~scope block =
  let open Result.Syntax in
  let json = History.content_block_to_json block in
  let+ () = Checkpoint_codec.validate_checkpoint_json ~context:scope json in
  json

let content_block_of_json json =
  let open Result.Syntax in
  let* () = Checkpoint_codec.validate_checkpoint_json ~context:"Checkpoint content block" json in
  History.content_block_of_json json
  |> Result.map_error (fun error ->
    Error.Serialization
      (JsonParseError
         { detail = "Checkpoint content block: " ^ History.decode_error_to_string error }))

let wire_content_block_to_json_result ~scope block =
  let open Result.Syntax in
  let json = Checkpoint_codec.wire_content_block_to_json block in
  let+ () = Checkpoint_codec.validate_checkpoint_json ~context:scope json in
  json

let wire_content_block_of_json json =
  let open Result.Syntax in
  let* () = Checkpoint_codec.validate_checkpoint_json ~context:"Wire content block" json in
  Checkpoint_codec.wire_content_block_of_json_strict json

let message_to_json = Checkpoint_codec.message_to_json

let message_of_json json =
  let open Result.Syntax in
  let* () = Checkpoint_codec.validate_checkpoint_json ~context:"Checkpoint message" json in
  Checkpoint_codec.message_of_json json

type encoding_memo = Checkpoint_codec.encoding_memo

let create_encoding_memo = Checkpoint_codec.create_encoding_memo
let to_pieces_with_encoding_memo = Checkpoint_codec.to_pieces_with_encoding_memo
let of_string_with_encoding_memo = Checkpoint_codec.of_string_with_encoding_memo
let of_string = Checkpoint_codec.of_string
let message_count cp = List.length cp.messages
let token_usage cp = cp.usage
