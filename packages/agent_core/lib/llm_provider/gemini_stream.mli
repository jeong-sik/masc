(** Gemini_stream — a Gemini chunk as stream events.

    {!Gemini_wire} reads one payload into a {!Gemini_wire.gemini_chunk}. This
    module turns that chunk into {!Types.sse_event}s and keeps the block state
    in {!Openai_stream_state}.

    The module is private to the library. Callers use
    {!Streaming.gemini_chunk_to_events}. *)

open Types

type gemini_chunk_to_events_error = { reason : string }

(** Documented on {!Streaming.gemini_chunk_to_events}. *)
val gemini_chunk_to_events
  :  Openai_stream_state.openai_stream_state
  -> Gemini_wire.gemini_chunk
  -> (sse_event list * Telemetry_event.t option, gemini_chunk_to_events_error) result
