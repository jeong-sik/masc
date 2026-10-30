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

let extract_response_json ?shape response =
  inspect_response_json ?shape response |> result_of_response_outcome
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
  let response_format = Types.JsonSchema (schema_to_json_schema schema) in
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

(* ── Extractors ────────────────────────────────────────────────── *)

(** An extractor converts an api_response into a typed value. *)
type 'a extractor = api_response -> ('a, string) result

let schema_extractor (schema : 'a schema) : 'a extractor =
  fun response -> extract_response ~schema response |> Result.map_error Error.to_string
;;

let response_json_extractor ?shape () : Yojson.Safe.t extractor =
  fun response ->
  extract_response_json ?shape response |> Result.map_error Error.to_string
;;

(* NOTE: keep [json_extractor] / [text_extractor] for callers who parse
   free-form responses themselves. *)
let try_parse f x =
  try Ok (f x) with
  | Yojson.Json_error e -> Error (Printf.sprintf "JSON parse: %s" e)
  | Yojson.Safe.Util.Type_error (msg, _) -> Error (Printf.sprintf "JSON type: %s" msg)
  | Failure msg -> Error (Printf.sprintf "parse failure: %s" msg)
;;

let json_extractor (parse : Yojson.Safe.t -> 'a) : 'a extractor =
  fun resp ->
  let texts = List.filter_map text_block resp.content in
  let* text =
    match texts with
    | [] -> Error "no text content in response"
    | text :: _ -> Ok text
  in
  let* json =
    parse_json_string text
    |> Result.map_error (fun e -> Printf.sprintf "JSON parse: %s" e)
  in
  try_parse parse json
;;

(** Extract a value from the first text block using a string parser. *)
let text_extractor (parse : string -> 'a option) : 'a extractor =
  fun resp ->
  let texts = List.filter_map text_block resp.content in
  let* text =
    match texts with
    | [] -> Error "no text content in response"
    | text :: _ -> Ok text
  in
  parse text |> Option.to_result ~none:"text extractor returned None"
;;

(** Extract structured output with SSE streaming.
    Like [extract] but streams via {!Llm_provider.Complete.complete_stream}. *)
let extract_stream
      ~sw
      ~net
      ~provider_config
      ?clock
      ~config
      ~(schema : 'a schema)
      ~on_event
      prompt
  : ('a * api_response, Error.t) result
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
    (Llm_provider.Complete.complete_stream
      ~sw
      ~net
      ?clock
      ~config:provider_cfg
      ~messages
      ~tools:[]
      ~on_event
      ()).Llm_provider.Completion_outcome.result
    |> Result.map_error (core_error_of_http_error ~provider)
  in
  let* value = extract_response ~schema response in
  Ok (value, response)
;;

[@@@coverage off]
(* === Inline tests === *)

let%test "json_extractor parses json from text block" =
  let extractor =
    json_extractor (fun j -> Yojson.Safe.Util.(j |> member "key" |> to_string))
  in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "{\"key\":\"val\"}" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Ok "val" -> true
  | Ok _ | Error _ -> false
;;

let%test "json_extractor returns error on empty content" =
  let extractor = json_extractor (fun _ -> "x") in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = []
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "json_extractor returns error on invalid json" =
  let extractor = json_extractor (fun _ -> "x") in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "not json" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "text_extractor parses text content" =
  let extractor = text_extractor (fun s -> if s = "yes" then Some true else None) in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "yes" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Ok true -> true
  | Ok false | Error _ -> false
;;

let%test "text_extractor returns error when parse returns None" =
  let extractor = text_extractor (fun _ -> None) in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "anything" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Error _ -> true
  | Ok _ -> false
;;

(* --- Additional coverage tests --- *)

let%test "json_extractor type error produces descriptive message" =
  let extractor =
    json_extractor (fun j -> Yojson.Safe.Util.(j |> member "key" |> to_int))
  in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "{\"key\":\"not_int\"}" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Error msg -> String.length msg > 0
  | Ok _ -> false
;;

let%test "json_extractor Failure propagation" =
  let extractor = json_extractor (fun _ -> failwith "custom fail") in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ Text "{}" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Error msg -> String.length msg > 0
  | Ok _ -> false
;;

let%test "text_extractor skips non-text blocks" =
  let extractor = text_extractor (fun s -> Some s) in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ ToolUse { id = "tu"; name = "t"; input = `Null }; Text "target" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Ok "target" -> true
  | Ok _ | Error _ -> false
;;

let%test "text_extractor empty content" =
  let extractor = text_extractor (fun s -> Some s) in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = []
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Error "no text content in response" -> true
  | Ok _ | Error _ -> false
;;

let%test "json_extractor non-text content only" =
  let extractor = json_extractor (fun _ -> "x") in
  let resp =
    { id = ""
    ; model = ""
    ; stop_reason = EndTurn
    ; content = [ ToolUse { id = "tu"; name = "t"; input = `Null } ]
    ; usage = None
    ; telemetry = None
    }
  in
  match extractor resp with
  | Error "no text content in response" -> true
  | Ok _ | Error _ -> false
;;
