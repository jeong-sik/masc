(** Ollama_stream — an Ollama chunk as stream events.

    {!Ollama_wire} reads each NDJSON line into an {!Ollama_wire.ollama_chunk}.
    This module converts that chunk into {!Types.sse_event}s. Block indices, tool
    identities and thinking state live in the shared {!Openai_stream_state}.

    The module is private to the library. Callers use
    {!Streaming.ollama_chunk_to_events}. *)

open Types

(** Documented on {!Streaming.ollama_chunk_to_events}. *)
val ollama_chunk_to_events
  :  Openai_stream_state.openai_stream_state
  -> Ollama_wire.ollama_chunk
  -> sse_event list * Telemetry_event.t option
