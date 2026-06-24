(** Single source of truth for rendering an
    [Llm_provider.Http_client.http_error] to a one-line human-readable
    message.

    Four MASC consumers (tool verify/bench runtimes, keeper
    librarian/memory-summary runtimes) previously each kept a
    byte-for-output-identical copy of this match; the copies had begun to
    drift in incidental detail (one discarded the [ProviderTerminal.kind]
    field, the others bound it unused). Centralising removes the drift
    surface. *)

let to_message (err : Llm_provider.Http_client.http_error) : string =
  match err with
  | Llm_provider.Http_client.NetworkError { message; _ } -> message
  | Llm_provider.Http_client.TimeoutError { message; phase } ->
      Printf.sprintf "provider timeout: %s: %s"
        (Llm_provider.Http_client.timeout_phase_to_label phase) message
  | Llm_provider.Http_client.AcceptRejected { reason } -> reason
  | Llm_provider.Http_client.ProviderTerminal { kind = _; message } ->
      Printf.sprintf "provider terminal: %s" message
  | Llm_provider.Http_client.ProviderFailure { kind; message } ->
      Llm_provider.Http_client.provider_failure_to_string ~kind ~message
  | Llm_provider.Http_client.HttpError { code; body } ->
      Printf.sprintf "HTTP %d: %s" code
        (if String.length body > 200 then String.sub body 0 200 ^ "..." else body)
