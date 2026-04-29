(** Masc_http_client — cohttp-eio wrapper with explicit socket close.

    cohttp-eio 6.1.1 does not reliably close the underlying TCP
    socket fd when the {!Eio.Switch} exits (observed on macOS).
    This module intercepts the connection factory via
    [Cohttp_eio.Client.make_generic] to capture the raw socket and
    close it explicitly on switch release.

    All MASC code that makes outbound HTTP requests should use this
    module instead of {!Cohttp_eio.Client.make} directly.  See
    {{:https://github.com/jeong-sik/masc-mcp/issues/3221} #3221}.

    Internal helper {!with_optional_timeout} stays private — every
    public entry point exposes [?clock ?timeout_sec] directly so
    callers do not see the timeout-fiber-race scaffolding. *)

(** {1 Connection factory} *)

val make_closing_client :
  sw:Eio.Switch.t ->
  net:[> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  https:
    (Uri.t ->
     [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
     [> `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
    option ->
  Cohttp_eio.Client.t
(** [make_closing_client ~sw ~net ~https] builds a
    {!Cohttp_eio.Client.t} that:

    + Resolves the URI hostname via {!Eio.Net.getaddrinfo_stream}
      (raises [Invalid_argument] when no result).
    + Connects raw via {!Eio.Net.connect}.
    + For [https://] URIs, calls [https = Some wrap] with [(uri,
      sock)] to layer TLS; raises [Invalid_argument] when [https =
      None] but the URI is HTTPS.
    + Tracks every connection in an internal flow list and registers
      an {!Eio.Switch.on_release} hook to close all flows when the
      switch exits.

    The polymorphic [net] / [https] arguments accept any
    Eio.Net.t-compatible resource and any TLS wrapper that returns
    a flow-shaped resource — kept abstract so callers can plug in
    their own TLS stack. *)

(** {1 Response payload} *)

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}
(** Structured response returned by {!get_response_sync}.  Body is
    fully read into memory; size capped at 8 MB
    (see {!post_sync} / {!get_response_sync} for the cap details). *)

(** {1 Synchronous request helpers}

    All three helpers:
    - Run inside {!Eio.Switch.run}, so connection cleanup is
      guaranteed regardless of success or exception.
    - Add [Connection: close] to the request headers so the
      cohttp-eio reader stops at end-of-stream.
    - Cap the response body at 8 MB; oversize bodies surface
      [Error "masc_http_client: body size exceeds 8 MB"].
    - Convert [Eio.Cancel.Cancelled] re-raises (cancellation
      propagates), wrap any other exception as
      [Error (Printexc.to_string exn)].
    - When [?clock] {b and} [?timeout_sec > 0.0] are both supplied,
      race the request against an {!Eio.Time.sleep} fiber.  On
      timeout, return [Error "timeout after %.1fs"]. *)

val post_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  net:[> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  ?https:
    (Uri.t ->
     [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
     [> `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
    option ->
  url:string ->
  headers:(string * string) list ->
  body:string ->
  unit ->
  ((int * string), string) result
(** [post_sync ?clock ?timeout_sec ~net ?https ~url ~headers ~body
      ()] performs a [POST url] with [Content-Type] honored from
    [headers].  Returns [Ok (status_code, body_string)] on success.
    Connection-level errors (DNS, TLS, I/O) are caught and surfaced
    as [Error _] rather than propagating as exceptions. *)

val get_response_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  net:[> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  ?https:
    (Uri.t ->
     [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
     [> `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
    option ->
  url:string ->
  headers:(string * string) list ->
  unit ->
  (response, string) result
(** [get_response_sync ?clock ?timeout_sec ~net ?https ~url
      ~headers ()] performs a [GET url].  Returns [Ok response] with
    full status / headers / body for callers that need to inspect
    response headers (e.g. link-preview redirect handling). *)

val get_sync :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  net:[> `Network | `Platform of [> `Generic ] ] Eio.Resource.t ->
  ?https:
    (Uri.t ->
     [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
     [> `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t)
    option ->
  url:string ->
  headers:(string * string) list ->
  unit ->
  ((int * string), string) result
(** [get_sync] is {!get_response_sync} with the response headers
    discarded — returns [Ok (status_code, body_string)] for callers
    that only care about status + body. *)
