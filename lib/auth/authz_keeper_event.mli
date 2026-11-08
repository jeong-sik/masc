(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the records
   that make a person the owner of a Keeper and give the Keeper a Runtime. The
   owner this body names is the only person whose Runtimes the Keeper may be
   given. *)

(** The body of a record of a Keeper (design 4.3, plan D1-5): a person makes a
    Keeper and is its owner, and the owner gives it one of their Runtimes.

    {b Keeper.} In the first stage a Keeper of a person has one owner (design
    4.3). Its turns run as the owner, on a Runtime whose Self grant the owner
    holds. In multi-account mode the Runtime a Keeper is given is in the log,
    not in [runtime.toml]: the Runtimes of a person are made from the log and a
    provider template, and no provider of [runtime.toml] declares them (user
    decision 2026-11-09).

    {b Body.} [{"event":"made","keeper_id":...,"user_id":...}] and
    [{"event":"assigned","keeper_id":...,"runtime_id":...}], with the members
    in this order and every value a string. An assignment names no person: its
    author is the owner who gives the Runtime. The labels are on disk and
    renaming one orphans every record written with it. A body with other
    members, the same members in another order, or a member of another type is
    refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_state} decide that), whether the Keeper was made before, nor
    whose the Runtime is. *)

type t =
  | Made of
      { keeper_id : Authz_types.Keeper_id.t
      ; user_id : Authz_types.User_id.t  (** The owner, who makes it. *)
      }
  | Assigned of
      { keeper_id : Authz_types.Keeper_id.t
      ; runtime_id : Authz_types.Runtime_id.t
          (** The Runtime its turns run on, from now on. *)
      }

val equal : t -> t -> bool

(** The body of the record. An error comes only from {!Authz_body.string}. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a Keeper record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order,
          each a string. *)
  | Invalid_keeper_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_runtime_id of Authz_id.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, and
    then each id, in the order of the members, is one. *)
val of_body : Authz_body.t -> (t, error) result
