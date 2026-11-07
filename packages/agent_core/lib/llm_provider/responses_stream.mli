(** Responses_stream — an OpenAI Responses API payload as stream events.

    Responses streaming uses item-level event names:
    - [response.output_text.delta] for assistant text
    - [response.reasoning_summary_text.delta] / [response.reasoning_text.delta]
      for reasoning summaries/text
    - [response.output_item.added] + [response.function_call_arguments.delta]
      for function calls
    - [response.completed] / [response.incomplete] / [response.failed] for
      terminal status and usage.

    Keep this separate from {!Openai_wire.parse_openai_sse_chunk}: Responses has no
    [choices[].delta] envelope. Block indices, tool identities and thinking state
    live in the shared {!Openai_stream_state}.

    The module is private to the library. Callers use
    {!Streaming.responses_sse_to_events}. *)

open Types

(** Documented on {!Streaming.responses_sse_to_events}. *)
val responses_sse_to_events
  :  Openai_stream_state.openai_stream_state
  -> string option
  -> string
  -> sse_event list * Telemetry_event.t option
