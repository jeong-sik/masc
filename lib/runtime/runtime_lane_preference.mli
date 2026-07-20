(** Process-local sticky candidate preference for runtime lane failover.

    Lane failover walks candidates in declared order every turn, so a dead
    head candidate (e.g. an hourly provider rate-limit window) is hit on
    every turn before the lane fails over.  This module remembers the last
    successful candidate per lane so later turns start from it instead.

    The table is keyed by lane id and shared across keepers on purpose:
    provider rate limits are account-scoped, so one keeper's failover
    discovery benefits every keeper routed through the same lane.  Entries
    expire lazily on read against {!ttl_s}; there is no background sweeper. *)

val prefer_order : lane_id:string -> string list -> string list
(** Reorder [candidates] so the remembered last-good candidate for [lane_id]
    comes first, keeping the declared relative order of the rest.  Returns
    the input unchanged when no entry is remembered, the entry expired, or
    the remembered candidate is not a member of [candidates]. *)

val note_success : lane_id:string -> candidate:string -> unit
(** Remember [candidate] as the last-good candidate for [lane_id], stamped
    with the current time.  Called on every successful attempt, whether the
    head candidate or a failover candidate succeeded. *)

val ttl_s : unit -> float
(** Sticky preference TTL in seconds ([MASC_LANE_PREFERENCE_TTL_S], default
    [3600.0]; [0] disables stickiness). *)

val reset_for_testing : unit -> unit
(** Drop every remembered entry.  Test-only. *)
