(** HTTP client for TypeSafe AI System One evaluation endpoint.
    Uses {!Masc_http_client.post_sync} for outbound keep-alive pooling. *)

type evaluated =
  { response : Typesafeai_types.eval_response
  ; destination_uri : string
  ; request_body_sha256 : string
  }
(** A decoded response together with the identity of the exact outbound
    request bytes that produced it. [destination_uri] is an observation URL:
    userinfo, query and fragment are removed; the outbound URL is unchanged. *)

type failure =
  | Transport_failure of string
  | Http_response_failure of
      { status : int
      ; body : string
      ; detail : string
      }
(** A transport diagnostic, or the response the server actually
    returned. [body] remains a string even when it is invalid JSON.
    Response content is private evidence, not guaranteed free of secrets
    that the remote server chose to echo. *)

val endpoint_for_observation : string -> string
val failure_to_string : failure -> string
val failure_to_yojson : failure -> Yojson.Safe.t

val evaluate :
  ?endpoint:string ->
  ?model:string ->
  ?timeout_sec:float ->
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  api_key:string ->
  state:Yojson.Safe.t ->
  questions:(string * Typesafeai_types.question) list ->
  unit ->
  (evaluated, failure) result
(** [timeout_sec] bounds the whole request/response exchange and defaults to
    {!Masc_http_client.default_request_timeout_sec}, the deadline the other
    outbound clients share. *)

module For_testing : sig
  val transport_failure : endpoint:string -> api_key:string -> string -> failure
end
