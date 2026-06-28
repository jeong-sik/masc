(** Per-directory, mutex-guarded single-flight cache backing a background
    refresh probe.

    Extracted from the structurally identical bookkeeping that
    [git_rev_parse_short] and [git_upstream_status] each inlined.
    The cache owns only state plus lookup/guard/store bookkeeping;
    the caller-driven background refresh orchestration and the
    domain-fork-aware fiber fork stay in the enclosing module and
    call [try_begin_refresh] / [finish_refresh] / [cancel_refresh].

    Concurrency model: [mu] guards [cache] and [in_flight] together;
    [try_begin_refresh] is the single-flight gate (one refresh per key);
    [finish_refresh] / [cancel_refresh] release it. *)

module Make (C : sig
  type value

  val ttl_sec : float
end) : sig
  val cached_lookup : string -> now:float -> C.value option
  val cached_any : string -> C.value option
  val try_begin_refresh : string -> bool
  val finish_refresh : string -> C.value -> now:float -> unit
  val cancel_refresh : string -> unit
  val clear_cache_for_tests : unit -> unit
  val seed_cache_for_tests : string -> C.value -> refreshed_at:float -> unit
  val set_probe_hook_for_tests : (string -> C.value) -> unit
  val clear_probe_hook_for_tests : unit -> unit
  val probe_hook_for_tests : (string -> C.value) option Atomic.t
end

(** [fork_background_refresh_or_cancel] forks an Eio fiber to run a background
    cache refresh. If no switch is available or the domain is unable to fork
    (e.g., Domain_pool worker without an active server root switch), it immediately
    cancels the refresh to release the single-flight gate. *)
val fork_background_refresh_or_cancel : dir:string -> cancel_refresh:(string -> unit) -> (unit -> unit) -> unit

val background_refresh_clear_unavailable_domains_for_tests : unit -> unit
val background_refresh_domain_unavailable : unit -> bool
val eio_switch_fork_unavailable : exn -> bool
val background_refresh_mark_domain_unavailable : unit -> unit
