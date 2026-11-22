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

(** Wire semantics of a reported Ollama/llama.cpp KV-cache token count relative
    to [prompt_eval_count]. *)
type kv_cache_semantics =
  | Exclusive_from_prompt_eval
    (** Reported cached prefix tokens were skipped during prompt evaluation and
        are excluded from [prompt_eval_count] (e.g. Ollama
        [prompt_eval_cached_count] and llama.cpp [cache_n] / [timings.cache_n]). *)
  | Inclusive_in_prompt_eval
    (** Reported cached prefix tokens are already included in
        [prompt_eval_count] (e.g. [prompt_tokens_details.cached_tokens]). *)

type kv_cache_read =
  { tokens : int
  ; semantics : kv_cache_semantics
  }

(** Extract non-negative KV-cache reuse telemetry from an Ollama or llama.cpp
    JSON response object. Returns [None] when no KV-cache field is present or
    when a field carries a negative/non-integer value. *)
val extract_kv_cache_read : Yojson.Safe.t -> kv_cache_read option

(** Normalize [(prompt_eval_count, kv_cache_read)] into
    [(inclusive_input_tokens, cache_read_input_tokens, reported_cache_read_opt)]
    matching {!Types.api_usage}'s inclusive [input_tokens] contract. *)
val resolve_prompt_tokens
  :  prompt_eval_count:int
  -> kv_cache_read:kv_cache_read option
  -> int * int * int option

(** Parse one NDJSON line without collapsing provider errors or malformed
    records into an absent chunk. The Ollama error envelope is a provider
    fact; missing or incorrectly typed data fields are wire failures. When a
    provider error object omits [message], [message] stays empty and the
    original payload remains available only through [raw]. *)
val parse_ollama_ndjson_chunk : string -> ollama_ndjson_parse_result
