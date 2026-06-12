(** Pure decision logic for trying provider candidates in order. *)

type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response
  | Call_err of Llm_provider.Http_client.http_error
  | Accept_rejected of {
      response : Llm_provider.Types.api_response;
      reason : string;
    }

type decision =
  | Accept of Llm_provider.Types.api_response
  | Accept_on_exhaustion of {
      response : Llm_provider.Types.api_response;
      reason : string;
    }
  | Try_next of { last_err : Llm_provider.Http_client.http_error option }
  | Exhausted of { last_err : Llm_provider.Http_client.http_error option }

val should_try_next : Llm_provider.Http_client.http_error -> bool

val decide :
  accept_on_exhaustion:bool ->
  is_last:bool ->
  provider_outcome ->
  decision

val decide_and_record :
  runtime_id:string ->
  accept_on_exhaustion:bool ->
  is_last:bool ->
  provider_outcome ->
  decision

val to_user_message : Llm_provider.Http_client.http_error option -> string



val provider_outcome_to_string : provider_outcome -> string

val provider_outcome_option_to_string : provider_outcome option -> string
