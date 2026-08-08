(** Typed telemetry events for the OAS inference layer. *)

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
        (** RFC-OAS-020: milliseconds from request submission to the
            first parsed chunk that carried a non-empty user-visible
            delta (text, reasoning, or tool-call). Distinct from
            [ttfrc_ms] on [Streaming_first_chunk] which fires on the
            first chunk regardless of payload. [None] when the
            completion never delivered a non-empty delta or elapsed
            latency was unavailable. *)
      ; prefill_ms : float option
        (** RFC-OAS-020: milliseconds from request submission to the
            first SSE event of any kind. [Some] when the provider
            exposes a separable prefill marker
            (e.g. Anthropic [MessageStart] arrives before the first
            [ContentBlockDelta]); [None] for providers that do not
            (e.g. OpenAI-compat first chunk is a content delta). *)
      ; total_ms : float option
        (** Monotonic elapsed milliseconds for the full stream. [None]
            when the monotonic latency counter was unavailable. *)
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

(** Human-readable event type label for metrics and logging. *)
val event_type_name : t -> string
