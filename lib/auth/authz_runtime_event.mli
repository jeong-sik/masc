(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record
   that makes a Runtime and its Self grant. The owner this body names is the
   only person a Keeper turn on the Runtime may run as. *)

(** The body of a record of a Runtime (design 4.2-4.3, plan D1): a person makes
    a Runtime on a provider account they own, and the same record gives them
    its Self grant.

    {b Runtime.} A Runtime is one binding of a provider and a model, and its id
    is the key of that binding (plan D1). The record names the owner, the
    provider account the Runtime spends, and the id of the Self grant. The
    Self grant is in the same record because a commit of the zone is one
    record, and design 4.3 makes the grant in the same append as the Runtime.

    {b Body.}
    [{"event":"made","runtime_id":...,"provider_account_id":...,"user_id":...,"grant_id":...,"self_effects":[...]}],
    with the members in this order. Every value is a string but
    [self_effects], the effects the Self grant allows: a list of effect labels
    in strictly ascending order ({!Authz_scope_body.effect_set_to_body}). The
    Self grant of design 4.3 names its effects, and the decision of design 6.2
    reads them from here (user decision 2026-11-09). The labels are on
    disk and renaming one orphans every record written with it. A body with
    other members, the same members in another order, or a member of another
    type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), whose the provider account is, nor whether
    the Runtime was made before. *)

type t =
  | Made of
      { runtime_id : Authz_types.Runtime_id.t
      ; provider_account_id : Authz_types.Provider_account_id.t
      ; user_id : Authz_types.User_id.t  (** The owner, who makes it. *)
      ; grant_id : Authz_types.Grant_id.t  (** The Self grant of the owner. *)
      ; self_effects : Authz_types.Effect.Set.t  (** What the Self grant allows. *)
      }

val equal : t -> t -> bool

(** The body of the record. An error comes only from {!Authz_body.string}. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a Runtime record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order,
          each of its type. *)
  | Invalid_runtime_id of Authz_id.error
  | Invalid_provider_account_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_grant_id of Authz_id.error
  | Invalid_self_effects of Authz_scope_body.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, and
    then each id, in the order of the members, is one. *)
val of_body : Authz_body.t -> (t, error) result
