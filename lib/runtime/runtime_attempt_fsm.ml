(** Pure decision logic for trying provider candidates in order. *)

type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response
  | Call_err of Llm_provider.Http_client.http_error
  | Accept_rejected of
      { response : Llm_provider.Types.api_response
      ; reason : string
      }

let to_user_message = function
  | Some (Llm_provider.Http_client.HttpError { code; body; _ }) ->
    Printf.sprintf
      "HTTP %d: %s"
      code
      (String_util.utf8_safe
         ~max_bytes:(Runtime_provider_defaults.max_error_body_length + 3)
         ~suffix:"..."
         body
       |> String_util.to_string)
  | Some (Llm_provider.Http_client.AcceptRejected { reason }) -> reason
  | Some (Llm_provider.Http_client.NetworkError { message; _ }) -> message
  | Some (Llm_provider.Http_client.TimeoutError { message; _ }) -> message
  | Some (Llm_provider.Http_client.ProviderTerminal { message; _ }) ->
    Printf.sprintf "provider terminal: %s" message
  | Some (Llm_provider.Http_client.ProviderFailure { kind; message }) ->
    Llm_provider.Http_client.provider_failure_to_string ~kind ~message
  | None -> "No providers available"

let provider_outcome_to_string = function
  | Call_ok _ -> "call-ok"
  | Call_err _ -> "call-err"
  | Accept_rejected _ -> "accept-rejected"

let provider_outcome_option_to_string = function
  | Some outcome -> "some-" ^ provider_outcome_to_string outcome
  | None -> "none"
