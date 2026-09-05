(** Masc_http_client — typed pool front-end for outbound HTTP.

    Every public entry point delegates to a per-domain
    {!Pool.t} (lib/masc_http_client/pool.mli), which owns the
    underlying piaf transport, keep-alive, and TLS context cache.
    Each OCaml Domain (OS thread) gets its own pool instance with
    its own [Eio.Switch], eliminating cross-domain Switch access
    errors.  Callers should reach for [post_sync] / [get_sync] /
    [get_response_sync] for plain status+body access, or import
    {!Pool} directly when they need typed response headers or
    non-default pool configuration. *)

(** {1 Response payload} *)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}
(** Structured response returned by {!get_response_sync}. Body is
    fully read into memory; size capped at 8 MB
    (see {!post_sync} / {!get_response_sync} for the cap details). *)

val default_request_timeout_sec : float
(** Shared outbound HTTP request deadline used by connector delivery clients.
    This bounds the full request/response exchange, unlike the pool's separate
    connection-establishment timeout. *)

(** {1 Synchronous request helpers}

    All three helpers:
    - Acquire a connection from the per-process {!Pool.t}; keep-alive
      lets repeated requests against the same host reuse the same TCP+TLS
      session.  Connection cleanup is owned by the pool's idle-eviction
      fiber, not the caller switch.
    - Cap the response body at 8 MB; oversize bodies surface
      [Error "masc_http_client: body size exceeds 8 MB"].
    - Convert {!Eio.Cancel.Cancelled} re-raises (cancellation
      propagates); wrap any other exception as
      [Error (Printexc.to_string exn)].
    - When [?clock] {b and} [?timeout_sec > 0.0] are both supplied,
      race the request against an {!Eio.Time.sleep} fiber.  On
      timeout, return [Error "timeout after %.1fs"]. *)

val post_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  url:string ->
  headers:(string * string) list ->
  body:string ->
  unit ->
  ((int * string), string) result
(** [post_sync ?clock ?timeout_sec ~url ~headers ~body ()] performs
    a [POST url] with [Content-Type] honored from [headers].
    Returns [Ok (status_code, body_string)] on success.
    Connection-level errors (DNS, TLS, I/O) are caught and surfaced
    as [Error _] rather than propagating as exceptions. *)

val post_response_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  url:string ->
  headers:(string * string) list ->
  body:string ->
  unit ->
  (response, string) result
(** [post_response_sync] is {!post_sync} with the response headers kept,
    for a caller that needs one of them -- the MCP transport returns a new
    session's id in [Mcp-Session-Id], not in the body. *)

val patch_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  url:string ->
  headers:(string * string) list ->
  body:string ->
  unit ->
  ((int * string), string) result
(** [patch_sync ?clock ?timeout_sec ~url ~headers ~body ()] performs
    a [PATCH url].  Same error handling as {!post_sync}. *)

val get_response_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  url:string ->
  headers:(string * string) list ->
  unit ->
  (response, string) result
(** [get_response_sync ?clock ?timeout_sec ~url ~headers ()] performs
    a [GET url].  Returns [Ok response] with full status / headers /
    body for callers that need to inspect response headers (e.g.
    link-preview redirect handling). *)

val get_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  url:string ->
  headers:(string * string) list ->
  unit ->
  ((int * string), string) result
(** [get_sync] is {!get_response_sync} with the response headers
    discarded — returns [Ok (status_code, body_string)] for callers
    that only care about status + body. *)

val post_stream :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  idle_timeout_sec:float ->
  url:string ->
  headers:(string * string) list ->
  body:string ->
  on_chunk:(string -> unit) ->
  unit ->
  (Pool.stream_outcome, string) result
(** [post_stream ~clock ~idle_timeout_sec ~url ~headers ~body ~on_chunk ()]
    POSTs and calls [on_chunk] with each response body chunk as it arrives,
    for callers rendering a live view of a server-sent event stream.

    On the [Streamed] branch the complete body is returned as well, so a
    caller can render from the chunks and still run an authoritative
    whole-body decode at the end. On a non-success status the body comes back
    as [Buffered] and [on_chunk] is never called — see {!Pool.stream_outcome}.

    There is no wall-clock cap: one would cancel a stream that is still
    delivering bytes. [idle_timeout_sec] bounds silence instead, and is
    required because a tolerable silence depends on the protocol — a keeper
    turn goes quiet for as long as the tool it is running takes. *)

val get_stream :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  idle_timeout_sec:float ->
  url:string ->
  headers:(string * string) list ->
  on_chunk:(string -> unit) ->
  unit ->
  (Pool.stream_outcome, string) result
(** [get_stream ~clock ~idle_timeout_sec ~url ~headers ~on_chunk ()] is
    {!post_stream} for a GET: one request whose body is a server-sent event
    stream the caller reads chunk by chunk for as long as it delivers. The
    observer feed at [GET /mcp?sse_kind=observer] is the case. The same
    rules apply: no total cap, silence bounded by [idle_timeout_sec], a
    non-success status comes back [Buffered] with [on_chunk] never called. *)

(** {1 Typed pool surface}

    Re-exports [Pool] (lib/masc_http_client/pool.mli) so callers and
    tests can name the typed connection pool without reaching into
    the wrapped module path. Most callers should keep using
    [post_sync] / [get_sync] / [get_response_sync] which delegate
    through the per-domain [Pool.t] internally; direct
    [Pool.request] is reserved for code that needs typed responses
    with header maps or non-default config. *)
module Pool : module type of Pool

(** {1 WWW-Authenticate}

    Re-exports [Www_authenticate] (lib/masc_http_client/www_authenticate.mli):
    a 401's challenges read by the RFC 9110 grammar, for the callers that
    act on what such an answer names. *)
module Www_authenticate : module type of Www_authenticate

val all_domain_pools : unit -> (int * Pool.t) list
(** [all_domain_pools ()] returns all domain-local pools as
    [(domain_id, pool)] pairs.  Used by [Pool_metrics] to aggregate
    counters across all OCaml Domains.  Thread-safe; acquires an
    internal [Stdlib.Mutex] for the duration of the snapshot. *)

module For_testing : sig
  val with_request_timeout :
    clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
    timeout_sec:float ->
    (unit -> ('a, string) result) ->
    ('a, string) result
  (** Transport-independent proof seam for the exact deadline race used by
      [post_sync]/[patch_sync]. *)
end
