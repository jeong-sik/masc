(* See gemini_stream.mli for module rationale. *)

open Types
open Openai_stream_state

let gemini_message_start_for_model (state : openai_stream_state) raw_model =
  match Model_id.of_string raw_model with
  | Error reason ->
    raise
      (Backend_gemini.Gemini_api_error
         (Printf.sprintf "gemini.modelVersion invalid: %s" reason))
  | Ok model_id ->
    (match state.gemini_message_model with
     | None ->
       state.gemini_message_model <- Some model_id;
       Some (MessageStart { id = ""; model = Model_id.to_string model_id; usage = None })
     | Some observed when Model_id.equal observed model_id -> None
     | Some _ ->
       raise
         (Backend_gemini.Gemini_api_error
            "gemini.modelVersion changed within one streamed response"))
;;

let gemini_chunk_to_events_impl
      (state : openai_stream_state)
      (chunk : Gemini_wire.gemini_chunk)
  : sse_event list * Telemetry_event.t option
  =
  let open Yojson.Safe.Util in
  let events = ref [] in
  let emit evt = events := evt :: !events in
  let telemetry_event = ref None in
  (match chunk.Gemini_wire.gem_model with
   | Some model -> Option.iter emit (gemini_message_start_for_model state model)
   | None -> ());
  let has_thought_part =
    List.exists
      (fun part ->
         Cli_common_json.member_bool "thought" part
         &&
         match part |> member "text" |> to_string_option with
         | Some text when text <> "" -> true
         | Some empty_text ->
           let (_ : string) = empty_text in
           false
         | None -> false)
      chunk.Gemini_wire.gem_parts
  in
  (match state.thinking_state, has_thought_part with
   | Not_thinking, true | Thinking_done, true ->
     state.thinking_state <- Thinking_started (Unix.gettimeofday ())
   | Thinking_started t0, false ->
     let thinking_duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
     state.thinking_state <- Thinking_done;
     telemetry_event
     := Some
          (Telemetry_event.Thinking_complete
             { provider = state.provider; model = state.model; thinking_duration_ms })
   | Not_thinking, false | Thinking_done, false | Thinking_started _, true -> ());
  List.iteri
    (fun part_index part ->
       let is_thought = Cli_common_json.member_bool "thought" part in
       let part_thought_signature = Backend_gemini.thought_signature_of_part part in
       let emit_signed_part ~target ~content_type ~delta thought_signature =
         (match target with
          | Backend_gemini.Gemini_text_part -> state.text_block_started <- false
          | Backend_gemini.Gemini_thought_part -> state.thinking_block_started <- false
          | Backend_gemini.Gemini_image_part
          | Backend_gemini.Gemini_audio_part
          | Backend_gemini.Gemini_document_part -> ());
         let carrier_index = state.next_block_index in
         let carrier_payload =
           Backend_gemini.gemini_part_thought_signature_payload ~target ~thought_signature
         in
         emit
           (ContentBlockStart
              { index = carrier_index
              ; content_type = "redacted_thinking"
              ; tool_id = Some carrier_payload
              ; tool_name = None
              });
         let content_index = carrier_index + 1 in
         emit
           (ContentBlockStart
              { index = content_index; content_type; tool_id = None; tool_name = None });
         emit (ContentBlockDelta { index = content_index; delta });
         state.next_block_index <- content_index + 1
       in
       let emit_function_call_delta () =
         match part |> member "functionCall" with
         | `Assoc _ as fc ->
           let name = Cli_common_json.member_str "name" fc in
           let args =
             match fc |> member "args" with
             | `Null -> `Assoc []
             | args -> args
           in
           let provider_tool_id = fc |> member "id" |> to_string_option in
           let thought_signature = part_thought_signature in
           let resolution, start =
             resolve_tool_block
               state
               ~protocol:"gemini"
               ~wire_index:part_index
               ~provider_tool_id
               ~tool_name:(Some name)
               ~index_policy:
                 (match thought_signature with
                  | Some _ -> Next_after_carrier
                  | None -> Next_available)
               ~idless_semantics:Complete_occurrence
           in
           (match resolution with
            | Tool_block_rejected error -> emit error
            | Tool_block_resolved { block_index = idx; identity } ->
              (match start with
               | Some start ->
                 (match thought_signature with
                  | Some thought_signature ->
                    let payload =
                      Backend_gemini.gemini_thought_signature_payload
                        ~tool_use_id:identity.id
                        ~thought_signature
                    in
                    let carrier_index = idx - 1 in
                    emit
                      (ContentBlockStart
                         { index = carrier_index
                         ; content_type = "redacted_thinking"
                         ; tool_id = Some payload
                         ; tool_name = None
                         })
                  | None -> ());
                 emit start
               | None -> ());
              emit
                (ContentBlockDelta
                   { index = idx; delta = InputJsonSnapshot (Yojson.Safe.to_string args) }))
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> ()
       in
       let emit_textual_part text =
         match part_thought_signature with
         | Some thought_signature ->
           if is_thought
           then
             emit_signed_part
               ~target:Backend_gemini.Gemini_thought_part
               ~content_type:"thinking"
               ~delta:(ThinkingDelta text)
               thought_signature
           else
             emit_signed_part
               ~target:Backend_gemini.Gemini_text_part
               ~content_type:"text"
               ~delta:(TextDelta text)
               thought_signature
         | None when String.equal text "" -> ()
         | None ->
           if is_thought
           then (
             if not state.thinking_block_started
             then (
               state.thinking_block_index <- state.next_block_index;
               emit
                 (ContentBlockStart
                    { index = state.next_block_index
                    ; content_type = "thinking"
                    ; tool_id = None
                    ; tool_name = None
                    });
               state.thinking_block_started <- true;
               state.next_block_index <- state.next_block_index + 1);
             emit
               (ContentBlockDelta
                  { index = state.thinking_block_index; delta = ThinkingDelta text }))
           else (
             if not state.text_block_started
             then (
               state.text_block_index <- state.next_block_index;
               emit
                 (ContentBlockStart
                    { index = state.next_block_index
                    ; content_type = "text"
                    ; tool_id = None
                    ; tool_name = None
                    });
               state.text_block_started <- true;
               state.next_block_index <- state.next_block_index + 1);
             emit
               (ContentBlockDelta
                  { index = state.text_block_index; delta = TextDelta text }))
       in
       let emit_media_part inline_data =
         let target, block =
           Backend_gemini.media_content_block_of_inline_data inline_data
         in
         let content_type, delta =
           match block with
           | Image { media_type; source } ->
             "image", MediaDelta { media_type; source }
           | Audio { media_type; source } ->
             "audio", MediaDelta { media_type; source }
           | Document { media_type; source } ->
             "document", MediaDelta { media_type; source }
           | Text _
           | Thinking _
           | ReasoningDetails _
           | RedactedThinking _
           | ToolUse _
           | ToolResult _ ->
             raise
               (Backend_gemini.Gemini_api_error
                  "Gemini inlineData decoder produced a non-media content block")
         in
         match part_thought_signature with
         | Some thought_signature ->
           emit_signed_part ~target ~content_type ~delta thought_signature
         | None ->
           let index = state.next_block_index in
           emit
             (ContentBlockStart { index; content_type; tool_id = None; tool_name = None });
           emit (ContentBlockDelta { index; delta });
           state.next_block_index <- index + 1
       in
       let emit_non_text_part () =
         match part |> member "functionCall" with
         | `Assoc _ -> emit_function_call_delta ()
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
           (match part |> member "inlineData" with
            | `Assoc _ as inline_data -> emit_media_part inline_data
            | `Null ->
              (match part_thought_signature with
               | Some _ ->
                 raise
                   (Backend_gemini.Gemini_api_error
                      "Gemini thoughtSignature is attached to an unsupported Part")
               | None -> ())
            | _ ->
              raise
                (Backend_gemini.Gemini_api_error "Gemini inlineData must be an object"))
       in
       match part |> member "text" |> to_string_option with
       | Some text when not (String.equal text "") -> emit_textual_part text
       | Some empty_text ->
         (match part |> member "functionCall" with
          | `Assoc _ -> emit_function_call_delta ()
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
            (match part |> member "inlineData" with
             | `Assoc _ as inline_data -> emit_media_part inline_data
             | `Null -> emit_textual_part empty_text
             | _ ->
               raise
                 (Backend_gemini.Gemini_api_error "Gemini inlineData must be an object")))
       | None -> emit_non_text_part ())
    chunk.Gemini_wire.gem_parts;
  (* Finish reason *)
  (match chunk.Gemini_wire.gem_finish_reason with
   | Some (Gemini_wire.Gemini_candidate_finish_reason reason) ->
     let stop_reason =
       Backend_gemini.stop_reason_of_finish_reason
         ~has_tool_use:(Hashtbl.length state.tool_block_indices > 0)
         reason
     in
     emit
       (MessageDelta
          { stop_reason = Some stop_reason
          ; usage = Option.map Types.delta_usage_of_api_usage chunk.Gemini_wire.gem_usage
          });
     emit MessageStop
   | Some (Gemini_wire.Gemini_prompt_block_reason _) ->
     emit
       (MessageDelta
          { stop_reason = Some Refusal
          ; usage = Option.map Types.delta_usage_of_api_usage chunk.Gemini_wire.gem_usage
          });
     emit MessageStop
   | None -> ());
  List.rev !events, !telemetry_event
;;

let rec validate_gemini_parts position = function
  | [] -> Ok ()
  | part :: rest ->
    (match Gemini_wire.validate_gemini_part ~position part with
     | Error _ as error -> error
     | Ok () -> validate_gemini_parts (position + 1) rest)
;;

type gemini_chunk_to_events_error = { reason : string }

let gemini_chunk_to_events state chunk =
  match validate_gemini_parts 0 chunk.Gemini_wire.gem_parts with
  | Error reason -> Error { reason = "gemini_sse_chunk_shape_failure: " ^ reason }
  | Ok () ->
    (try Ok (gemini_chunk_to_events_impl state chunk) with
     | Backend_gemini.Gemini_api_error reason ->
       Error { reason = "gemini_sse_chunk_decode_failure: " ^ reason }
     | Yojson.Safe.Util.Type_error (reason, _) ->
       Error { reason = "gemini_sse_chunk_decode_type_error: " ^ reason }
     | Yojson.Safe.Util.Undefined (reason, _) ->
       Error { reason = "gemini_sse_chunk_decode_undefined: " ^ reason }
     | Invalid_argument reason ->
       Error { reason = "gemini_sse_chunk_decode_invalid_argument: " ^ reason })
;;
