(** Abstract transport for LLM completions.

    Decouples the completion logic (cache, retry, request execution) from
    the underlying I/O mechanism (HTTP, subprocess, etc.).

    @since 0.78.0

    @stability Internal
    @since 0.93.1 *)

(** A completion request: everything needed to produce a response. *)
type completion_request =
  { config : Provider_config.t
  ; messages : Types.message list
  ; tools : Yojson.Safe.t list
  ; capture_id : string option
    (** Exact caller-owned request/run identity for raw wire observation.
        [None] never triggers identity inference. *)
  ; observe_http_status :
      (provider:string -> model_id:string -> status:int -> unit) option
    (** Optional caller-owned sink for the HTTP status an HTTP-backed
        transport actually observed. Set by the caller so a transport arm
        reports the same status the direct arm does, instead of the caller
        reconstructing one from the result — an accepted 200 that later
        becomes a typed wire failure is invisible to any such reconstruction.
        Non-HTTP transports leave it unused: they never saw an HTTP response,
        and inventing one would be a fabricated metric. *)
  ; observe_wire_chunk : Wire_observer.observe_chunk option
    (** Optional OAS-owned sink for raw provider chunks. A custom streaming
        transport that participates in wire observation calls this sink once
        for every raw provider chunk. The sink, rather than the transport,
        owns redaction, caller delivery, typed failure telemetry, and ordinary
        callback-exception isolation. The original caller callback is never
        exposed through the transport request. *)
  ; request_wire_observer : Request_wire_observer.try_observe option
    (** Optional caller-owned observer for pre-dispatch serialization evidence.
        Built-in HTTP transports invoke it exactly once after final body
        admission and before attempting dispatch. The observation does not
        prove that transport dispatch started or completed. Custom transports
        that do their own serialization must provide the same evidence boundary
        if they participate. *)
  ; stream_idle_timeout_s : float option
    (** Inter-chunk idle deadline for streaming reads, in seconds. Bounds the
        gap between streamed SSE/NDJSON lines, not total stream duration.
        [None] preserves pre-0.205.0 behaviour (no idle deadline). Armed only
        when the transport also holds a clock (closed over at construction).
        See RFC-OAS-026. @since 0.205.0 *)
  ; first_event_timeout_s : float option
    (** RFC-OAS-037: time-to-first-event (TTFT / prefill) deadline, in
        seconds, distinct from [stream_idle_timeout_s]. Bounds only the wait
        for the first streaming event; inter-token idle arms after it. [None]
        falls back to [body_timeout_s], then to [stream_idle_timeout_s] (the
        bound that applied before RFC-OAS-037); inter-token idle still guards
        once the stream produces. @since 0.218.0 *)
  ; body_timeout_s : float option
    (** RFC-OAS-037 §4.2: total body budget, in seconds. On the streaming path
        it is the fallback bound for the first-event (TTFT/prefill) wait when
        [first_event_timeout_s] is [None] — the common production shape, since
        callers wire [body_timeout_s] but not [first_event_timeout_s]. [None]
        leaves the first-event wait to [stream_idle_timeout_s], and unarmed if
        that is [None] too. Armed only when the transport also holds a clock.
        @since 0.218.0 *)
  }

(** Result of a sync completion. *)
type sync_result =
  { response : (Types.api_response, Http_client.http_error) result
  ; latency_ms : int option
  }

(** Result of a streaming completion. *)
type stream_result = (Types.api_response, Http_client.http_error) result

(** Transport interface.

    Both [complete_sync] and [complete_stream] handle the full
    request → I/O → response pipeline for their transport kind.

    - HTTP transport: build request body, POST, parse response
    - Subprocess transport: write stdin, read stdout, parse output *)
type t =
  { complete_sync : completion_request -> sync_result
  ; complete_stream :
      ?on_telemetry:(Telemetry_event.t -> unit)
      -> on_event:(Types.sse_event -> unit)
      -> completion_request
      -> stream_result
  }
