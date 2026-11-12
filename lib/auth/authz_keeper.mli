(* HIGH-RISK-UNREVIEWED: this module writes the records that make a person the
   owner of a Keeper and give the Keeper a Runtime. *)

(** Makes a Keeper for its owner and gives it a Runtime, against the writer
    zone (design 4.3, plan D1-5). In the first stage a Keeper is given only a
    Runtime whose Self grant its owner holds; the zone refuses another one
    through {!Authz_keeper_state}. *)

type error =
  | Id_not_drawn of Authz_id.error  (** [draw] gave a value that is not a policy id. *)
  | Body_not_built of Authz_body.error
  | Refused of Authz_keeper_state.refusal
      (** The state of the zone, read just before the commit, refuses the
          record: the Keeper was made before, or the Runtime is another
          person's, among others. Nothing was written. *)
  | Commit_failed of Authz_zone.error
      (** The zone did not write the record. A record that a later record
          made refusable between the read and the commit lands here too, as a
          [Refused] of the zone. *)

(** The reason in full, as {!Authz_zone.error_detail} gives that of a commit
    that failed. It can name paths of the server, so it is for the log of the
    server and not for an answer to a person. *)
val error_detail : error -> string

(** Writes the record that makes [keeper_id] for [user_id], whose turns run
    under a policy of [user_id] to [user_id] with the id [draw ()] and the
    limits [turn_scope]. *)
val make
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> keeper_id:Authz_types.Keeper_id.t
  -> turn_scope:Authz_types.Authorization_scope.t
  -> draw:(unit -> string)
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
