(** Pure decision logic for trying provider candidates in order. *)

type provider_outcome = Call_err of Llm_provider.Http_client.http_error

(* The server-failure class is [Retry.server_status_class_of_code], the same
   classifier [Retry.classify_error] builds [ServerError] from and the failure
   route reads, so the walk and the route agree on which codes are a server
   failure. *)
let should_try_next = function
  | Llm_provider.Http_client.HttpError { code; _ } ->
    code = 408 || code = 409 || code = 429
    || Option.is_some (Llm_provider.Retry.server_status_class_of_code code)
  | Llm_provider.Http_client.NetworkError _
  | Llm_provider.Http_client.TimeoutError _
  | Llm_provider.Http_client.ProviderFailure _ ->
    true
  | Llm_provider.Http_client.AcceptRejected _
  | Llm_provider.Http_client.ProviderTerminal _ ->
    false
