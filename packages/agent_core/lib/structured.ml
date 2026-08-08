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

let text_block = function
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

let parse_schema_text_json schema json =
  try
    schema.parse json
    |> Result.map_error (fun e -> Error.Serialization (JsonParseError { detail = e }))
  with
  | Yojson.Json_error detail -> Error (Error.Serialization (JsonParseError { detail }))
;;

type response_json_shape =
  | Any_json
  | Object_json

let text_json_of_response (response : api_response) =
  response |> Types.text_of_response |> String.trim
;;

let extract_response_json ?(shape = Any_json) (response : api_response)
  : (Yojson.Safe.t, Error.sdk_error) result
  =
  let text = text_json_of_response response in
  if text = ""
  then
    Error
      (Error.Serialization
         (JsonParseError
            { detail = "structured output response did not contain text JSON" }))
  else
    let* json =
      parse_json_string text
      |> Result.map_error (fun detail -> Error.Serialization (JsonParseError { detail }))
    in
    match shape, json with
    | Any_json, _ -> Ok json
    | Object_json, `Assoc _ -> Ok json
    | Object_json, _ ->
      Error
        (Error.Serialization
           (JsonParseError
              { detail = "structured output response JSON was not an object" }))
;;

(** Extract structured output from the response text JSON. *)
let extract_text_json ~(schema : _ schema) (response : api_response)
  : ('a, Error.sdk_error) result
  =
  let* json = extract_response_json response in
  parse_schema_text_json schema json
;;

let sdk_error_of_http_error =
  Http_error_sdk.of_http_error
    ~accept_rejected:(Config_invalid_config { field = "response_format" })
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
  : ('a, Error.sdk_error) result
  =
  let messages =
    [ { role = User
      ; content = [ Text prompt ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let* provider_cfg = provider_config_for_schema ~provider_config ~config ~schema in
  let* response =
    Llm_provider.Complete.complete ~sw ~net ~config:provider_cfg ~messages ~tools:[] ()
    |> Result.map_error sdk_error_of_http_error
  in
  extract_text_json ~schema response
;;

(* ── Extractors ────────────────────────────────────────────────── *)

(** An extractor converts an api_response into a typed value.
    Use with {!run_structured} for Agent.t-level structured output. *)
type 'a extractor = api_response -> ('a, string) result

let schema_extractor (schema : 'a schema) : 'a extractor =
  fun response -> extract_text_json ~schema response |> Result.map_error Error.to_string
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

(** Run an agent with a prompt and extract a structured value from the response.
    Uses the full Agent pipeline (hooks, tools, tracing) unlike {!extract}
    which calls the API directly. *)
let run_structured ~sw ?clock agent prompt ~(extract : 'a extractor) =
  let* response = Agent.run ~sw ?clock agent prompt in
  extract response
  |> Result.map_error (fun detail -> Error.Serialization (JsonParseError { detail }))
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
  : ('a * api_response, Error.sdk_error) result
  =
  let messages =
    [ { role = User
      ; content = [ Text prompt ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let* provider_cfg = provider_config_for_schema ~provider_config ~config ~schema in
  let* response =
    Llm_provider.Complete.complete_stream
      ~sw
      ~net
      ?clock
      ~config:provider_cfg
      ~messages
      ~tools:[]
      ~on_event
      ()
    |> Result.map_error sdk_error_of_http_error
  in
  let* value = extract_text_json ~schema response in
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
  | _ -> false
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
  | _ -> false
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
  | _ -> false
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
  | _ -> false
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
  | _ -> false
;;
