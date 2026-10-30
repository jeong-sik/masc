(** Pure decision logic for trying provider candidates in order. *)

type provider_outcome = Call_err of Llm_provider.Http_client.http_error

val should_try_next : Llm_provider.Http_client.http_error -> bool
