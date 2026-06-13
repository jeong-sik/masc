(** Pure decision logic for trying provider candidates in order. *)

type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response
  | Call_err of Llm_provider.Http_client.http_error
  | Accept_rejected of
      { response : Llm_provider.Types.api_response
      ; reason : string
      }

type decision =
  | Accept of Llm_provider.Types.api_response
  | Accept_on_exhaustion of
      { response : Llm_provider.Types.api_response
      ; reason : string
      }
  | Try_next of { last_err : Llm_provider.Http_client.http_error option }
  | Exhausted of { last_err : Llm_provider.Http_client.http_error option }

let should_try_next = function
  | Llm_provider.Http_client.HttpError { code; _ } -> code = 408 || code = 409 || code = 429 || code >= 500
  | Llm_provider.Http_client.NetworkError _
  | Llm_provider.Http_client.TimeoutError _
  | Llm_provider.Http_client.ProviderFailure _ ->
    true
  | Llm_provider.Http_client.AcceptRejected _
  | Llm_provider.Http_client.ProviderTerminal _ ->
    false

let decide ~accept_on_exhaustion ~is_last = function
  | Call_ok response -> Accept response
  | Accept_rejected { response; reason } ->
    if is_last && accept_on_exhaustion
    then Accept_on_exhaustion { response; reason }
    else if is_last
    then Exhausted { last_err = Some (Llm_provider.Http_client.AcceptRejected { reason }) }
    else Try_next { last_err = Some (Llm_provider.Http_client.AcceptRejected { reason }) }
  | Call_err err ->
    if (not is_last) && should_try_next err
    then Try_next { last_err = Some err }
    else Exhausted { last_err = Some err }

let decide_and_record ~runtime_id:_ ~accept_on_exhaustion ~is_last outcome =
  decide ~accept_on_exhaustion ~is_last outcome

let to_user_message = function
  | Some (Llm_provider.Http_client.HttpError { code; body }) ->
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
