(** Per-turn telemetry signals emitted by the OAS inference layer.

    Closed variant — every constructor has a defined consumer
    in the telemetry feedback loop. No catch-all matching.

    @since 0.43.0 *)

type timeout_type =
  | No_response
  | Ttft_exceeded
  | Non_streaming_body
  | Stream_body
  | Stream_idle of Http_client.stream_idle_state
  | Provider_step
  | Cli_stdout_idle
  | Unknown_timeout
[@@deriving yojson, show]

(* RFC-OAS-019 §4.1 — typed kind breakdown for [Streaming_summary].
   Counts of SSE-level deltas observed during a stream lifecycle, used
   by downstream operators to triage what a stream actually did without
   having to re-aggregate raw chunks. [done_] uses a trailing underscore
   because [done] is reserved (for loop syntax). *)
type streaming_kind_breakdown =
  { thinking : int
  ; answer : int
  ; tool_call_start : int
  ; tool_call_arg_delta : int
  ; tool_call_complete : int
  ; substrate : int
  ; heartbeat : int
  ; done_ : int
  }
[@@deriving yojson, show]

(* RFC-OAS-019 §4.4 — terminal classification for [Streaming_summary].
   Nominal variant rather than polymorphic — yojson serialisation is
   stable across compiler versions and ppx changes. *)
type streaming_terminal =
  | Terminal_done
  | Terminal_cancelled
  | Terminal_error of string
[@@deriving yojson, show]

type t =
  | Streaming_first_chunk of
      { provider : string
      ; model : string
      ; ttfrc_ms : float option
      ; requested_at : float
      }
  | Streaming_summary of
      { provider : string
      ; model : string
      ; chunk_count : int
      ; kind_breakdown : streaming_kind_breakdown
      ; ttft_ms : float option
      ; prefill_ms : float option
      ; total_ms : float option
      ; inter_chunk_ms_p50 : float option
      ; inter_chunk_ms_p95 : float option
      ; inter_chunk_ms_max : float option
      ; terminal : streaming_terminal
      }
  | Thinking_complete of
      { provider : string
      ; model : string
      ; thinking_duration_ms : float
      }
  | Timeout of
      { provider : string
      ; model : string
      ; timeout_type : timeout_type
      }
  | Prefill_complete of
      { provider : string
      ; model : string
      ; prompt_eval_tokens : int
      ; prompt_eval_ms : float
      ; cache_hit : bool
      }
  | Wire_observer_failure of Wire_observer.failure
[@@deriving yojson, show]

let event_type_name = function
  | Streaming_first_chunk _ -> "streaming_first_chunk"
  | Streaming_summary _ -> "streaming_summary"
  | Thinking_complete _ -> "thinking_complete"
  | Timeout _ -> "timeout"
  | Prefill_complete _ -> "prefill_complete"
  | Wire_observer_failure _ -> "wire_observer_failure"
;;
