(** Openai_stream — an OpenAI-compatible chunk as stream events.

    Chat Completions streaming uses SSE with flat deltas:
    - Text content arrives as [delta.content] strings
    - Tool calls arrive as [delta.tool_calls] with incremental arguments
    - [finish_reason] signals end of a choice
    - No explicit content_block_start/stop events (unlike Anthropic)

    {!Openai_wire} reads each SSE chunk into an {!Openai_wire.openai_chunk}.
    This module converts it to a {!Types.sse_event} list using a stateful
    adapter ({!Openai_stream_state.openai_stream_state}).

    The module is private to the library. Callers use
    {!Streaming.openai_chunk_to_events} and
    {!Streaming.openai_sse_parse_result_to_events}. *)

open Types

(** Documented on {!Streaming.openai_chunk_to_events}. *)
val openai_chunk_to_events
  :  Openai_stream_state.openai_stream_state
  -> Openai_wire.openai_chunk
  -> sse_event list * Telemetry_event.t option

(** Documented on {!Streaming.openai_sse_parse_result_to_events}. *)
val openai_sse_parse_result_to_events
  :  Openai_stream_state.openai_stream_state
  -> Openai_wire.openai_sse_parse_result
  -> sse_event list * Telemetry_event.t option
