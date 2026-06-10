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
  | Try_next of
      { last_err : Llm_provider.Http_client.http_error option
      ; source : string option
      }
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
    else Try_next { last_err = Some (Llm_provider.Http_client.AcceptRejected { reason }); source = None }
  | Call_err err ->
    if (not is_last) && should_try_next err
    then Try_next { last_err = Some err; source = None }
    else Exhausted { last_err = Some err }

let decide_and_record ~runtime_id ~source ~accept_on_exhaustion ~is_last ?(log_warn = Log.Runtime.warn) outcome =
  let d = decide ~accept_on_exhaustion ~is_last outcome in
  (match d with
   | Try_next { last_err; _ } ->
     log_warn "try_next decision runtime_id=%s source=%s last_err=%s"
       runtime_id
       (match source with None -> "none" | Some s -> s)
       (match last_err with None -> "none" | Some _ -> "set")
   | Exhausted { last_err } ->
     log_warn "exhausted runtime_id=%s last_err=%s"
       runtime_id
       (match last_err with None -> "none" | Some _ -> "set")
   | Accept _ | Accept_on_exhaustion _ -> ());
  d

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

let format_exhausted_error last_err =
  let message = to_user_message last_err in
  let kind =
    match last_err with
    | Some (Llm_provider.Http_client.NetworkError { kind; _ }) -> kind
    | Some (Llm_provider.Http_client.TimeoutError _) -> Llm_provider.Http_client.Timeout
    | _ -> Llm_provider.Http_client.Unknown
  in
  match last_err with
  | Some (Llm_provider.Http_client.AcceptRejected _ as err) -> err
  | _ ->
    Llm_provider.Http_client.NetworkError
      { message = Printf.sprintf "All providers failed: %s" message; kind }

let provider_outcome_to_string = function
  | Call_ok _ -> "call-ok"
  | Call_err _ -> "call-err"
  | Accept_rejected _ -> "accept-rejected"

let provider_outcome_option_to_string = function
  | Some outcome -> "some-" ^ provider_outcome_to_string outcome
  | None -> "none"
