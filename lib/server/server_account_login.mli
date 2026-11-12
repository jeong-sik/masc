(* HIGH-RISK-UNREVIEWED: builds the clients that log a person in. A client
   holds the secret a login provider gave this installation. *)

(** What the login routes of a multi-account installation share
    ({!Login_routes.t}), made once for a zone (plan S1a-3).

    The account server makes it at boot from the login clients of the
    [config.json] that the boot judged, and the localhost preview makes it
    from the loopback client of its command line. Both go through {!routes},
    so the seal of a login in flight, the transport to a provider, the wall
    clock and the random source of the two are made the same way. *)

type refusal =
  | Google_client_refused of Login_client.environment_error
  | Github_client_refused of Login_client.environment_error
  | Redirect_not_the_callback of
      { provider : Login_routes.provider
      ; callback_path : string  (** The path this server answers the callback on. *)
      ; redirect_path : string  (** The path of the [redirect_uri] of the member. *)
      }
      (** The provider would send the browser back to a path this server
          does not answer the callback on. *)
  | Redirect_not_on_the_base_url of
      { provider : Login_routes.provider
      ; base_url_origin : string  (** The origin of the base URL of the server. *)
      ; redirect_origin : string  (** The origin of the [redirect_uri] of the member. *)
      }
      (** The provider would send the browser back to an origin that is not
          the one the operator configured as the base URL of this server. *)

(** Names the provider, and the variable, the field or the path that was
    refused. The value of a secret is in no refusal. *)
val refusal_to_string : refusal -> string

(** The clients of a server. *)
type clients =
  { google : Login_routes.google_login option
  ; github : Login_client.t option
  }

(** The clients that [config.json] names, each built by
    {!Login_client.of_environment}: the secret is read through [getenv] from
    the variable the member names, and the redirect has to be an [https]
    URL whose path is the callback of its provider
    ({!Server_login_http.google_callback_path},
    {!Server_login_http.github_callback_path}). The origin of the redirect is
    compared by {!redirects_on_the_server}, once the server knows its own
    address. A member that is there and whose client is refused stops the boot:
    a server that left it out would answer 404 on a login the operator
    configured. A member that is not there gives [None], and its routes
    answer 404 ({!Login_routes.t}). The Google client gets an empty cache of
    the provider's endpoints and keys. *)
val clients_of_config
  :  getenv:(string -> string option)
  -> Authz_boot_mode_read.login_clients
  -> (clients, refusal) result

(** Whether the redirects were compared with the address of the server. *)
type redirect_check =
  | Compared_with_the_base_url
  | No_base_url
      (** The operator configured no base URL, so the server knows no public
          address of its own and compares nothing. It does not take the
          address it binds for one: a server behind a proxy or a tunnel binds
          another. *)

(** Compares the origin (scheme, host and effective port) of the redirect of
    every client with [base_url], the identity of the base URL the operator
    configured; [None] when they configured none. A redirect on another
    origin is refused: the provider would send the browser of every login to
    a server that is not this one. The caller gives [None] and not the
    address the listener binds, which {!Server_bootstrap_http.make_http_config}
    writes into the variable of the base URL when the operator left it
    unset. *)
val redirects_on_the_server
  :  base_url:Server_request_authority.authority option
  -> clients
  -> (redirect_check, refusal) result

(** The shared value of the routes over [zone]: a new key that seals the
    logins in flight ({!Oidc_login_transaction.create}), the transport of
    {!Server_login_http.get} and {!Server_login_http.post} on [clock], the
    wall clock, and 32 random bytes per draw ({!Random_id.hex}). The
    transport needs the environment and the switch of the process
    ([Eio_context.set_env], [Eio_context.set_switch]) when a login reaches
    its provider; without them a login that reaches its provider answers
    502. *)
val routes
  :  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> zone:Authz_zone.t
  -> clients
  -> Login_routes.t
