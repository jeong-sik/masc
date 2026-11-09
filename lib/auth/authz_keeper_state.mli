(* HIGH-RISK-UNREVIEWED: this is what the Keeper records of the authorization
   log add up to. The owner this module names for a Keeper is the only person
   whose Runtimes the Keeper may be given, and the Runtime it names is the one
   its turns run on. *)

(** The Keepers that the Keeper records of [authz.jsonl] add up to (design 4.3,
    plan D1-5). {!Authz_state} keeps one of these as its field and hands it
    every Keeper record of a bootstrapped log.

    {b Who may write.} An active human principal makes a Keeper for
    themselves, and gives it a Runtime they own. An Admin makes none for
    another person, gives no Runtime to the Keeper of another person, and
    gives their own Keeper no Runtime of another person. A service, the local
    operator, and the system authors write none.

    {b One name.} A Keeper id names one Keeper for good: once made, a Keeper
    keeps its owner, and no record makes it again, for its owner or for anyone
    else. A later assignment replaces the Runtime of an earlier one. A Keeper
    with no assignment has no Runtime and falls back to none (user decision
    2026-11-08). A policy id names one Keeper's policy for good: no other
    Keeper record names it again. *)

type keeper =
  { owner : Authz_types.User_id.t
  ; policy_id : Authz_types.Policy_id.t
      (** The policy the owner's turns of this Keeper run under. *)
  ; turn_scope : Authz_types.Authorization_scope.t  (** The limits of that policy. *)
  ; runtime : Authz_types.Runtime_id.t option
      (** The Runtime of the latest assignment; [None] until the first. *)
  }

type t

val empty : t

(** The Keeper, if it was made. *)
val find : t -> Authz_types.Keeper_id.t -> keeper option

(** The Keepers this person owns, in the order of their ids. *)
val owned_by : t -> Authz_types.User_id.t -> (Authz_types.Keeper_id.t * keeper) list

type refusal =
  | Already_made of Authz_types.Keeper_id.t
  | Policy_named_before of Authz_types.Policy_id.t
      (** Another Keeper's record named this policy id. *)
  | Not_made of Authz_types.Keeper_id.t
      (** An assignment to a Keeper no record made. *)
  | Made_for_another of
      { author : Authz_types.User_id.t
      ; user_id : Authz_types.User_id.t
      }
      (** A principal makes a Keeper only for themselves, an Admin too. *)
  | Assigned_by_another of
      { author : Authz_types.User_id.t
      ; keeper_id : Authz_types.Keeper_id.t
      ; owner : Authz_types.User_id.t
      }
      (** Only the owner gives a Keeper a Runtime, not an Admin. *)
  | Runtime_not_made of Authz_types.Runtime_id.t
  | Not_the_owners_runtime of
      { keeper_id : Authz_types.Keeper_id.t
      ; runtime_id : Authz_types.Runtime_id.t
      ; runtime_owner : Authz_types.User_id.t
      }
      (** The Runtime is another person's: its Self grant is not the Keeper
          owner's (design 4.3). *)
  | User_not_active of Authz_types.User_id.t
      (** No active principal has this id: it never joined, or it is disabled
          or deleted. *)
  | Not_a_human of Authz_types.Principal.t
  | Not_a_keeper_author of Authz_records.Author.t
      (** The local operator or a system author, which {!Authz_record.admits}
          does not let write a Keeper record. *)

val refusal_to_string : refusal -> string

(** What one Keeper record does to the Keepers. [is_active] says whether a
    human principal is there and active, and [runtime_owner] who owns a
    Runtime, if it was made. *)
val apply
  :  t
  -> author:Authz_records.Author.t
  -> is_active:(Authz_types.User_id.t -> bool)
  -> runtime_owner:(Authz_types.Runtime_id.t -> Authz_types.User_id.t option)
  -> Authz_keeper_event.t
  -> (t, refusal) result
