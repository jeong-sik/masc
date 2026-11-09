(** Which OAuth client redeems a Keeper's codes and refresh tokens.

    Two kinds of client reach a provider, and they live in different places
    because they belong to different things.

    An app an operator made at the provider belongs to the install. One per
    {!Keeper_oauth_provider.client_group}: providers behind the same
    authorization server share it, so one Google app answers for all eight of
    its resources. It is kept under [identity/apps/].

    A client this install registered (RFC 7591) belongs to the login that
    registered it. Every login that has no app to use registers a fresh one,
    naming the callback this server answers at right now. A registered client
    is never reused by a later login: its redirect URI is the one in force
    when it was made. Measured on 2026-11-02, after the server moved from
    [http://127.0.0.1:8935] to a public base URL, 27 of the 48 clients this
    install had kept answered the authorize step with an error for the public
    callback while accepting the loopback one, and three more had been
    deleted by their provider.

    The cost is one registration per login at the provider. This install keeps
    no registration management credentials (RFC 7592), so those records are
    never deleted from this side.

    Whichever client a login used is written beside that Keeper's tokens, at
    a path the caller names, because a refresh token is bound to the client
    it was issued to. Renewing with any other client is refused by the
    provider.

    Client ids are not secrets -- they travel in a browser URL on every login.
    Secrets are kept in the same 0600 files and never rendered. *)

module App : sig
  type t = {
    client_id : string;
    client_secret : string option;
        (** Absent when the provider issued the app without one. *)
    scopes : string list;
        (** What to ask for instead of everything the service publishes.
            The app is the authority on what it may be granted: a request
            for a scope it does not declare is refused. Empty means ask for
            what the service publishes. *)
  }
end

module Registered : sig
  type t = {
    client_id : string;
    client_secret : string option;
        (** [None] is a public client, which is what most providers answer
            registration with. *)
    secret_expires_at : float option;
        (** Unix seconds at which the secret lapses, as registration dated
            it. [Some 0.] is the server saying it never does. [None] beside a
            secret is a server that stated no deadline, although RFC 7591
            section 3.2.1 requires one. *)
  }
end

(** The client a login is using. *)
type login_client =
  | Operator_app of App.t
  | Registered of Registered.t

val login_client_id : login_client -> string
val login_client_secret : login_client -> string option

(** {1 Operator apps} *)

val app_path : identity_dir:string -> provider:Keeper_oauth_provider.t -> string
(** [<identity_dir>/apps/<client_group>.json]. The group is one path
    component, checked when the declaration was read. *)

val load_app :
  identity_dir:string ->
  provider:Keeper_oauth_provider.t ->
  (App.t option, string) result
(** [Ok None] means no app is on file. An [Error] is a file that could not be
    read or decoded, and is not the same as none: writing over it would
    replace credentials that may still be good. *)

val save_app :
  identity_dir:string ->
  provider:Keeper_oauth_provider.t ->
  App.t ->
  (unit, string) result

(** {1 The client a login used} *)

type binding =
  | Bound_to_app of { client_id : string }
      (** The login used the operator's app. Its secret is read from the app
          when it is needed, so an operator who rotates the secret of the
          same app does not strand the Keepers that logged in with it. *)
  | Bound_to_registered of Registered.t
      (** The login registered this client for itself. *)

val binding_of_login_client : login_client -> binding

val load_binding : path:string -> (binding option, string) result
(** Strict: an unknown kind, an unknown field, a [null] or a blank string is an
    [Error], never a different binding. *)
val save_binding : path:string -> binding -> (unit, string) result
(** Written whole and then renamed, so a reader finds the previous binding
    or this one, never half of either. *)

val delete_binding : path:string -> (unit, string) result
(** Removing a binding that is not there is not an error. *)

val secret_expired : Registered.t -> now:float -> bool
(** Whether the deadline registration stated for this secret is behind us.
    A public client, a secret dated [0.] and a secret with no stated deadline
    are not expired: the provider's answer to a renewal decides those. *)

type redeem_error =
  | Not_bound
      (** No record of which client this Keeper's login used. *)
  | Binding_unreadable of string
  | App_unreadable of string
  | App_gone of { client_id : string }
      (** The login used an app that is no longer on file. *)
  | App_replaced of { bound : string; current : string }
      (** The app on file is a different app from the one the login used. *)
  | Registration_lapsed of { client_id : string }

val redeem_error_to_string : redeem_error -> string

val redeeming_client :
  identity_dir:string ->
  provider:Keeper_oauth_provider.t ->
  binding:binding ->
  now:float ->
  (string * string option, redeem_error) result
(** The client id and secret that redeem a token this binding's login was
    issued. *)

val write_whole : string -> string -> (unit, string) result
(** Atomically write [contents] to [path] via a unique 0600 temporary file in
    [Filename.dirname path], creating missing parent directories with mode
    0700. *)
