(** Ollama_wire — reader for one Ollama [/api/chat] NDJSON line.

    With [stream:true] Ollama emits one JSON object per line. Non-final lines
    carry a [message.content] delta; the final line has [done:true] together
    with [done_reason] and the four timing fields ([prompt_eval_count] /
    [prompt_eval_duration] / [eval_count] / [eval_duration]) that the Openai
    compat path on [/v1/chat/completions] strips out. Nothing here keeps state
    between lines: {!Streaming.ollama_chunk_to_events} turns the chunks into
    stream events. Tool-call arguments use {!Openai_wire.tool_call_arguments},
    the same two wire shapes the OpenAI reader produces.

    Pure module: no I/O, no env reads. *)

open Types

type ollama_tool_call_delta =
  { oll_tc_index : int
  ; oll_tc_id : string option
  ; oll_tc_name : string option
  ; oll_tc_arguments : Openai_wire.tool_call_arguments option
    (** Tool-call arguments as they arrive on the wire. *)
  }

type ollama_chunk =
  { oll_model : string
  ; oll_delta_content : string option
  ; oll_delta_thinking : string option
  ; oll_tool_calls : ollama_tool_call_delta list
  ; oll_done_reason : string option
  ; oll_is_done : bool
  ; oll_usage : api_usage option
  ; oll_timings : inference_timings option
  }

type ollama_ndjson_parse_result =
  | Ollama_chunk of ollama_chunk
  | Ollama_provider_error of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | Ollama_parse_failed of
      { reason : string
      ; raw : string
      }

(** Parse one NDJSON line without collapsing provider errors or malformed
    records into an absent chunk. The Ollama error envelope is a provider
    fact; missing or incorrectly typed data fields are wire failures. When a
    provider error object omits [message], [message] stays empty and the
    original payload remains available only through [raw]. *)
val parse_ollama_ndjson_chunk : string -> ollama_ndjson_parse_result
