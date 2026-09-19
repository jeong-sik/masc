(** HTTP client for TypeSafe AI System One evaluation endpoint.
    Uses {!Masc_http_client.post_sync} for outbound keep-alive pooling. *)

type evaluated =
  { response : Typesafeai_types.eval_response
  ; destination_uri : string
  ; request_body_sha256 : string
  }
(** A decoded response together with the identity of the exact outbound
    request bytes that produced it. *)

val evaluate :
  ?endpoint:string ->
  ?model:string ->
  ?timeout_sec:float ->
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  api_key:string ->
  state:Yojson.Safe.t ->
  questions:(string * Typesafeai_types.question) list ->
  unit ->
  (evaluated, string) result
(** [timeout_sec] bounds the whole request/response exchange and defaults to
    {!Masc_http_client.default_request_timeout_sec}, the deadline the other
    outbound clients share. *)
