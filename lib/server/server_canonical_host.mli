(** Redirect a request that names a loopback alias to the canonical loopback
    host.

    [Server_route] runs it in front of the public read of the dashboard pages,
    and [Server_routes_http_routes_frontend] uses the same helpers for the root
    redirect and exposes them to its tests. *)

val respond_redirect : location:string -> Httpun.Reqd.t -> unit
(** A 302 to [location] with an empty body. *)

val authority_host_port
  :  default_port:int
  -> Server_request_authority.authority
  -> string * int
(** The host of the admitted authority, and its port or [default_port]. *)

val canonical_loopback_location
  :  default_port:int
  -> request_authority:Server_request_authority.authority
  -> Httpun.Request.t
  -> string option
(** [Some redirect_url] when the admitted authority advertises a non-canonical
    loopback host that should redirect, [None] when it already matches the
    canonical advertisement. *)

val with_canonical_loopback_host
  :  port:int
  -> (Httpun.Request.t -> Httpun.Reqd.t -> unit)
  -> Httpun.Request.t
  -> Httpun.Reqd.t
  -> unit
(** Redirects when {!canonical_loopback_location} answers, and runs the handler
    otherwise. It reads the request authority bound to the current fiber, so it
    must run inside a request. *)
