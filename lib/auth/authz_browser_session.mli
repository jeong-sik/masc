(* HIGH-RISK-UNREVIEWED: issues, matches, and ends browser sessions. A cookie that
   this module matches acts as its principal. *)

(** A browser session from the cookie side (design 5.2, plan C3-6): what the
    cookie [__Host-masc_session] carries, how a sign-in issues a session, how a
    request's cookie is matched to one, how a sign-out ends one, and the CSRF
    token bound to it.

    The routes of C3-8 call it. This module never sees an HTTP request, and
    the zone writes every record. *)

(** What the cookie carries: the id of the session and its secret. The secret
    is 32 bytes from the OS CSPRNG as 64 lowercase hex characters; the log
    holds only its digest ({!Authz_session_event.Secret_digest}). No function
    but {!Cookie.to_value} gives the secret out, so it reaches no log line or
    error text. *)
module Cookie : sig
  type t

  val session_id : t -> Authz_types.Session_id.t

  (** [<session id>.<secret>]. The secret is the last 64 characters, so an id
      with a [.] in it reads back. *)
  val to_value : t -> string

  (** [None] for a value that is not one of {!to_value}. *)
  val of_value : string -> t option
end

(** The CSRF token of a session (design 5.3): the SHA-256 of the secret with a
    label of its own, as 64 lowercase hex characters. The server does not
    store it; it makes it again from the cookie. The cookie is HttpOnly, so a
    page reads the token only from what the server answers. *)
val csrf_token : Cookie.t -> string

(** Whether [token] is the CSRF token of the cookie, compared in a time that
    does not depend on where they differ. *)
val csrf_matches : Cookie.t -> string -> bool

type error =
  | Id_not_drawn of Authz_id.error  (** [draw] gave a value that is not a session id. *)
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

val error_to_string : error -> string

(** How many ids {!issue} draws before it gives up: an id that the snapshot
    already names is drawn again. *)
val attempts : int

(** Issues a session for [user_id], who signed in. [replaces] is the session
    that the same browser held, which the caller matched with
    {!authenticate}; the record ends it ({!Authz_session_event}). [draw ()]
    gives the session id. *)
val issue
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> draw:(unit -> string)
  -> replaces:Authz_types.Session_id.t option
  -> (Cookie.t, error) result

(** The principal a cookie acts as, and its session. *)
type signed_in =
  { user_id : Authz_types.User_id.t
  ; session_id : Authz_types.Session_id.t
  ; expires_at_ms : int
        (** The time of the record that issued the session plus
            {!Authz_session_state.lifetime_ms}. *)
  }

(** Why a cookie does not act. *)
type refusal =
  | Unknown  (** No session has the id of the cookie. *)
  | Ended  (** The session was revoked or replaced. *)
  | Expired
  | Secret_differs  (** The session is there, and the secret of the cookie is not its own. *)
  | Revocation_pending
      (** A revocation of the session was given up before it reached the log
          (design 8.3). *)
  | Principal_inactive of Authz_types.User_id.t
      (** The principal of the session is disabled or deleted. *)
  | Principal_revocation_pending of Authz_types.User_id.t
      (** A revocation of the principal of the session was given up before it
          reached the log (design 8.3): the principal is still active in the
          state, and a sign-in refuses them for the same block
          ({!Authz_login.Blocked}). *)

val refusal_to_string : refusal -> string

(** What a cookie acts as at [now_ms], in the state of one snapshot that the
    zone could be trusted for ({!Authz_zone.read}). A zone whose files
    stopped or disagree gives no such snapshot, so no cookie acts on one. *)
val authenticate : Authz_zone.trusted -> now_ms:int -> Cookie.t -> (signed_in, refusal) result

(** Ends the session of [user_id], who signs out. The caller matched the
    cookie with {!authenticate} first. *)
val sign_out
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> Authz_types.Session_id.t
  -> (unit, error) result
