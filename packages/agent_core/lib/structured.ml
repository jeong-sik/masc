(** Structured output helpers.

    Direct extraction uses provider-native JSON schema output via
    {!Llm_provider.Complete}. Unsupported providers fail fast instead of
    silently falling back to prompt-only JSON mode. *)

open Result_syntax
open Types

type 'a schema =
  { params : tool_param list
  ; parse : Yojson.Safe.t -> ('a, string) result
  }

let schema_to_json_schema (s : _ schema) : Yojson.Safe.t =
  Types.params_to_input_schema s.params
;;

let text_block : Llm_provider.Types.content_block -> string option = function
  | Text s -> Some s
  | Thinking _
  | ReasoningDetails _
  | RedactedThinking _
  | Image _
  | Document _
  | Audio _
  | ToolUse _
  | ToolResult _ -> None
;;

let parse_json_string text =
  try Ok (Yojson.Safe.from_string text) with
  | Yojson.Json_error detail -> Error detail
;;

let parse_schema_text_json ~raw schema json =
  try
    schema.parse json
    |> Result.map_error (fun detail ->
      Error.structured_output_parse_error ~reason:Error.Schema_rejected ~detail ~raw)
  with
  | Yojson.Json_error detail ->
    Error (Error.structured_output_parse_error ~reason:Error.Schema_rejected ~detail ~raw)
  | Yojson.Safe.Util.Type_error (detail, _) ->
    Error (Error.structured_output_parse_error ~reason:Error.Schema_type_mismatch ~detail ~raw)
;;

type response_json_shape =
  | Any_json
  | Object_json

type 'a response_outcome =
  | Ready of 'a
  | Awaiting_tool_results
  | Refused of Error.structured_refusal
  | Truncated of Error.structured_truncation
  | Interrupted of Error.structured_interruption
  | Invalid of Error.t

let parse_response_json ?(shape = Any_json) ~raw ()
  : (Yojson.Safe.t, Error.t) result
  =
  let text = String.trim raw in
  if text = ""
  then
    Error
      (Error.structured_output_parse_error
         ~reason:Error.Empty_response
         ~detail:"structured output response did not contain text JSON"
         ~raw)
  else
    let* json =
      parse_json_string text
      |> Result.map_error (fun detail ->
        Error.structured_output_parse_error ~reason:Error.Invalid_json ~detail ~raw)
    in
    match shape, json with
    | Any_json, _ -> Ok json
    | Object_json, `Assoc _ -> Ok json
    | Object_json, _ ->
      Error
        (Error.structured_output_parse_error
           ~reason:Error.Expected_object
           ~detail:"structured output response JSON was not an object"
           ~raw)
;;

let response_has_tool_calls (response : api_response) =
  List.exists
    (fun (block : Llm_provider.Types.content_block) ->
      match block with
      | ToolUse _ -> true
      | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
      | Image _ | Document _ | Audio _ | ToolResult _ -> false)
    response.content
;;

let inspect_terminal_json ?shape (response : api_response) =
  let raw = Types.visible_text_of_response response in
  match List.filter_map text_block response.content with
  | [] | [ _ ] ->
    (match parse_response_json ?shape ~raw () with
     | Ok json -> Ready (json, raw)
     | Error error -> Invalid error)
  | _ :: _ :: _ ->
    Invalid
      (Error.structured_output_parse_error
         ~reason:Error.Multiple_text_blocks
         ~detail:"structured output requires exactly one text block"
         ~raw)
;;

let inspect_response_json_with_raw ?shape (response : api_response) =
  match response.stop_reason with
  | Refusal -> Refused Error.Policy_refusal
  | ContentFilter -> Refused Error.Content_filtered
  | MaxTokens -> Truncated Error.Token_limit
  | RepetitionTruncation -> Truncated Error.Repetition_limit
  | ContextWindowExceeded -> Truncated Error.Context_limit
  | PauseTurn -> Interrupted Error.Paused_turn
  | Compaction -> Interrupted Error.Compacted_turn
  | UnmatchedToolCalls -> Interrupted Error.Missing_tool_calls
  | Unknown _ -> Interrupted Error.Unknown_stop
  | StopToolUse ->
    if response_has_tool_calls response
    then Awaiting_tool_results
    else Interrupted Error.Missing_tool_calls
  | EndTurn | StopSequence ->
    if response_has_tool_calls response
    then Awaiting_tool_results
    else inspect_terminal_json ?shape response
;;

let map_response_outcome f = function
  | Ready value -> Ready (f value)
  | Awaiting_tool_results -> Awaiting_tool_results
  | Refused reason -> Refused reason
  | Truncated reason -> Truncated reason
  | Interrupted reason -> Interrupted reason
  | Invalid error -> Invalid error
;;

let inspect_response_json ?shape response =
  inspect_response_json_with_raw ?shape response |> map_response_outcome fst
;;

let result_of_response_outcome = function
  | Ready value -> Ok value
  | Invalid error -> Error error
  | Awaiting_tool_results ->
    Error (Error.Serialization (StructuredOutputStateError Awaiting_tool_results))
  | Refused reason ->
    Error (Error.Serialization (StructuredOutputStateError (Refused_response reason)))
  | Truncated reason ->
    Error (Error.Serialization (StructuredOutputStateError (Truncated_response reason)))
  | Interrupted reason ->
    Error (Error.Serialization (StructuredOutputStateError (Interrupted_response reason)))
;;

(** Extract structured output from the response text JSON. *)
let extract_response ~(schema : _ schema) (response : api_response)
  : ('a, Error.t) result
  =
  let* json, raw =
    inspect_response_json_with_raw response |> result_of_response_outcome
  in
  parse_schema_text_json ~raw schema json
;;

(* [provider] is required here on purpose: the optional label on the shared
   mapper is exactly how the pipeline sites almost shipped without one
   (#28886 review) — sibling callers must not be able to forget it. *)
let core_error_of_http_error ~provider =
  Http_error_agent_core.of_http_error
    ~accept_rejected:(Config_invalid_config { field = "response_format" })
    ~provider
;;

let provider_config_for_schema ~provider_config ~config ~(schema : _ schema) =
  let provider_cfg =
    Agent_turn.provider_config_with_agent_config ~config provider_config
  in
  let response_format = Types.JsonSchema (Types.Raw_schema (schema_to_json_schema schema)) in
  Ok
    { provider_cfg with Llm_provider.Provider_config.tool_choice = None; response_format }
;;

(** Extract structured output from a prompt using provider-native JSON
    schema output when available. Unsupported providers fail fast. *)
let extract ~sw ~net ~provider_config ~config ~(schema : 'a schema) prompt
  : ('a, Error.t) result
  =
  let messages : Llm_provider.Types.message list =
    [ { origin = Llm_provider.Types.Conversation;  role = User
      ; content = [ Text prompt ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let* provider_cfg = provider_config_for_schema ~provider_config ~config ~schema in
  let provider =
    Llm_provider.Provider_config.capability_provider_label provider_cfg
  in
  let* response =
    (Llm_provider.Complete.complete ~sw ~net ~config:provider_cfg ~messages ~tools:[] ()).Llm_provider.Completion_outcome.result
    |> Result.map_error (core_error_of_http_error ~provider)
  in
  extract_response ~schema response
;;
