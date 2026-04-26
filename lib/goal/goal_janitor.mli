(** Goal_janitor — Periodic cleanup of stale and dropped goals.

    Three sweep rules:
    1. Purge: delete [Dropped] goals older than
       [dropped_ttl_days] (default 7).
    2. Stagnate: mark [Active] goals with no update for
       [stagnant_days] (default 30) as [Dropped].
    3. Orphan: remove [active_goal_ids] entries from each
       [keeper_meta] that reference non-existent goals in the Goal
       Store.

    @since 2.236.0 *)

(** {1 Configuration} *)

type sweep_config =
  { dropped_ttl_days : int (** Delete Dropped goals after this many days. *)
  ; stagnant_days : int (** Drop Active goals with no update after this many days. *)
  }

val default_config : sweep_config

(** {1 Result} *)

type sweep_result =
  { purged : int (** Dropped goals deleted. *)
  ; stagnated : int (** Active goals marked Dropped. *)
  ; orphans : int (** Orphaned [active_goal_ids] cleaned. *)
  }

val sweep_result_to_yojson : sweep_result -> Yojson.Safe.t

(** {1 Helpers} *)

(** [prune_active_goal_ids ~valid_goal_ids active_ids] keeps only
    ids in [valid_goal_ids]. Returns the pruned list and the number
    of removed ids. *)
val prune_active_goal_ids : valid_goal_ids:string list -> string list -> string list * int

(** {1 Entry point} *)

(** Run a full sweep: goal purge / stagnate, then keeper
    [active_goal_ids] prune. Writes updated state to disk. *)
val run : ?config:sweep_config -> Coord.config -> sweep_result
