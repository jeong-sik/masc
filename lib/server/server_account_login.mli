(* HIGH-RISK-UNREVIEWED: builds the clients that log a person in. A client
   holds the secret a login provider gave this installation. *)

(** What the login routes of a multi-account installation share
    ({!Login_routes.t}), made once for a zone (plan S1a-3).

    The account server makes it at boot from the login clients of the
    [config.json] that the boot judged, and the localhost preview makes it
    from the loopback client of its command line. Both go through {!routes},
    so the store of pending logins, the transport to a provider, the wall
    clock and the random source of the two are the same. *)

type refusal =
  | Google_client_refused of Login_client.environment_error
  | Github_client_refused of Login_client.environment_error

(** Names the provider, and the variable or the field that was refused. The
    value of a secret is in no refusal. *)
val refusal_to_string : refusal -> string

(** The clients of a server. *)
type clients =
  { google : Login_routes.google_login option
  ; github : Login_client.t option
  }

(** The clients that [config.json] names, each built by
    {!Login_client.of_environment}: the secret is read through [getenv] from
    the variable the member names, and the redirect has to be an [https]
    URL. A member that is there and whose client is refused stops the boot:
    a server that left it out would answer 404 on a login the operator
    configured. A member that is not there gives [None], and its routes
    answer 404 ({!Login_routes.t}). The Google client gets an empty cache of
    the provider's endpoints and keys. *)
val clients_of_config
  :  getenv:(string -> string option)
  -> Authz_boot_mode_read.login_clients
  -> (clients, refusal) result

(** How many logins can be between their start and their callback at once.
    A start beyond it is refused ({!Oidc_login_transaction.start_error}),
    and a pending login leaves at its callback or when it expires. *)
val pending_login_capacity : int

(** The shared value of the routes over [zone]: a new store of
    {!pending_login_capacity} pending logins, the transport of
    {!Server_login_http.get} and {!Server_login_http.post} on [clock], the
    wall clock, and 32 random bytes per draw ({!Random_id.hex}). The
    transport needs the environment of the process
    ([Eio_context.set_env]) when a login reaches its provider. *)
val routes
  :  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> zone:Authz_zone.t
  -> clients
  -> Login_routes.t
