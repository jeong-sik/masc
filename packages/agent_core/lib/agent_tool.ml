(** Agent-as-tool: wrap an agent runner as a callable {!Tool.t}.

    @since 0.102.0 *)

open Types

type agent_runner = string -> (api_response, Error.sdk_error) result

type child_output =
  { text : string
  ; response : api_response
  }

type config =
  { name : string
  ; description : string
  ; runner : agent_runner
  ; output_summarizer : (string -> string) option
  }

(* ── Text extraction ─────────────────────────────────────────── *)

let text_of_response (resp : api_response) =
  List.filter_map
    (function
      | Text s -> Some s
      | _ -> None)
    resp.content
  |> String.concat "\n"
;;

(* stop_reason wire serialization is the SSOT [Types.stop_reason_to_string]
   (this module's former local copy was byte-identical). *)

let api_usage_to_json = function
  | None -> `Null
  | Some usage ->
    `Assoc
      [ "input_tokens", `Int usage.input_tokens
      ; "output_tokens", `Int usage.output_tokens
      ; "cache_creation_input_tokens", `Int usage.cache_creation_input_tokens
      ; "cache_read_input_tokens", `Int usage.cache_read_input_tokens
      ; ( "cost_usd"
        , match usage.cost_usd with
          | Some cost -> `Float cost
          | None -> `Null )
      ]
;;

let content_block_to_json = function
  | Text text -> `Assoc [ "type", `String "text"; "text", `String text ]
  | Thinking { content; signature } ->
    `Assoc
      [ "type", `String "thinking"
      ; ( "signature"
        , match signature with
          | Some s -> `String s
          | None -> `Null )
      ; "content", `String content
      ]
  | ReasoningDetails { reasoning_content; details } ->
    let fields =
      [ ( "details"
        , `List (List.map (fun (detail : reasoning_detail) -> detail.raw) details) )
      ]
    in
    let fields =
      match reasoning_content with
      | Some content -> ("reasoning_content", `String content) :: fields
      | None -> fields
    in
    `Assoc (("type", `String "reasoning_details") :: fields)
  | RedactedThinking value ->
    `Assoc [ "type", `String "redacted_thinking"; "content", `String value ]
  | ToolUse { id; name; input } ->
    `Assoc
      [ "type", `String "tool_use"
      ; "id", `String id
      ; "name", `String name
      ; "input", input
      ]
  | ToolResult { tool_use_id; content; outcome; json; _ } ->
    `Assoc
      [ "type", `String "tool_result"
      ; "tool_use_id", `String tool_use_id
      ; "content", `String content
      ; "is_error", `Bool (tool_result_outcome_is_error outcome)
      ; "json", Option.value ~default:`Null json
      ]
  | Image { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "image"
      ; "media_type", `String media_type
      ; "data", `String data
      ; "source_type", `String (Types.media_source_kind_to_string source_type)
      ]
  | Document { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "document"
      ; "media_type", `String media_type
      ; "data", `String data
      ; "source_type", `String (Types.media_source_kind_to_string source_type)
      ]
  | Audio { media_type; data; source_type } ->
    `Assoc
      [ "type", `String "audio"
      ; "media_type", `String media_type
      ; "data", `String data
      ; "source_type", `String (Types.media_source_kind_to_string source_type)
      ]
;;

let child_output_to_json output =
  let response = output.response in
  `Assoc
    [ "type", `String "agent_tool_child_output"
    ; "response_id", `String response.id
    ; "model", `String response.model
    ; "stop_reason", `String (Types.stop_reason_to_string response.stop_reason)
    ; "text", `String output.text
    ; "content", `List (List.map content_block_to_json response.content)
    ; "usage", api_usage_to_json response.usage
    ]
;;

(* ── Tool handler ────────────────────────────────────────────── *)

let prompt_param =
  { name = "prompt"
  ; description = "The prompt to send to the agent"
  ; param_type = String
  ; required = true
  }
;;

let parameters = [ prompt_param ]

let prompt_of_input = function
  | `Assoc fields ->
    (match List.assoc_opt "prompt" fields with
     | Some (`String s) -> Ok s
     | Some _ -> Error "Agent_tool prompt must be a string"
     | None -> Error "Agent_tool input requires a prompt field")
  | json -> Error ("Agent_tool input must be an object: " ^ Yojson.Safe.to_string json)
;;

let make_handler config : Tool.tool_handler =
  fun (input : Yojson.Safe.t) ->
  (* RFC-OAS-029 S4.3: the untyped handler delegates to the typed parser
     [prompt_of_input] (the SSOT) and propagates its [Error] instead of
     silently serializing malformed input as the prompt. *)
  match prompt_of_input input with
  | Error message -> Error { message; recoverable = false; error_class = None }
  | Ok prompt ->
    (match config.runner prompt with
     | Ok response ->
       let text = text_of_response response in
       let output =
         match config.output_summarizer with
         | Some summarize -> summarize text
         | None -> text
       in
       Ok { content = output; _meta = None }
     | Error e ->
       Error { message = Error.to_string e; recoverable = false; error_class = None })
;;

let make_typed_handler config prompt =
  match config.runner prompt with
  | Ok response ->
    let text = text_of_response response in
    let text =
      match config.output_summarizer with
      | Some summarize -> summarize text
      | None -> text
    in
    Ok { text; response }
  | Error e -> Error (Error.to_string e)
;;

(* ── Construction ────────────────────────────────────────────── *)

let create config =
  Tool.create
    ~name:config.name
    ~description:config.description
    ~parameters
    (make_handler config)
;;

let create_typed config =
  Typed_tool.create
    ~name:config.name
    ~description:config.description
    ~params:parameters
    ~parse:prompt_of_input
    ~handler:(make_typed_handler config)
    ~encode:child_output_to_json
    ()
;;

let create_simple ~name ~description runner =
  create { name; description; runner; output_summarizer = None }
;;

[@@@coverage off]
(* === Inline tests === *)

let mock_runner text _prompt =
  Ok
    { id = "m"
    ; model = "m"
    ; stop_reason = EndTurn
    ; content = [ Text text ]
    ; usage = None
    ; telemetry = None
    }
;;

let failing_runner _prompt = Error (Error.Internal "agent failed")

let%test "create_simple produces valid tool" =
  let tool = create_simple ~name:"helper" ~description:"A helper" (mock_runner "hello") in
  tool.schema.name = "helper"
;;

let%test "tool has prompt parameter" =
  let tool = create_simple ~name:"t" ~description:"d" (mock_runner "x") in
  List.exists (fun (p : tool_param) -> p.name = "prompt") tool.schema.parameters
;;

let%test "handler returns agent text" =
  let tool = create_simple ~name:"t" ~description:"d" (mock_runner "agent says hello") in
  match Tool.execute tool (`Assoc [ "prompt", `String "hi" ]) with
  | Ok { content; _meta = _ } -> content = "agent says hello"
  | Error _ -> false
;;

let%test "handler rejects string input outside its schema" =
  let tool = create_simple ~name:"t" ~description:"d" (mock_runner "ok") in
  match Tool.execute tool (`String "direct prompt") with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "handler propagates error" =
  let tool = create_simple ~name:"t" ~description:"d" failing_runner in
  match Tool.execute tool (`Assoc [ "prompt", `String "test" ]) with
  | Error { recoverable; _ } -> not recoverable
  | Ok _ -> false
;;

let%test "output_summarizer applied" =
  let tool =
    create
      { name = "sum_tool"
      ; description = "d"
      ; runner = mock_runner "long output text here"
      ; output_summarizer = Some (fun s -> String.sub s 0 4)
      }
  in
  match Tool.execute tool (`Assoc [ "prompt", `String "q" ]) with
  | Ok { content; _meta = _ } -> content = "long"
  | Error _ -> false
;;

let%test "declared inputs exactly match the consumed prompt" =
  let tool =
    create
      { name = "t"
      ; description = "d"
      ; runner = mock_runner "ok"
      ; output_summarizer = None
      }
  in
  tool.schema.parameters = [ prompt_param ]
;;
