(** HTTP client for TypeSafe AI System One evaluation endpoint.
    Uses {!Masc_http_client.post_sync} for outbound keep-alive pooling. *)

val evaluate :
  ?endpoint:string ->
  ?model:string ->
  ?timeout_sec:float ->
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  api_key:string ->
  state:Yojson.Safe.t ->
  questions:(string * Typesafeai_types.question) list ->
  unit ->
  (Typesafeai_types.eval_response, string) result
(** [timeout_sec] bounds the whole request/response exchange and defaults to
    {!Masc_http_client.default_request_timeout_sec}, the deadline the other
    outbound clients share. *)
