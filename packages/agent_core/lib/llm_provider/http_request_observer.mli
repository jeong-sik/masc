(** Caller-owned observation of native HTTP POST calls. No URL, headers,
    credentials, request content or response content crosses this interface.
    A call identity belongs to the observer captured when that call entered;
    nested observers and inherited concurrent fibers cannot rebind it.

    Body size/hash describe the bytes submitted to the HTTP client, not bytes
    acknowledged by a peer. Dispatch entry, response headers and client return
    are distinct facts. A successful client return is not a provider/parser or
    business-success verdict. Callbacks run synchronously and must stay bounded.
    Unbound calls do no body hashing or recording. No observation changes
    admission or retry policy. *)

type mode = Synchronous | Streaming
type completion = Returned_ok | Returned_error | Cancelled | Raised
type phase =
  | Client_entered of { mode : mode; body_bytes : int; body_sha256 : string }
  | Dispatch_entered
  | Response_headers_received of { status : int }
  | Client_finished of completion

type event = { call_id : int; phase : phase }
type t
type call

val create : (event -> (unit, unit) result) -> t
val with_observer : t -> (unit -> 'a) -> 'a
val delivery_failure_count : t -> int
(** Rejected callbacks and ordinary callback exceptions are counted and do not
    rewrite a client result. Reserved exceptions, including cancellation, escape.
    A consumer with missing events must retain unknown aggregate metrics. *)

val with_call :
  mode:mode -> body:string -> (call option -> ('a, 'error) result) -> ('a, 'error) result
val dispatch_entered : call option -> unit
val response_headers_received : call option -> status:int -> unit
