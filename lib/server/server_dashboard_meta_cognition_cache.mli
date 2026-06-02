(** Meta-cognition summary cache for dashboard shell endpoints.

    Encapsulates per-cache-key warm-inflight dedup and the TTL used by callers
    in [Server_dashboard_http_core]. *)

val summary_ttl : float
val clear_warm_flag : string -> unit

(** Claim the warm slot for [key]; returns [true] when this caller
    acquired the slot, [false] when another fiber is already warming. *)
val try_acquire_warm_slot : string -> bool
