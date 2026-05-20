(** Meta-cognition summary cache for dashboard shell endpoints.

    Encapsulates per-cache-key warm-inflight dedup and last-good
    fallback tables, plus the TTL/stale-window constants used by
    callers in [Server_dashboard_http_core]. *)

val summary_ttl : float
val summary_stale_for : float
val summary_empty_json : Yojson.Safe.t

val store_last_good : string -> Yojson.Safe.t -> unit
val find_last_good : string -> Yojson.Safe.t option
val clear_warm_flag : string -> unit

(** Claim the warm slot for [key]; returns [true] when this caller
    acquired the slot, [false] when another fiber is already warming. *)
val try_acquire_warm_slot : string -> bool
