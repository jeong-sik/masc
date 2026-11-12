(* HIGH-RISK-UNREVIEWED: runs a GitHub login from its start to the decision of
   who it signs in as. It sends the client secret and writes admissions. *)

(** A GitHub login from its start to the admission (design 5.2.1, plan C2b-3).

    The routes of C3 call it: {!start} for [POST /auth/github/start] and
    {!callback} for [GET /auth/github/callback]. The routes carry the
    sealed transaction in a cookie; this module never sees the cookie.

    The transport, the clock and the draws are arguments. This module does no
    I/O of its own; the zone writes the admission. *)

(** What a start gives the route: the sealed transaction for the cookie, and
    where to send the browser. *)
type started =
  { sealed : Oidc_login_transaction.Sealed.t
  ; authorization_url : string
  }

(** Seals a GitHub transaction. GitHub has no discovery document, so a start
    reads nothing first and fails only when the sealed transaction does not
    fit a cookie. [invite] is the token that the invitation link
    posted, if any. [replaces] is the session of the browser that started,
    which the sign-in ends. *)
val start
  :  Oidc_login_transaction.t
  -> Login_client.t
  -> now:(unit -> Ptime.t)
  -> invite:Oidc_login_transaction.Invite_token.t option
  -> return_to:Oidc_login_transaction.Local_path.t
  -> replaces:Authz_types.Session_id.t option
  -> (started, Oidc_login_transaction.start_error) result

(** What GitHub sent the browser back with. *)
type answer =
  | Code of string
  | Refused
      (** An [error] parameter instead of a code, such as [access_denied]
          when the person declined. *)

type completed =
  { outcome : Authz_login.outcome
  ; return_to : Oidc_login_transaction.Local_path.t
  ; replaces : Authz_types.Session_id.t option
        (** The session that the browser held at the start
            ({!Oidc_login_transaction.taken}). *)
  }

type callback_error =
  | Transaction_refused of Oidc_login_transaction.open_error
  | Refused_at_github
  | Exchange_failed of Github_oauth.error
  | Login_refused of Authz_login.refusal

val callback_error_to_string : callback_error -> string

(** Takes the GitHub transaction [id] with [state] first, so the transaction
    is gone after any callback, a refused one included. Then, for a code, it
    exchanges the code for the identity (C2b-2c) and decides the login with
    the zone (C2a-4), with the invitation token of the transaction. [draw]
    gives the user ID and the namespace of an admission
    ({!Authz_login.sign_in}). *)
val callback
  :  get:Login_transport.get
  -> post:Login_transport.post
  -> Oidc_login_transaction.t
  -> Authz_zone.t
  -> Login_client.t
  -> now:(unit -> Ptime.t)
  -> draw:(unit -> string)
  -> Oidc_login_transaction.Sealed.t
  -> state:string
  -> answer
  -> (completed, callback_error) result
