(* See openai_wire.mli for module rationale. *)

open Types

(* Wire shape of streamed tool-call arguments. [Args_fragment] is an incremental
   string chunk that the accumulator appends; [Args_complete] is a whole
   JSON-value snapshot serialized in a single delta, which replaces the block
   buffer so a provider that re-emits the same snapshot does not concatenate it
   into invalid JSON. Each codec and the completed ToolUse boundary validate
   the value shape they allow. *)
type tool_call_arguments =
  | Args_fragment of string
  | Args_complete of string

type openai_tool_call_delta =
  { tc_index : int
  ; tc_id : string option
  ; tc_name : string option
  ; tc_arguments : tool_call_arguments option
  }

type openai_reasoning_details_delta =
  { delta_reasoning_content : string option
  ; delta_details : reasoning_detail list
  }

type openai_chunk_parse_error =
  { reason : string
  ; raw : string
  }

type openai_chunk =
  { chunk_id : string
  ; chunk_model : string
  ; delta_content : string option
  ; delta_refusal : bool
  ; delta_reasoning : string option
  ; delta_reasoning_details : openai_reasoning_details_delta option
  ; delta_tool_calls : openai_tool_call_delta list
  ; finish_reason : string option
  ; chunk_usage : delta_usage option
  ; chunk_timings : inference_timings option
  }

type openai_sse_parse_result =
  | Openai_chunk of openai_chunk
  | Openai_done
  | Openai_empty
  | Openai_provider_error of
      { message : string
      ; error_type : string option
      ; provider_status : Types.provider_status option
      ; report : Types.provider_report
      ; raw : string
      }
  | Openai_parse_failed of openai_chunk_parse_error
  | Openai_undeclared_reasoning_member of
      { declared : string
      ; member : string
      ; raw : string
      }

(* OpenAI-compatible / GLM / Kimi streams terminate with this
   literal SSE payload (the bare token after [data: ]), not a JSON object. SSOT
   for the sentinel shared by the chunk parser and the Responses reader in
   [Streaming]. *)
let openai_done_sentinel = "[DONE]"

let non_blank_json_string = function
  | `String s when String.trim s <> "" -> Ok (Some s)
  | `String _ -> Ok None
  | `Null -> Ok None
  | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> Error "not_string"
;;

(* One streamed reasoning slice is a piece of a longer text, so a slice of
   only spaces or a newline is that text's spacing: GLM-5.3 on z.ai sends 16
   of its 148 [reasoning_content] slices as [" "] or ["\n"] (wire capture
   manual-20260910-glm5.3-zai). Dropping them glues the words and paragraphs
   around them. Only [""] carries nothing. *)
let non_empty_json_string = function
  | `String "" | `Null -> Ok None
  | `String s -> Ok (Some s)
  | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> Error "not_string"
;;

(* The two members OpenAI-compatible chat deltas carry readable reasoning
   under: the DeepSeek-direct [reasoning_content] and the OpenRouter /
   ollama.com [reasoning]. A catalog row declares exactly one of them and the
   parser reads only that one; a chunk whose text rides the other member is a
   misdeclared row, not a second place to look. *)
let documented_reasoning_members = [ "reasoning_content"; "reasoning" ]

(* The documented member other than [declared] that carries non-blank text
   on this delta, if any. *)
let undeclared_reasoning_member ~declared delta =
  List.find_opt
    (fun member ->
       (not (String.equal member declared))
       &&
       match Json_util.assoc_member_opt member delta with
       | None -> false
       | Some value ->
         (match non_blank_json_string value with
          | Ok (Some _) -> true
          | Ok None | Error _ -> false))
    documented_reasoning_members
;;

(* What one delta's reasoning members parsed to. The readable text, the typed
   [reasoning_details] item, a malformed member, or text under a member the
   catalog row did not declare. *)
type openai_reasoning_delta_read =
  | Reasoning_delta_read of string option * openai_reasoning_details_delta option
  | Reasoning_delta_malformed of string
  | Reasoning_delta_undeclared_member of
      { declared : string
      ; member : string
      }

let parse_stream_reasoning_detail ~index = function
  | `Assoc fields as raw ->
    let text =
      match List.assoc_opt "text" fields with
      | Some (`String "") -> None
      | Some (`String s) -> Some s
      | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
      | None -> None
    in
    Ok { raw; text }
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error (Printf.sprintf "malformed_delta_reasoning_details:index:%d:not_object" index)
;;

let parse_stream_reasoning_details = function
  | None -> Ok None
  | Some `Null -> Ok None
  | Some (`List []) -> Ok None
  | Some (`List details) ->
    let rec loop index acc = function
      | [] -> Ok (Some (List.rev acc))
      | detail :: rest ->
        (match parse_stream_reasoning_detail ~index detail with
         | Ok parsed -> loop (index + 1) (parsed :: acc) rest
         | Error _ as error -> error)
    in
    loop 0 [] details
  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error "malformed_delta_reasoning_details:not_list"
;;

let parse_optional_delta_string ~position ~field json =
  match Json_util.assoc_member_opt field json with
  | None | Some `Null -> Ok None
  | Some (`String value) when not (Api_common.string_is_blank value) -> Ok (Some value)
  | Some (`String _) -> Ok None
  | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error
      (Printf.sprintf
         "malformed_delta_tool_call:position:%d:%s_not_string"
         position
         field)
;;

let parse_delta_tool_call_type ~position json =
  match Json_util.assoc_member_opt "type" json with
  | None | Some `Null | Some (`String "function") -> Ok ()
  | Some (`String _) ->
    Error
      (Printf.sprintf "malformed_delta_tool_call:position:%d:unsupported_type" position)
  | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error
      (Printf.sprintf "malformed_delta_tool_call:position:%d:type_not_string" position)
;;

let parse_delta_tool_call_index ~position json =
  match Json_util.assoc_member_opt "index" json with
  | Some (`Int index) when index >= 0 -> Ok index
  | Some (`Intlit raw) ->
    (match int_of_string_opt raw with
     | Some index when index >= 0 -> Ok index
     | Some _ | None ->
       Error
         (Printf.sprintf
            "malformed_delta_tool_call:position:%d:index_not_nonnegative_integer"
            position))
  | None | Some `Null ->
    Error (Printf.sprintf "malformed_delta_tool_call:position:%d:missing_index" position)
  | Some (`Assoc _ | `List _ | `String _ | `Float _ | `Bool _ | `Int _) ->
    Error
      (Printf.sprintf
         "malformed_delta_tool_call:position:%d:index_not_nonnegative_integer"
         position)
;;

(* Some explicitly OpenAI-compatible servers send the arguments as a complete
   JSON value rather than the wire string fragment. This is a structural wire
   variant, not a provider/model-name inference: the complete value replaces
   the accumulator buffer instead of being concatenated. A value that is not an
   object is still the model's argument text; the stream assembly judges it
   the way it judges a fragment that does not parse, so one call with such
   arguments does not fail the stream. *)
let parse_delta_tool_call_arguments function_json =
  match Json_util.assoc_member_opt "arguments" function_json with
  | None | Some `Null -> Ok None
  | Some (`String arguments) -> Ok (Some (Args_fragment arguments))
  | Some arguments ->
    (match Tool_call_input.validate_object arguments with
     | Ok (arguments, _dropped) -> Ok (Some (Args_complete (Yojson.Safe.to_string arguments)))
     | Error (Tool_call_input.Invalid_json _ | Tool_call_input.Not_object) ->
       Ok (Some (Args_complete (Yojson.Safe.to_string arguments))))
;;

let parse_openai_delta_tool_call ~position = function
  | `Assoc _ as tool_call ->
    let ( let* ) = Result.bind in
    let* tc_index = parse_delta_tool_call_index ~position tool_call in
    let* () = parse_delta_tool_call_type ~position tool_call in
    let* tc_id = parse_optional_delta_string ~position ~field:"id" tool_call in
    let* tc_name, tc_arguments =
      match Json_util.assoc_member_opt "function" tool_call with
      | None | Some `Null -> Ok (None, None)
      | Some (`Assoc _ as function_json) ->
        let* tc_name =
          parse_optional_delta_string ~position ~field:"name" function_json
        in
        let* tc_arguments = parse_delta_tool_call_arguments function_json in
        Ok (tc_name, tc_arguments)
      | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
        Error
          (Printf.sprintf
             "malformed_delta_tool_call:position:%d:function_not_object"
             position)
    in
    Ok { tc_index; tc_id; tc_name; tc_arguments }
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error (Printf.sprintf "malformed_delta_tool_call:position:%d:not_object" position)
;;

let parse_openai_delta_tool_calls delta =
  match Json_util.assoc_member_opt "tool_calls" delta with
  | None | Some `Null -> Ok []
  | Some (`List calls) ->
    let rec loop position acc = function
      | [] -> Ok (List.rev acc)
      | call :: rest ->
        (match parse_openai_delta_tool_call ~position call with
         | Ok parsed -> loop (position + 1) (parsed :: acc) rest
         | Error _ as error -> error)
    in
    loop 0 [] calls
  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error "malformed_delta_tool_calls:not_list"
;;

let openai_provider_error_of_envelope ~raw (envelope : Openai_error_envelope.t) =
  Openai_provider_error
    { message = envelope.message
    ; error_type = envelope.error_type
    ; provider_status = envelope.provider_status
    ; report = envelope.report
    ; raw
    }
;;

let openai_provider_error_of_json ~raw json =
  Option.map
    (openai_provider_error_of_envelope ~raw)
    (Option.bind
       (Json_util.assoc_member_opt "error" json)
       Openai_error_envelope.of_error_value)
;;

let choice_finished_with_provider_error choice =
  match Json_util.assoc_member_opt "finish_reason" choice with
  | Some (`String finish_reason) -> Stop_reason_wire.is_provider_error_finish finish_reason
  | None | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) ->
    false
;;

(* A choice that finished with [error] is the provider failing, whether or not
   the chunk also carries the error object: OpenRouter's streaming reference
   puts it at the top level (read first, by [openai_provider_error_of_json]),
   its API overview declares it on the choice, and a chunk may carry neither.
   None of them is a stop reason. *)
let openai_choice_provider_error ~raw choice =
  openai_provider_error_of_envelope
    ~raw
    (Openai_error_envelope.of_errored_choice choice)
;;

let openai_parse_failed ~raw reason = Openai_parse_failed { reason; raw }

(** Parse one OpenAI-compatible SSE data payload into a closed result. In
    particular, [delta.tool_calls] is one atomic protocol batch: one malformed
    member rejects the whole chunk, so no valid sibling can be executed after a
    malformed sibling was silently discarded. *)
let parse_openai_sse_chunk ~streaming_reasoning data_str : openai_sse_parse_result =
  if String.equal data_str openai_done_sentinel
  then Openai_done
  else (
    match Yojson.Safe.from_string data_str with
    | exception Yojson.Json_error message ->
      openai_parse_failed ~raw:data_str ("json_error: " ^ message)
    | json ->
      (match json with
       | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
         openai_parse_failed ~raw:data_str "malformed_openai_sse_payload:not_object"
       | `Assoc _ ->
         (match openai_provider_error_of_json ~raw:data_str json with
          | Some provider_error -> provider_error
          | None ->
            let open Yojson.Safe.Util in
            (try
               let chunk_id = Cli_common_json.member_str "id" json in
               let chunk_model = Cli_common_json.member_str "model" json in
               (* [usage] is top-level, not under a choice, so it is read even
                  for the final [choices=[]] usage chunk. *)
               let chunk_usage = Backend_openai_parse.delta_usage_of_openai_json json in
               (* llama-server attaches a top-level [timings] object to the
                  final chunk (the one with [finish_reason]) without opt-in;
                  [cache_n] is the prompt-token count reused from the slot KV
                  cache. Cloud OpenAI-compatible providers do not send it. *)
               let chunk_timings =
                 let t = json |> member "timings" in
                 if t = `Null
                 then None
                 else (
                   let int_field name = t |> member name |> to_int_option in
                   let float_field name =
                     match t |> member name with
                     | `Float f -> Some f
                     | `Int i -> Some (float_of_int i)
                     | `Intlit s -> float_of_string_opt s
                     | _ -> None
                   in
                   Some
                     { Types.prompt_n = int_field "prompt_n"
                     ; prompt_ms = float_field "prompt_ms"
                     ; prompt_per_second = float_field "prompt_per_second"
                     ; predicted_n = int_field "predicted_n"
                     ; predicted_ms = float_field "predicted_ms"
                     ; predicted_per_second = float_field "predicted_per_second"
                     ; cache_n = int_field "cache_n"
                     })
               in
               match Json_util.assoc_member_opt "choices" json with
               | Some (`List []) ->
                 (match chunk_usage with
                  | None -> Openai_empty
                  | Some _ ->
                    Openai_chunk
                      { chunk_id
                      ; chunk_model
                      ; delta_content = None
                      ; delta_refusal = false
                      ; delta_reasoning = None
                      ; delta_reasoning_details = None
                      ; delta_tool_calls = []
                      ; finish_reason = None
                      ; chunk_usage
                      ; chunk_timings
                      })
               | Some (`List (choice :: _)) when choice_finished_with_provider_error choice ->
                 openai_choice_provider_error ~raw:data_str choice
               | Some (`List (choice :: _)) ->
                 let delta = choice |> member "delta" in
                 (* Streaming answers from chunk-list models (mistral-large-4,
                    recorded live 2026-11-06, #49352) carry the whole answer
                    inside delta.content as chunk objects: thinking fragments
                    under thinking[].text and the visible text in text chunks,
                    with no plain-string delta at all. Split by member shape,
                    the same structural read the non-streaming parser uses. *)
                 let delta_content, content_chunk_thinking =
                   match delta |> member "content" with
                   | `String text -> (Some text, None)
                   | `List blocks ->
                     let text =
                       blocks
                       |> List.filter_map Backend_openai_parse.text_of_openai_content_block
                       |> String.concat ""
                     in
                     let thinking =
                       Backend_openai_parse.chunk_list_thinking_of_openai_content
                         (`List blocks)
                     in
                     let visible =
                       if Api_common.string_is_blank text then None else Some text
                     in
                     let trace =
                       if Api_common.string_is_blank thinking then None else Some thinking
                     in
                     (visible, trace)
                   | `Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
                     (None, None)
                 in
                 let delta_refusal = Stop_reason_wire.refusal_of_json (delta |> member "refusal") in
                 let declared_delta_field field =
                   match delta |> member field |> to_string_option with
                   | Some "" | None -> None
                   | Some _ as value -> value
                 in
                 let reasoning_result =
                   match streaming_reasoning with
                   | Reasoning_dialect.Delta_field_and_details field ->
                     (* The declared member carries the readable text and the
                        sibling [reasoning_details] carries the typed item. A
                        model can send one without the other: OpenRouter's
                        gpt-5.5 streams [reasoning: null] with the encrypted
                        item in [reasoning_details] (live probe 2026-09-10),
                        while minimax-m3 streams [reasoning_content] text with
                        a mirrored text detail. Reading only one member drops
                        the other model's reasoning entirely. *)
                     let reasoning_content_result =
                       match Json_util.assoc_member_opt field delta with
                       | None -> Ok None
                       | Some value ->
                         (match non_empty_json_string value with
                          | Ok _ as ok -> ok
                          | Error _ ->
                            Error
                              (Printf.sprintf
                                 "malformed_delta_reasoning_field:%s:not_string"
                                 field))
                     in
                     let details_result =
                       parse_stream_reasoning_details
                         (Json_util.assoc_member_opt "reasoning_details" delta)
                     in
                     (match reasoning_content_result, details_result with
                      | Ok reasoning_content, Ok details ->
                        (match reasoning_content, details with
                         | None, None -> Reasoning_delta_read (None, None)
                         | Some _, None | _, Some _ ->
                           Reasoning_delta_read
                             ( None
                             , Some
                                 { delta_reasoning_content = reasoning_content
                                 ; delta_details = Option.value details ~default:[]
                                 } ))
                      | Error reason, Ok _ | Ok _, Error reason | Error reason, Error _ ->
                        Reasoning_delta_malformed reason)
                   | Reasoning_dialect.Delta_field field ->
                     (* Only the declared member is read. Text arriving under
                        the other documented spelling is not picked up in its
                        place: that is a misdeclared catalog row, and reading
                        it silently is what kept the row wrong (F111). *)
                     (match declared_delta_field field with
                      | Some value when not (Api_common.string_is_blank value) ->
                        Reasoning_delta_read (Some value, None)
                      | declared ->
                        (* Absent or only spacing. Text under the other
                           spelling is still the misdeclaration; without it the
                           spacing is this member's own slice. *)
                        (match undeclared_reasoning_member ~declared:field delta with
                         | Some member ->
                           Reasoning_delta_undeclared_member { declared = field; member }
                         | None -> Reasoning_delta_read (declared, None)))
                   | Reasoning_dialect.No_streaming_reasoning
                   | Reasoning_dialect.Template_parser -> Reasoning_delta_read (None, None)
                 in
                 (match reasoning_result with
                  | Reasoning_delta_malformed reason ->
                    openai_parse_failed ~raw:data_str reason
                  | Reasoning_delta_undeclared_member { declared; member } ->
                    Openai_undeclared_reasoning_member
                      { declared; member; raw = data_str }
                  | Reasoning_delta_read (delta_reasoning, delta_reasoning_details) ->
                    (* Chunk-list thinking is its own named source beside the
                       declared delta field: the two never meet on one wire
                       today, and if they ever do both texts belong to the
                       trace, declared field first. *)
                    let delta_reasoning =
                      match content_chunk_thinking with
                      | None -> delta_reasoning
                      | Some thinking ->
                        Some (Option.value delta_reasoning ~default:"" ^ thinking)
                    in
                    (match delta_refusal, parse_openai_delta_tool_calls delta with
                     | Error (), _ ->
                       openai_parse_failed ~raw:data_str "malformed_openai_sse_payload:refusal_not_string"
                     | Ok _, Error reason -> openai_parse_failed ~raw:data_str reason
                     | Ok delta_refusal, Ok delta_tool_calls ->
                       let finish_reason =
                         choice |> member "finish_reason" |> to_string_option
                       in
                       Openai_chunk
                         { chunk_id
                         ; chunk_model
                         ; delta_content
                         ; delta_refusal
                         ; delta_reasoning
                         ; delta_reasoning_details
                         ; delta_tool_calls
                         ; finish_reason
                         ; chunk_usage
                         ; chunk_timings
                         }))
               | None | Some `Null ->
                 openai_parse_failed
                   ~raw:data_str
                   "malformed_openai_sse_payload:missing_choices"
               | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
                 openai_parse_failed
                   ~raw:data_str
                   "malformed_openai_sse_payload:choices_not_list"
             with
             | Yojson.Safe.Util.Type_error (message, _) ->
               openai_parse_failed ~raw:data_str ("type_error: " ^ message)
             | Yojson.Safe.Util.Undefined (message, _) ->
               openai_parse_failed ~raw:data_str ("undefined: " ^ message)
             | Invalid_argument message ->
               openai_parse_failed ~raw:data_str ("invalid_argument: " ^ message)))))
;;
