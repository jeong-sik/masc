(** OpenAI-compatible response parsing.

    Parses JSON responses from Openai Chat Completions API into
    agent_sdk Types (api_response, api_usage).

    @since 0.92.0 extracted from Backend_openai *)

open Types

(* oas#2483: a blank-content 200 must not be accepted as [Ok content=[]] (a
   silent empty turn that storms downstream). The parser fails closed with a
   typed [Empty_completion] carrying the response identity so a consumer can
   attribute the empty turn to a runtime binding instead of retrying blindly. *)
type empty_completion =
  { id : string
  ; model : string
  ; stop_reason : Types.stop_reason
  ; usage : Types.api_usage option
  ; telemetry : Types.inference_telemetry option
  }

type parse_error =
  | Provider_error of string
  | Empty_completion of empty_completion

let parse_error_to_string = function
  | Provider_error msg -> msg
  | Empty_completion { stop_reason; model; _ } ->
    Printf.sprintf
      "empty completion (no thinking, text, or tool calls; model=%s, stop_reason=%s)"
      model
      (Types.stop_reason_to_string stop_reason)
;;

let ( let* ) = Result.bind

let first_some a b =
  match a with
  | Some _ -> a
  | None -> b
;;

let json_float_number = function
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | `Assoc _ | `List _ | `String _ | `Intlit _ | `Bool _ | `Null -> None
;;

let non_blank_json_string = function
  | `String s when not (Api_common.string_is_blank s) -> Some s
  | `String _ | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    None
;;

let assoc_field_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let reasoning_detail_of_json ~index = function
  | `Assoc fields as raw ->
    let text =
      match List.assoc_opt "text" fields with
      | Some text -> non_blank_json_string text
      | None -> None
    in
    Ok { raw; text }
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error (Printf.sprintf "malformed_reasoning_details:index:%d:not_object" index)
;;

let reasoning_details_of_message msg =
  match assoc_field_opt "reasoning_details" msg with
  | None -> Ok None
  | Some (`List details) ->
    let rec loop index acc = function
      | [] -> Ok (Some (List.rev acc))
      | detail :: rest ->
        (match reasoning_detail_of_json ~index detail with
         | Ok parsed -> loop (index + 1) (parsed :: acc) rest
         | Error _ as error -> error)
    in
    loop 0 [] details
  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) ->
    Error "malformed_reasoning_details:not_list"
;;

let reasoning_texts_of_block = function
  | Thinking { content; _ } -> [ content ]
  | ReasoningDetails { reasoning_content; details } ->
    let content = reasoning_details_text ~reasoning_content ~details in
    if Api_common.string_is_blank content then [] else [ content ]
  | Text _
  | RedactedThinking _
  | ToolUse _
  | ToolResult _
  | Image _
  | Document _
  | Audio _ -> []
;;

let reasoning_content_blocks_of_message_result msg =
  let open Yojson.Safe.Util in
  let reasoning_content = non_blank_json_string (msg |> member "reasoning_content") in
  let* reasoning_details = reasoning_details_of_message msg in
  match reasoning_details with
  | Some details -> Ok [ ReasoningDetails { reasoning_content; details } ]
  | None ->
    (match reasoning_content with
     | Some content -> Ok [ Thinking { signature = None; content } ]
     | None ->
       (match non_blank_json_string (msg |> member "reasoning") with
        | Some content -> Ok [ Thinking { signature = None; content } ]
        | None -> Ok []))
;;

let text_of_openai_content_block = function
  | `String s -> Some s
  | `Assoc fields ->
    (match List.assoc_opt "text" fields with
     | Some (`String s) -> Some s
     | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None
       -> None)
  | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let text_content_of_openai_content = function
  | `String s -> s
  | `Null -> ""
  | `List blocks ->
    blocks |> List.filter_map text_of_openai_content_block |> String.concat ""
  | `Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> ""
;;

let parse_tool_call_string_field ~tool_index ~field json =
  let open Yojson.Safe.Util in
  match json |> member field |> to_string_option with
  | Some value when not (Api_common.string_is_blank value) -> Ok value
  | Some _ | None ->
    Error (Printf.sprintf "malformed_tool_call:index:%d:missing_%s" tool_index field)
;;

let parse_tool_call_function ~tool_index json =
  let open Yojson.Safe.Util in
  match json |> member "function" with
  | `Assoc _ as fn -> Ok fn
  | `Null | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
    Error (Printf.sprintf "malformed_tool_call:index:%d:missing_function" tool_index)
;;

let parse_tool_call_arguments ~tool_index raw =
  match Tool_call_input.parse_object raw with
  | Ok input -> Ok input
  | Error Tool_call_input.Not_object ->
    Error (Printf.sprintf "malformed_tool_call_arguments:index:%d:not_object" tool_index)
  | Error (Tool_call_input.Invalid_json message) ->
    Error (Printf.sprintf "malformed_tool_call_arguments:index:%d:%s" tool_index message)
;;

let parse_tool_call ~tool_index tc =
  let* id = parse_tool_call_string_field ~tool_index ~field:"id" tc in
  let* fn = parse_tool_call_function ~tool_index tc in
  let* name = parse_tool_call_string_field ~tool_index ~field:"name" fn in
  let* raw_arguments = parse_tool_call_string_field ~tool_index ~field:"arguments" fn in
  let* input = parse_tool_call_arguments ~tool_index raw_arguments in
  Ok (ToolUse { id; name; input })
;;

let parse_tool_calls_field = function
  | `Null -> Ok []
  | `List calls ->
    let rec loop acc index = function
      | [] -> Ok (List.rev acc)
      | tc :: rest ->
        (match parse_tool_call ~tool_index:index tc with
         | Ok tool_call -> loop (tool_call :: acc) (index + 1) rest
         | Error _ as error -> error)
    in
    loop [] 0 calls
  | `Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
    Error "malformed_tool_calls:not_list"
;;

let member_int_fallback json field_names =
  let open Yojson.Safe.Util in
  let rec loop = function
    | [] -> None
    | key :: rest ->
      (match json |> member key |> to_int_option with
       | Some _ as value -> value
       | None -> loop rest)
  in
  loop field_names
;;

let member_float_fallback json field_names =
  let open Yojson.Safe.Util in
  let rec loop = function
    | [] -> None
    | key :: rest ->
      let value = json_float_number (json |> member key) in
      (match value with
       | Some _ -> value
       | None -> loop rest)
  in
  loop field_names
;;

let derive_ms token_count tok_per_sec =
  match token_count, tok_per_sec with
  | Some n, Some v when v > 0.0 -> Some (float_of_int n /. v *. 1000.0)
  | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
;;

let usage_of_openai_json json =
  let open Yojson.Safe.Util in
  let usage = json |> member "usage" in
  if usage = `Null
  then None
  else (
    let prompt_tokens =
      member_int_fallback usage [ "prompt_tokens"; "input_tokens" ]
      |> Option.value ~default:0
    in
    let cached_tokens =
      match member_int_fallback usage [ "prompt_cache_hit_tokens" ] with
      | Some n -> n
      | None ->
        let details = usage |> member "prompt_tokens_details" in
        if details = `Null then 0 else Cli_common_json.member_int "cached_tokens" details
    in
    Some
      { input_tokens = prompt_tokens
      ; output_tokens =
          member_int_fallback usage [ "completion_tokens"; "output_tokens" ]
          |> Option.value ~default:0
      ; cache_creation_input_tokens = 0
      ; cache_read_input_tokens = cached_tokens
      ; cost_usd = None
      })
;;

(** Extract provider-reported inference telemetry from the raw JSON.
    llama-server populates [timings] and [system_fingerprint];
    cloud providers return [None] for those fields. *)
let telemetry_of_openai_json json =
  let open Yojson.Safe.Util in
  let usage = json |> member "usage" in
  let usage_int keys = if usage = `Null then None else member_int_fallback usage keys in
  let usage_float keys =
    if usage = `Null then None else member_float_fallback usage keys
  in
  let system_fingerprint = json |> member "system_fingerprint" |> to_string_option in
  let t = json |> member "timings" in
  let prompt_n =
    first_some
      (if t = `Null then None else member_int_fallback t [ "prompt_n" ])
      (usage_int [ "prompt_tokens"; "input_tokens" ])
  in
  let prompt_per_second =
    first_some
      (if t = `Null
       then None
       else member_float_fallback t [ "prompt_per_second"; "prompt_tps" ])
      (first_some
         (member_float_fallback json [ "prompt_tps" ])
         (usage_float [ "prompt_tps"; "prompt_per_second" ]))
  in
  let predicted_n =
    first_some
      (if t = `Null then None else member_int_fallback t [ "predicted_n" ])
      (usage_int [ "completion_tokens"; "output_tokens" ])
  in
  let predicted_per_second =
    first_some
      (if t = `Null
       then None
       else member_float_fallback t [ "predicted_per_second"; "generation_tps" ])
      (first_some
         (member_float_fallback json [ "generation_tps" ])
         (usage_float [ "generation_tps"; "predicted_per_second" ]))
  in
  let timings =
    if t = `Null && prompt_per_second = None && predicted_per_second = None
    then None
    else
      Some
        { Types.prompt_n
        ; prompt_ms =
            first_some
              (if t = `Null then None else member_float_fallback t [ "prompt_ms" ])
              (derive_ms prompt_n prompt_per_second)
        ; prompt_per_second
        ; predicted_n
        ; predicted_ms =
            first_some
              (if t = `Null then None else member_float_fallback t [ "predicted_ms" ])
              (derive_ms predicted_n predicted_per_second)
        ; predicted_per_second
        ; cache_n = (if t = `Null then None else member_int_fallback t [ "cache_n" ])
        }
  in
  let reasoning_tokens =
    if usage = `Null
    then None
    else (
      let details = usage |> member "completion_tokens_details" in
      if details = `Null
      then None
      else details |> member "reasoning_tokens" |> to_int_option)
  in
  let peak_memory_gb =
    first_some
      (member_float_fallback json [ "peak_memory"; "peak_memory_gb" ])
      (usage_float [ "peak_memory"; "peak_memory_gb" ])
  in
  Some
    { Types.default_inference_telemetry with
      system_fingerprint
    ; timings
    ; reasoning_tokens
    ; peak_memory_gb
    }
;;

(** Parse an OpenAI-compatible JSON response string into an [api_response].
    Returns [Error msg] when the response body contains an API error. *)
let parse_openai_response_result_json_raw (raw_json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let json =
    match raw_json with
    | `List (first :: _) -> first
    | `List [] -> raw_json
    | other -> other
  in
  match json |> member "error" with
  | `Null ->
    let choice = json |> member "choices" |> index 0 in
    let msg = choice |> member "message" in
    let* finish_reason =
      match choice |> member "finish_reason" |> to_string_option with
      | Some finish_reason -> Ok finish_reason
      | None -> Error "malformed_openai_response:missing_finish_reason"
    in
    let text_content = text_content_of_openai_content (msg |> member "content") in
    let* tool_blocks = parse_tool_calls_field (msg |> member "tool_calls") in
    (* Ollama uses "reasoning"; OpenAI-compatible providers commonly use
       "reasoning_content"; MiniMax split mode may return "reasoning_details".
       MiniMax split reasoning stays as [ReasoningDetails] so the original
       provider message shape can be replayed without overloading visible or
       redacted thinking channels. Other reasoning text stays [Thinking]. *)
    let* thinking_blocks = reasoning_content_blocks_of_message_result msg in
    let stop_reason =
      (* SSOT: Stop_reason_wire owns the wire finish-reason -> stop_reason table
         and the StopToolUse => has-tool-block invariant (previously duplicated
         here and in the streaming chunk handler with divergent guards). *)
      Stop_reason_wire.of_finish
        (Stop_reason_wire.wire_finish_of_string finish_reason)
        ~has_tool_blocks:(tool_blocks <> [])
    in
    Ok
      { id = Cli_common_json.member_str "id" json
      ; model = Cli_common_json.member_str "model" json
      ; stop_reason
      ; content =
          (let text_blocks =
             if Api_common.string_is_blank text_content then [] else [ Text text_content ]
           in
           (* Reasoning stays typed as [Thinking] end-to-end -- it is never
              promoted into a [Text] block. Promotion erased the type distinction
              between reasoning and answer, so on the next turn the request
              serializer re-fed the reasoning as the assistant's answer content
              and the model re-reasoned over it: the #2236 CoT re-injection loop.
              Surfacing reasoning-only replies for display is a read-side
              projection concern (see [Api_common.text_blocks_to_string] and the
              runtime text extractors), not a parse-time mutation that also
              pollutes replay. *)
           thinking_blocks @ text_blocks @ tool_blocks)
      ; usage = usage_of_openai_json json
      ; telemetry = telemetry_of_openai_json json
      }
  | err ->
    let msg =
      err
      |> member "message"
      |> to_string_option
      |> Option.value ~default:"Unknown API error"
    in
    Error msg
;;

(* oas#2483 fail-closed wrapper: an all-empty completion (no thinking, no text,
   no tool_calls) becomes a typed [Empty_completion] instead of [Ok content=[]]
   — the silent empty turn that stormed downstream. Blank text WITH tool_calls
   has content=[ToolUse ..] (content <> []) and stays [Ok]. *)
let parse_openai_response_result_json raw_json =
  match parse_openai_response_result_json_raw raw_json with
  | Error msg -> Error (Provider_error msg)
  | Ok ({ content = []; id; model; stop_reason; usage; telemetry } : Types.api_response)
    -> Error (Empty_completion { id; model; stop_reason; usage; telemetry })
  | Ok resp -> Ok resp
;;

(** [parse_openai_response_result] parses [json_str] then delegates to
    {!parse_openai_response_result_json}.  Callers that already hold the
    parsed [Yojson.Safe.t] (e.g. {!Backend_glm.parse_response}, which also
    error-checks and reasoning-extracts from the same body) should call
    {!parse_openai_response_result_json} directly to avoid re-parsing. *)
let parse_openai_response_result json_str =
  parse_openai_response_result_json (Yojson.Safe.from_string json_str)
;;

let%test "missing finish reason is not synthesized as stop" =
  match
    parse_openai_response_result
      {|{"id":"chat-1","model":"m","choices":[{"message":{"content":"ok"}}]}|}
  with
  | Error (Provider_error "malformed_openai_response:missing_finish_reason") -> true
  | Error _ | Ok _ -> false
;;

let%test "usage_of_openai_json supports mlx_vlm input/output token fields" =
  let json =
    `Assoc
      [ ( "usage"
        , `Assoc
            [ "input_tokens", `Int 11; "output_tokens", `Int 5; "total_tokens", `Int 16 ]
        )
      ]
  in
  match usage_of_openai_json json with
  | Some u -> u.input_tokens = 11 && u.output_tokens = 5
  | None -> false
;;

let%test "telemetry_of_openai_json synthesizes timings from mlx_vlm usage" =
  let json =
    `Assoc
      [ ( "usage"
        , `Assoc
            [ "input_tokens", `Int 11
            ; "output_tokens", `Int 5
            ; "prompt_tps", `Float 21.55
            ; "generation_tps", `Float 81.56
            ] )
      ; "peak_memory", `Float 52.66
      ]
  in
  match telemetry_of_openai_json json with
  | Some { timings = Some t; peak_memory_gb = Some peak; _ } ->
    t.prompt_n = Some 11
    && t.predicted_n = Some 5
    && Option.value ~default:0.0 t.prompt_per_second > 21.5
    && Option.value ~default:0.0 t.predicted_per_second > 81.5
    && Option.value ~default:0.0 t.prompt_ms > 500.0
    && Option.value ~default:0.0 t.predicted_ms > 60.0
    && peak = 52.66
  | Some { timings = None; _ }
  | Some { timings = Some _; peak_memory_gb = None; _ }
  | None -> false
;;

let%test "telemetry_of_openai_json keeps timings none without timing signals" =
  let json =
    `Assoc [ "usage", `Assoc [ "prompt_tokens", `Int 11; "completion_tokens", `Int 5 ] ]
  in
  match telemetry_of_openai_json json with
  | Some { timings = None; peak_memory_gb = None; _ } -> true
  | Some { timings = Some _; _ }
  | Some { timings = None; peak_memory_gb = Some _; _ }
  | None -> false
;;
