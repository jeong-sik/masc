(** Snapshot TTL cache with same-key deduplication. *)

type snapshot_slot =
  | Cached of
      { value : Yojson.Safe.t
      ; expires_at : float
      }
  | Computing of
      { cond : Eio.Condition.t
      ; stale : Yojson.Safe.t option
      ; started_at : float
      ; stuck_warned : bool ref
      }

val invalidate_snapshot_cache : unit -> unit
