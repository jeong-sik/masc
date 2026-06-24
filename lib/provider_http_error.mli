(** Single source of truth for rendering an
    [Llm_provider.Http_client.http_error] to a human-readable message,
    shared by the tool runtime and keeper runtime consumers. *)

val to_message : Llm_provider.Http_client.http_error -> string
(** One-line human-readable message for an HTTP/provider error. HTTP
    bodies are truncated to 200 bytes with a trailing ellipsis. *)
