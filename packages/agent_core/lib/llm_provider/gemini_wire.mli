(** Gemini_wire — reader for one Gemini [streamGenerateContent?alt=sse] data
    payload.

    Each payload is a JSON object shaped like
    [{candidates: [{content: {parts: [...]}}]}], and a chunk can carry text,
    thought or functionCall parts. Nothing here keeps state between chunks:
    {!Streaming.gemini_chunk_to_events} turns the chunks into stream events.

    Pure module: no I/O, no env reads. *)

open Types

type gemini_terminal_reason =
  | Gemini_candidate_finish_reason of string
  | Gemini_prompt_block_reason of string

type gemini_chunk =
  { gem_model : string option
  ; gem_parts : Yojson.Safe.t list
  ; gem_finish_reason : gemini_terminal_reason option
  ; gem_usage : api_usage option
  }

type gemini_unsupported_part =
  | Gemini_executable_code
  | Gemini_code_execution_result
  | Gemini_tool_call
  | Gemini_tool_response
  | Gemini_function_response
  | Gemini_file_data
  | Gemini_audio_transcription
  | Gemini_streaming_function_call_arguments
  | Gemini_streaming_function_call_continuation

type gemini_unsupported_response = Gemini_multiple_candidates of { count : int }

type gemini_sse_parse_result =
  | Gemini_chunk of gemini_chunk
  | Gemini_provider_error of
      { message : string
      ; error_type : string option
      ; provider_status : Types.provider_status option
      ; report : Types.provider_report
      ; raw : string
      }
  | Gemini_unsupported_part of
      { part : gemini_unsupported_part
      ; raw : string
      }
  | Gemini_unsupported_response of
      { response : gemini_unsupported_response
      ; raw : string
      }
  | Gemini_parse_failed of
      { reason : string
      ; raw : string
      }

(** Parse one Gemini SSE data payload without collapsing malformed JSON or
    malformed candidate/part shapes into an absent chunk. A top-level [error]
    object is read first, as {!Openai_error_envelope.of_error_value} reads it
    (Gemini's [code]/[message] envelope is that same shape), and returned as
    [Gemini_provider_error] so a declared 429/5xx reaches retry classification
    instead of surfacing as a malformed payload. Official Part kinds
    that AGENT_CORE does not project are returned as [Gemini_unsupported_part], not
    relabelled as malformed bytes. Official response shapes that AGENT_CORE does not
    project are returned as [Gemini_unsupported_response]. Callers must surface
    either capability fact with the raw payload. *)
val parse_gemini_sse_chunk : string -> gemini_sse_parse_result

val gemini_unsupported_part_wire_name : gemini_unsupported_part -> string
val gemini_unsupported_response_wire_name : gemini_unsupported_response -> string

(** Check one element of a candidate's [parts] array: an object with only
    known fields and exactly one supported payload ([text], [functionCall]
    or [inlineData]) of the right JSON type. [position] is the element's
    index in the error path. {!parse_gemini_sse_chunk} applies it to every
    part that is not an unsupported kind, and a {!gemini_chunk} built outside
    the parser is checked with it again before it becomes events. *)
val validate_gemini_part : position:int -> Yojson.Safe.t -> (unit, string) result
