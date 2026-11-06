(* HIGH-RISK-UNREVIEWED: holds the secrets of logins in flight. A transaction
   that is taken twice, or by the wrong browser, lets one person finish
   another's login, or spend their invitation. *)

(** Logins in flight (design 5.2, plan C2a-2).

    The start of a login draws its [state], [nonce], and PKCE verifier from the
    CSPRNG of {!Random_id} and keeps them here under a transaction ID. The
    browser carries the ID (plan C3 puts it in [__Host-masc_oidc_txn]) and
    Google carries [state] back to the callback, which takes the transaction
    with both. The verifier and the nonce never leave this module but through
    {!take}, so the browser and Google see only the challenge and the nonce
    sent to Google.

    A transaction is taken once: {!take} removes it whether or not [state]
    matches, so a second callback with the same ID finds nothing. It lives
    {!lifetime_ms}. The store holds at most the capacity it was made with, and
    a start that finds it full of live transactions is refused rather than
    pushing one out: pushing out the oldest would end a login that someone
    is finishing. Expired transactions do not count.

    No network. The clock is the [now_ms] of each call, from a clock that does
    not go back (a monotonic one): a clock set back would keep a transaction
    past its lifetime. *)

(** The token of an invitation link ([<base url>/accounts/invite#<token>],
    plan B3d-1), sent by the form of the invitation screen. It is held only in
    a transaction, and nothing prints it: the only function out of it is its
    digest, so it reaches no log, query string, or error text (design 5.1-4). *)
module Invite_token : sig
  type t

  (** [Some] for 64 lowercase hex characters, the token that
      {!Authz_activation} makes. *)
  val of_form : string -> t option

  val digest : t -> Authz_invite_event.Token_digest.t
end

(** Where the browser goes after the login: a path of this host (design 5.2).
    It is read as an RFC 3986 [path-absolute] with an optional query, not
    matched by prefix. A scheme, an authority ([//host]), a fragment, or a
    character outside the grammar (a backslash, a space, a control character,
    a [%] not followed by two hex digits) is refused. A browser reads a
    backslash as [/], so a slash and a backslash before a host name would
    leave this host. *)
module Local_path : sig
  type t

  val of_string : string -> t option
  val to_string : t -> string

  (** ["/"]. *)
  val root : t
end

(** The key of a transaction: 32 bytes of the CSPRNG as 64 lowercase hex
    characters. *)
module Id : sig
  type t

  val of_string : string -> t option
  val to_string : t -> string
end

(** Ten minutes. A login that takes longer starts again. *)
val lifetime_ms : int

(** What the start of a login sends: the ID to the browser, the rest to Google
    in the authorization request. [code_challenge] is the S256 challenge of the
    verifier (RFC 7636 section 4.2). *)
type started =
  { id : Id.t
  ; state : string
  ; nonce : string
  ; code_challenge : string
  }

(** What the callback gets back. *)
type taken =
  { nonce : string  (** The nonce the ID token must carry ({!Oidc_google.identity}). *)
  ; code_verifier : string  (** Sent with the code to the token endpoint. *)
  ; invite : Invite_token.t option
  ; return_to : Local_path.t
  }

type t

(** A store that holds at most [capacity] live transactions. [capacity] is at
    least 1. *)
val create : capacity:int -> t

type start_error = Full

val start
  :  t
  -> now_ms:int
  -> invite:Invite_token.t option
  -> return_to:Local_path.t
  -> (started, start_error) result

type take_error =
  | Unknown  (** No transaction has this ID: none started, or it was taken. *)
  | Expired  (** It started {!lifetime_ms} or more before [now_ms]. *)
  | State_differs

val take_error_to_string : take_error -> string

(** Removes the transaction [id] and gives it back if it is live and [state]
    is its state, compared in constant time. *)
val take : t -> now_ms:int -> Id.t -> state:string -> (taken, take_error) result

(** The live transactions at [now_ms]. *)
val live : t -> now_ms:int -> int
