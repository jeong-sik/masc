(** OpenAI Responses API request/response codec.

    This module is intentionally separate from {!Backend_openai_parse} and
    {!Backend_openai_request}: Responses uses ordered [output] / [input] items,
    while Chat Completions uses [choices[].message]. Mixing the two wire
    contracts is what breaks reasoning/tool round trips. *)
val project_history
  :  Provider_config.t
  -> Types.message list
  -> (Reasoning_history_projection.t, Reasoning_history_projection.error) result
(** The history this codec will actually serialize: reasoning blocks it cannot
    carry, and blocks the config's replay policy excludes, are already gone.

    Exported so a caller that must size a request before building it asks the
    same function the wire does, rather than keeping a second opinion about
    which blocks survive. Pure — the diagnostic [observe] belongs to whoever
    dispatches. *)


(** Message metadata key used to replay OpenAI Responses assistant
    ["phase"] values on stateless manual replay. Accepted values are
    ["commentary"] and ["final_answer"]. *)
val response_phase_metadata_key : string

type response_phase =
  | Commentary
  | Final_answer

val response_phase_metadata : response_phase -> string * Yojson.Safe.t
val responses_tool_json : Yojson.Safe.t -> Yojson.Safe.t

type request_artifact

val request_payload : request_artifact -> string
val request_output_token_receipt : request_artifact -> Types.output_token_receipt

val build_request_artifact
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> request_artifact

val build_request
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> string

(** Parse a Responses API JSON response into AGENT_CORE canonical content blocks.

    Reasoning summary items become {!Types.Thinking}; function call items become
    {!Types.ToolUse} with [ToolUse.id = call_id], so existing tool execution can
    correlate outputs via [function_call_output.call_id]. *)
val parse_response_result : string -> (Types.api_response, string) result
