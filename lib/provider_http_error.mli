(** Single source of truth for rendering an
    [Llm_provider.Http_client.http_error] to a human-readable message,
    shared by the tool runtime and keeper runtime consumers. *)

val max_body_length : int
(** Maximum number of bytes kept from an HTTP error body before truncation. *)

val body_truncation_suffix : string
(** Suffix appended to an HTTP error body that has been truncated. *)

val to_message : Llm_provider.Http_client.http_error -> string
(** One-line human-readable message for an HTTP/provider error. HTTP
    bodies are truncated to {!max_body_length} bytes with a trailing
    {!body_truncation_suffix}. *)
