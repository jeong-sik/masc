(* HIGH-RISK-UNREVIEWED: runs a Google login from its start to the decision of
   who it signs in as. It reads the client secret and writes admissions. *)

(** A Google login from its start to the admission (design 5.2, plan C2a-5).

    The routes of C3 call it: {!start} for [POST /auth/oidc/start] and
    {!callback} for [GET /auth/oidc/callback]. The routes carry the
    sealed transaction in a cookie; this module never sees the cookie.

    The transport, the clock and the draws are arguments. This module does no
    I/O of its own; the zone writes the admission. *)

(** What a start gives the route: the sealed transaction for the cookie, and
    where to send the browser. *)
type started =
  { sealed : Oidc_login_transaction.Sealed.t
  ; authorization_url : string
  }

type start_error =
  | Google_unavailable of Oidc_google_exchange.error
      (** The discovery document could not be read. *)
  | Return_path_too_long
      (** {!Oidc_login_transaction.Too_long}: the sealed transaction does not
          fit a cookie. *)

val start_error_to_string : start_error -> string

(** Reads the endpoints and then seals a transaction. [invite] is the token that
    the invitation link posted, if any. [replaces] is the session of the
    browser that started, which the sign-in ends. *)
val start
  :  get:Login_transport.get
  -> Oidc_google_exchange.cache
  -> Oidc_login_transaction.t
  -> Login_client.t
  -> now:(unit -> Ptime.t)
  -> invite:Oidc_login_transaction.Invite_token.t option
  -> return_to:Oidc_login_transaction.Local_path.t
  -> replaces:Authz_types.Session_id.t option
  -> (started, start_error) result

(** What Google sent the browser back with. *)
type answer =
  | Code of string
  | Refused
      (** An [error] parameter instead of a code: the person declined, or
          Google refused the request (RFC 6749 section 4.1.2.1). *)

type completed =
  { outcome : Authz_login.outcome
  ; return_to : Oidc_login_transaction.Local_path.t
  ; replaces : Authz_types.Session_id.t option
        (** The session that the browser held at the start
            ({!Oidc_login_transaction.taken}). *)
  }

type callback_error =
  | Transaction_refused of Oidc_login_transaction.open_error
  | Refused_at_google
  | Exchange_failed of Oidc_google_exchange.error
  | Login_refused of Authz_login.refusal

val callback_error_to_string : callback_error -> string

(** Takes the transaction [id] with [state] first, so the transaction is gone
    after any callback, a refused one included. Then, for a code, it exchanges
    the code for the identity (C2a-3, with C1 and C2a-1) and decides the login
    with the zone (C2a-4), with the invitation token of the transaction.
    [draw] gives the user ID and the namespace of an admission
    ({!Authz_login.sign_in}). *)
val callback
  :  get:Login_transport.get
  -> post:Login_transport.post
  -> Oidc_google_exchange.cache
  -> Oidc_login_transaction.t
  -> Authz_zone.t
  -> Login_client.t
  -> now:(unit -> Ptime.t)
  -> draw:(unit -> string)
  -> Oidc_login_transaction.Sealed.t
  -> state:string
  -> answer
  -> (completed, callback_error) result
