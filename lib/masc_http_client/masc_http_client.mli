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

val default_request_timeout_sec : float
(** Shared outbound HTTP request deadline used by connector delivery clients.
    This bounds the full request/response exchange, unlike the pool's separate
    connection-establishment timeout. *)
(** Structured response returned by {!get_response_sync}.  Body is
    fully read into memory; size capped at 8 MB
    (see {!post_sync} / {!get_response_sync} for the cap details). *)

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

(** {1 Typed pool surface}

    Re-exports [Pool] (lib/masc_http_client/pool.mli) so callers and
    tests can name the typed connection pool without reaching into
    the wrapped module path. Most callers should keep using
    [post_sync] / [get_sync] / [get_response_sync] which delegate
    through the per-domain [Pool.t] internally; direct
    [Pool.request] is reserved for code that needs typed responses
    with header maps or non-default config. *)
module Pool : module type of Pool

val pool_singleton_opt : unit -> Pool.t option
(** [pool_singleton_opt ()] returns some domain's [Pool.t] if any
    has been lazy-initialized by a prior HTTP call, [None] otherwise.
    Backward-compatible read-only accessor for telemetry consumers.
    For comprehensive metrics across all domains, use
    {!all_domain_pools} instead. *)

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
