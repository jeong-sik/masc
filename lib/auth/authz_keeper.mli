(* HIGH-RISK-UNREVIEWED: this module writes the records that make a person the
   owner of a Keeper and give the Keeper a Runtime. *)

(** Makes a Keeper for its owner and gives it a Runtime, against the writer
    zone (design 4.3, plan D1-5). In the first stage a Keeper is given only a
    Runtime whose Self grant its owner holds; the zone refuses another one
    through {!Authz_keeper_state}. *)

type error =
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error
      (** The zone refused the record: the Keeper was made before, the Runtime
          is another person's, or the person is no longer active, among
          others. *)

val error_to_string : error -> string

(** Writes the record that makes [keeper_id] for [user_id]. *)
val make
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> keeper_id:Authz_types.Keeper_id.t
  -> (unit, error) result

(** Writes the record by which [user_id], the owner of [keeper_id], gives it
    [runtime_id]. *)
val assign
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> keeper_id:Authz_types.Keeper_id.t
  -> runtime_id:Authz_types.Runtime_id.t
  -> (unit, error) result

(** The Keepers the person owns, in the order of their ids. *)
val owned
  :  Authz_state.t
  -> Authz_types.User_id.t
  -> (Authz_types.Keeper_id.t * Authz_keeper_state.keeper) list
