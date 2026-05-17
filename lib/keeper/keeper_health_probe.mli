(** Asynchronous health probe for condition-based auto-resume.

    RFC-0041 Phase B2: migrated from per-cascade cache keys to
    per-keeper, per-item (string * string) keys.

    TLA+ model: [healthProbeOk] is an Environment variable updated by
    an independent async action.  The supervisor's [ResumeFromPause]
    action reads the cached value without performing I/O. *)

(** Health status variants. *)
type health_status =
  | Unknown
  | Healthy
  | Unhealthy of string

(** {1 Per-item health (RFC-0041)} *)

(** [is_item_healthy ~keeper_name ~item_id] returns the cached health
    status for the specific keeper+item pair.
    Returns [false] when no probe result is available (Unknown) or
    the last probe reported Unhealthy. *)
val is_item_healthy : keeper_name:string -> item_id:string -> bool

(** [set_item_health ~keeper_name ~item_id status] updates the cache
    for a specific keeper+item pair. *)
val set_item_health : keeper_name:string -> item_id:string -> health_status -> unit

(** [record_item_result ~keeper_name ~item_id ~success] updates health
    state based on turn outcome. Success -> Healthy, Failure -> Unhealthy. *)
val record_item_result : keeper_name:string -> item_id:string -> success:bool -> unit

(** {1 Phase-based health predicate} *)

(** [is_terminal_unhealthy phase] returns true only for terminal
    unhealthy phases (Dead, Zombie, Crashed).  All other phases
    including Restarting are treated as healthy for cascade ratio
    purposes.  Exhaustive match ensures compiler catches omissions
    when new phase variants are added. *)
val is_terminal_unhealthy : Keeper_state_machine.phase -> bool

(** {1 Cascade health scan} *)

(** [max_failed_allowed_for_cascade ~total] returns the maximum number
    of terminal-unhealthy keepers (Dead/Zombie/Crashed) a cascade of
    size [total] can hold while still being treated as healthy.
    Formula: [max 1 (total / 10)] — one keeper down is always allowed,
    larger cascades scale at 10%.  Exposed so tests and other callers
    can derive the same admission threshold without duplicating the
    arithmetic. *)
val max_failed_allowed_for_cascade : total:int -> int

(** [check_cascade_health ~base_path] scans the registry and computes
    the health status of each active cascade.  Returns a list of
    (cascade_name, is_healthy) pairs.  A keeper is counted as failed
    only when its phase is Dead, Zombie, or Crashed — not based on
    restart_count, which is monotonic and would cause permanent
    cascade pollution.  Healthy iff
    [failed <= max_failed_allowed_for_cascade ~total].  This function
    performs I/O and should be called from the probe fiber, not the
    supervisor sweep. *)
val check_cascade_health : base_path:string -> (string * bool) list

(** [get_cascade_status ~cascade_name] returns the cached cascade-level
    [health_status] written by [run_once].  This preserves the [Unknown]
    case so the supervisor's auto-resume guard can distinguish
    "no probe data yet" from
    "probe observed restart pressure" and treat the former
    permissively.

    Background: prior to wiring this distinction, the supervisor's
    Phase 3.5 guard collapsed [Unknown] and [Unhealthy] to the same
    boolean result — turning the boot-time cold-cache window into a
    permanent auto-resume lockout for every cascade. *)
val get_cascade_status : cascade_name:string -> health_status

(** [run_once ~base_path] runs [check_cascade_health] and writes the
    results into the cascade cache.  Idempotent and bounded (registry
    scan, no I/O).  Safe to call from the supervisor sweep on every
    beat — [Keeper_supervisor.sweep_and_recover] does so to keep the
    cache live without depending on the background fiber. *)
val run_once : base_path:string -> unit

(** {1 Background probe fiber} *)

(** [start_probe ~sw ~base_path ~interval_sec ~clock] spawns a background Eio
    fiber that runs [check_cascade_health] every [interval_sec] seconds
    and updates the internal cache.  The fiber exits when [sw] is
    cancelled.  Currently unused — the supervisor calls [run_once]
    inline.  [clock] must be an Eio time clock (typically from the
    fiber's environment).  Retained for future use when a faster cadence
    than the 30 s sweep is needed. *)
val start_probe : sw:Eio.Switch.t -> base_path:string -> interval_sec:float -> clock:float Eio.Time.clock_ty Eio.Resource.t -> unit
