(** Terminal telemetry label for a provider-owned error envelope. Distinct
    from a wire failure: the response was structurally valid. *)
val provider_reported_terminal_label : string

(** Terminal telemetry label for a provider capability that OAS does not
    project. This is distinct from a malformed or unknown wire payload. *)
val capability_mismatch_terminal_label : string

(** Terminal telemetry label for a wire-contract failure in the given format.
    Derived from the same format value as the returned typed error, so the
    published summary cannot name a different wire format than the failure. *)
val wire_error_terminal_label : Http_client.provider_wire_format -> string

(** One payload unit (a joined SSE event, or a single line) exceeded the byte
    limit the reader was armed with. *)
val http_error_of_oversized_payload
  :  wire_format:Http_client.provider_wire_format
  -> actual_bytes:int option
  -> limit_bytes:int
  -> Http_client.http_error

val http_error_of_stream_error
  :  ?wire_format:Http_client.provider_wire_format
  -> Types.stream_error
  -> Http_client.http_error
