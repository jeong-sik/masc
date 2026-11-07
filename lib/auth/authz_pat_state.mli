(* HIGH-RISK-UNREVIEWED: this is what the PAT records of the authorization log
   add up to. A PAT that this module holds open, and not expired, lets the
   holder of its token act as its Human within its scope. *)

(** The scoped PATs that the PAT records of [authz.jsonl] add up to (design
    4.4, plan C4-4). {!Authz_state} keeps one of these as its field and hands
    it every PAT record of a bootstrapped log.

    {b Who may write.} An active human principal issues a PAT for themselves
    and revokes their own PAT. A service, the local operator, and the system
    authors write no PAT.

    {b One id.} A PAT id names one PAT for good: a revoked PAT keeps its id.

    {b Expiry.} A PAT with an expiry has expired when the time is not before
    it (design 4.4). No record says so; {!find_active} reads the time. Whether
    its Human is still active is for the caller to check, as principal records
    are not read here. *)

type status =
  | Open
  | Revoked

type pat = private
  { user_id : Authz_types.User_id.t
  ; secret_digest : Authz_credential_token.Pat.Digest.t
  ; scope : Authz_types.Authorization_scope.t
  ; expires_at_ms : int option
  ; issued_at_ms : int  (** The time of the record that issued it. *)
  ; status : status
  }

type t

val empty : t
val find : t -> Authz_types.Pat_id.t -> pat option

(** Why a PAT does not act now. *)
type inactive =
  | Unknown  (** No PAT has this id. *)
  | Ended  (** It was revoked. *)
  | Expired  (** Its expiry is not after [now_ms]. *)

(** The open PAT with this id, if it has not expired at [now_ms]. *)
val find_active : t -> Authz_types.Pat_id.t -> now_ms:int -> (pat, inactive) result

type refusal =
  | Already_issued of Authz_types.Pat_id.t  (** The id names a PAT, open or not. *)
  | Issued_for_another of
      { author : Authz_types.User_id.t
      ; user_id : Authz_types.User_id.t
      }
      (** A principal issues a PAT only for themselves. *)
  | User_not_active of Authz_types.User_id.t
      (** No active principal has this id: it never joined, or it is disabled
          or deleted. *)
  | Not_issued of Authz_types.Pat_id.t
  | Already_revoked of Authz_types.Pat_id.t
  | Not_the_owner of
      { pat_id : Authz_types.Pat_id.t
      ; author : Authz_types.User_id.t
      }
      (** A principal revokes only their own PAT. *)
  | Not_a_human of Authz_types.Principal.t  (** A service has no PAT. *)
  | Not_a_pat_author of Authz_records.Author.t
      (** The local operator or a system author, which {!Authz_record.admits}
          does not let write a PAT record. *)

val refusal_to_string : refusal -> string

(** What one PAT record does to the PATs. [at_ms] is the time of the record,
    and [is_active] says whether a human principal is there and active. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> at_ms:int
  -> is_active:(Authz_types.User_id.t -> bool)
  -> Authz_pat_event.t
  -> (t, refusal) result
