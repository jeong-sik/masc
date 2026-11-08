(** Redirect a request that names a loopback alias to the canonical loopback
    host.

    [Server_route] runs it in front of the public read of the dashboard pages,
    and [Server_routes_http_routes_frontend] uses the same helpers for the root
    redirect and exposes them to its tests. *)

val respond_redirect : location:string -> Http_reqd.t -> unit
(** A 302 to [location] with an empty body. *)

val authority_scheme : Server_request_authority.authority -> string
(** ["http"] or ["https"]: the admitted authority's scheme, so a redirect
    issued on the TLS listener stays on https. *)

val canonical_loopback_location
  :  request_authority:Server_request_authority.authority
  -> Httpun.Request.t
  -> string option
(** [Some redirect_url] when the admitted authority advertises a non-canonical
    loopback host that should redirect, [None] when it already matches the
    canonical advertisement. The redirect keeps the admitted authority's
    scheme and its port, or the scheme default when the request named none. *)

val with_canonical_loopback_host
  :  (Httpun.Request.t -> Http_reqd.t -> unit)
  -> Httpun.Request.t
  -> Http_reqd.t
  -> unit
(** Redirects when {!canonical_loopback_location} answers, and runs the handler
    otherwise. It reads the request authority bound to the current fiber, so it
    must run inside a request. *)
