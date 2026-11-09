(** Openai_wire — reader for one OpenAI-compatible [chat/completions] SSE data
    payload.

    Each payload is a JSON object shaped like
    [{id, model, choices: [{delta: {content, tool_calls, ...}, finish_reason}]}],
    and a chunk can carry text, reasoning, a refusal flag or tool-call deltas.
    Nothing here keeps state between chunks: {!Streaming.openai_chunk_to_events}
    turns the chunks into stream events. The Ollama reader, {!Ollama_wire},
    builds its tool-call deltas from {!tool_call_arguments} too.

    Pure module: no I/O, no env reads. *)

open Types

(** Wire shape of streamed tool-call arguments. [Args_fragment] is an incremental
    string chunk the accumulator appends; [Args_complete] is a whole JSON-value
    snapshot serialized in a single delta, which replaces the block buffer so a
    re-emitted snapshot does not concatenate into invalid JSON. Each codec and
    the completed ToolUse boundary validate the value shape they allow. *)
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
      (** The nullable [delta.refusal] field declared a refusal. Private refusal
          text is not emitted as answer text; the request retains the signal
          until its actual terminal event. *)
  ; delta_reasoning : string option
  ; delta_reasoning_details : openai_reasoning_details_delta option
  ; delta_tool_calls : openai_tool_call_delta list
  ; finish_reason : string option
  ; chunk_usage : delta_usage option
  ; chunk_timings : inference_timings option
    (** Top-level [timings] object llama-server attaches to the final SSE
        chunk (the one carrying [finish_reason]) without opt-in. Includes
        [cache_n], the prompt tokens reused from the slot KV cache. Cloud
        OpenAI-compatible providers do not send it. *)
  }

(** Closed classification of one OpenAI-compatible SSE data payload. Parsing
    never collapses malformed data into an absent chunk: callers must handle a
    terminal sentinel, an intentional empty chunk, a provider error, or a
    protocol parse failure explicitly. *)
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
      (** The catalog row declared reasoning on [delta.<declared>], and the
          chunk carried non-blank reasoning under the other documented
          member instead while the declared one was absent or blank. The
          parser reads only the declared member, so this is a misdeclared
          row surfacing as a typed observation; [raw] is the chunk that
          exposed it. *)

(** The literal SSE payload (the bare token after [data: ]) that ends an
    OpenAI-compatible stream. It is not a JSON object: {!parse_openai_sse_chunk}
    answers it with {!Openai_done}, and the Responses reader in {!Streaming}
    compares against it too. *)
val openai_done_sentinel : string

val parse_openai_sse_chunk
  :  streaming_reasoning:Reasoning_dialect.streaming_reasoning
  -> string
  -> openai_sse_parse_result
(** [streaming_reasoning] is the catalog row's declaration of where readable
    reasoning arrives on a chat delta; it is the only member the parser
    reads. There is no undeclared default: a caller without a resolved
    dialect passes {!Reasoning_dialect.No_streaming_reasoning} and gets no
    reasoning. *)
