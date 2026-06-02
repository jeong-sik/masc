(** P17: Turn Execution Budget *)

type t
(** Mutable budget tracker.  Thread-safe via single-owner: one per keeper
    turn, never shared across fibers. *)

val create : ?limit:int -> ?soft_limit:int -> unit -> t
(** Create a fresh budget.  Default [limit=30], [soft_limit=20]. *)

val reset : t -> unit
(** Reset counters to zero (call at turn start). *)

val record : t -> duration_ms:int -> unit
(** Increment command count and accumulate duration. *)

type budget_status =
  | Ok of { remaining : int }
  | Soft_warning of { remaining : int; limit : int }
  | Hard_stop of { count : int; limit : int; cumulative_ms : int }
(** Result of [check]: still under soft limit, approaching limit, or
    exceeded hard limit. *)

val check : t -> budget_status
(** Check current budget status.  Does not mutate. *)

val status_to_json : budget_status -> Yojson.Safe.t
(** Serialize status to JSON.  [Ok] returns [Null]; warnings include
    human-readable [message] and [suggestion] fields. *)

val to_json : t -> Yojson.Safe.t
(** Full budget snapshot as JSON. *)
