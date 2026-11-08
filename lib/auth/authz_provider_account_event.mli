(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record
   that names the owner of a provider account. A Runtime is made only on an
   account of its owner, so the owner this body names decides whose
   subscription a Keeper turn spends. *)

(** The body of a record of a provider account (design 4.2 and 5.4, plan
    D1-1): a person links a subscription as their own.

    {b Account.} A provider account is one provider entry of [runtime.toml]
    with its account home, and its id is the id of that entry (plan D1). The
    record names the owner. What the provider is and where its home lies stay
    in [runtime.toml], which a later layer checks against this record.

    {b Body.} [{"event":"linked","provider_account_id":...,"user_id":...}],
    with the members in this order and every value a string. The labels are on
    disk and renaming one orphans every record written with it. A body with
    other members, the same members in another order, or a member of another
    type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), nor whether the account was linked
    before. *)

type t =
  | Linked of
      { provider_account_id : Authz_types.Provider_account_id.t
      ; user_id : Authz_types.User_id.t  (** The owner, who links it. *)
      }

val provider_account_id : t -> Authz_types.Provider_account_id.t
val equal : t -> t -> bool

(** The body of the record. An error comes only from {!Authz_body.string}. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a provider account record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order,
          each a string. *)
  | Invalid_provider_account_id of Authz_id.error
  | Invalid_user_id of Authz_id.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, and
    then the account id and the user id are ones. *)
val of_body : Authz_body.t -> (t, error) result
