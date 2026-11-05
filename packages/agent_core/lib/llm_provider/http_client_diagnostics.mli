(** Diagnostics for requests that a provider edge rejects without saying why.
    A 4xx answer with no readable cause leaves the request as the only
    evidence, so this module logs the request's shape. *)

val profile_opaque_client_error
  :  url:string
  -> code:int
  -> resp_headers:Http.Header.t
  -> request_headers:(string * string) list
  -> request_body:string
  -> response_body:string
  -> unit
(** Logs one WARN line for a 4xx whose [response_body] names no cause: the
    status, the response [server] and [cf-ray] headers, the request header
    sizes, and the structure of the request body. Header values and message or
    tool-argument text are never logged, because they may carry credentials or
    user content. Does nothing for other statuses and for bodies that name
    their cause, since the body is the diagnosis then. *)
