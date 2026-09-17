(** Terminal telemetry label for a provider-owned error envelope. Distinct
    from a wire failure: the response was structurally valid. *)
val provider_reported_terminal_label : string

(** Terminal telemetry label for a provider capability that AGENT_CORE does not
    project. This is distinct from a malformed or unknown wire payload. *)
val capability_mismatch_terminal_label : string

(** Terminal telemetry label for a wire-contract failure in the given format.
    Derived from the same format value as the returned typed error, so the
    published summary cannot name a different wire format than the failure. *)
val wire_error_terminal_label : Http_client.provider_wire_format -> string

(** Terminal telemetry label for an [http_error] the stream returns when no
    stream event named the failure first, e.g. ["sse_stream_error: HTTP 502"].
    A provider condition declared inside the stream (429 or 5xx) is returned as
    [HttpError] by {!http_error_of_stream_error}, so its summary takes this
    label from the returned error instead of {!provider_reported_terminal_label}. *)
val returned_error_terminal_label
  :  Http_client.provider_wire_format
  -> Http_client.http_error
  -> string

(** One payload unit (a joined SSE event, or a single line) exceeded the byte
    limit the reader was armed with. *)
val http_error_of_oversized_payload
  :  wire_format:Http_client.provider_wire_format
  -> actual_bytes:int option
  -> limit_bytes:int
  -> Http_client.http_error

(** The typed error a stream failure is returned as. A provider envelope that
    declares a provider condition ([Types.provider_status]: 429 or 5xx) is
    [HttpError] with that status and only the error object as its body, so it
    is classified as the same status line before the stream would be; any other
    envelope is [ProviderFailure Provider_reported_error]. *)
val http_error_of_stream_error
  :  ?wire_format:Http_client.provider_wire_format
  -> Types.stream_error
  -> Http_client.http_error
