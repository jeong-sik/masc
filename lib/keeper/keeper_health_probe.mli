(** Asynchronous health probe for condition-based auto-resume.

    This module runs outside the supervisor sweep to avoid slowing down
    the 30s reconcile loop.  Results are cached in a lightweight hashtable
    and queried synchronously by [should_attempt_resume].

    TLA+ model: [healthProbeOk] is an Environment variable updated by
    an independent async action.  The supervisor's [ResumeFromPause]
    action reads the cached value without performing I/O. *)

(** [is_healthy ~keeper_name] returns the cached health status for the
    given keeper.  Returns [false] when no probe result is available
    (Unknown) or the last probe reported Unhealthy. *)
val is_healthy : keeper_name:string -> bool

(** [check_cascade_health ~base_path] scans the registry and computes
    the failure ratio for each active cascade.  Returns a list of
    (cascade_name, is_healthy) pairs.  This function performs I/O and
    should be called from the probe fiber, not the supervisor sweep. *)
val check_cascade_health :
  base_path:string -> (string * bool) list

(** [start_probe ~sw ~base_path ~interval_sec] spawns a background Eio
    fiber that runs [check_cascade_health] every [interval_sec] seconds
    and updates the internal cache.  The fiber exits when [sw] is
    cancelled. *)
val start_probe :
  sw:Eio.Switch.t -> base_path:string -> interval_sec:float -> unit
