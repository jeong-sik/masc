(** P17: Turn Execution Budget *)

(** Mutable budget tracker.  Thread-safe via single-owner: one per keeper
    turn, never shared across fibers. *)
type t

(** Create a fresh budget.  Default [limit=30], [soft_limit=20]. *)
val create : ?limit:int -> ?soft_limit:int -> unit -> t

(** Reset counters to zero (call at turn start). *)
val reset : t -> unit

(** Increment command count and accumulate duration. *)
val record : t -> duration_ms:int -> unit

type budget_status =
  | Ok of { remaining : int }
  | Soft_warning of
      { remaining : int
      ; limit : int
      }
  | Hard_stop of
      { count : int
      ; limit : int
      ; cumulative_ms : int
      }
  (** Result of [check]: still under soft limit, approaching limit, or
    exceeded hard limit. *)

(** Check current budget status.  Does not mutate. *)
val check : t -> budget_status

(** Serialize status to JSON.  [Ok] returns [Null]; warnings include
    human-readable [message] and [suggestion] fields. *)
val status_to_json : budget_status -> Yojson.Safe.t

(** Full budget snapshot as JSON. *)
val to_json : t -> Yojson.Safe.t
