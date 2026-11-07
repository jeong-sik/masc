(* HIGH-RISK-UNREVIEWED: this is what the session records of the authorization log
   add up to. A session that this module holds open, and not expired, lets the
   browser that holds its secret act as its principal. *)

(** The browser sessions that the session records of [authz.jsonl] add up to
    (design 5.2, plan C3). {!Authz_state} keeps one of these as its field and
    hands it every session record of a bootstrapped log.

    {b Who may write.} A human principal issues a session for themselves and
    revokes their own session. An issue may end, in the same record, the
    session that the same browser held ([replaces]), whoever it belonged to:
    the server puts a session there only after it matched the secret of the
    cookie. A service, the local operator, and the system authors write no
    session.

    {b One id.} A session id names one session for good: a revoked or replaced
    session keeps its id, so a later session takes another.

    {b Lifetime.} A session ends {!lifetime_ms} after the time of the record
    that issued it. No record says so; {!find_active} reads the time. Using a
    session does not make it last longer. Whether its principal is still
    active is for the caller to check, as principal records are not read
    here. *)

(** Seven days (user decision 2026-11-07). *)
val lifetime_ms : int

type status =
  | Open
  | Revoked  (** Its user signed out. *)
  | Replaced of Authz_types.Session_id.t
      (** A new sign-in of the same browser ended it and issued this one. *)

type session = private
  { user_id : Authz_types.User_id.t
  ; secret_digest : Authz_session_event.Secret_digest.t
  ; issued_at_ms : int  (** The time of the record that issued it. *)
  ; status : status
  }

type t

val empty : t
val find : t -> Authz_types.Session_id.t -> session option

(** Why a session does not act now. *)
type inactive =
  | Unknown  (** No session has this id. *)
  | Ended  (** It was revoked or replaced. *)
  | Expired  (** It was issued {!lifetime_ms} or more before [now_ms]. *)

(** The open session with this id, if it has not expired at [now_ms]. *)
val find_active
  :  t
  -> Authz_types.Session_id.t
  -> now_ms:int
  -> (session, inactive) result

type refusal =
  | Already_issued of Authz_types.Session_id.t
      (** The id names a session, open or not. *)
  | Issued_for_another of
      { author : Authz_types.User_id.t
      ; user_id : Authz_types.User_id.t
      }
      (** A principal issues a session only for themselves. *)
  | User_not_active of Authz_types.User_id.t
      (** No active principal has this id: it never joined, or it is disabled
          or deleted. *)
  | Not_issued of Authz_types.Session_id.t
      (** A revocation or an issue names a session that was never issued. *)
  | Already_ended of Authz_types.Session_id.t
  | Not_the_owner of
      { session_id : Authz_types.Session_id.t
      ; author : Authz_types.User_id.t
      }
      (** A principal revokes only their own session. *)
  | Not_a_human of Authz_types.Principal.t  (** A service has no browser session. *)
  | Not_a_session_author of Authz_records.Author.t
      (** The local operator or a system author, which {!Authz_record.admits}
          does not let write a session record. *)

val refusal_to_string : refusal -> string

(** What one session record does to the sessions. [at_ms] is the time of the
    record, and [is_active] says whether a human principal is there and
    active. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> at_ms:int
  -> is_active:(Authz_types.User_id.t -> bool)
  -> Authz_session_event.t
  -> (t, refusal) result
