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
val set_item_health :
  keeper_name:string -> item_id:string ->
  health_status -> unit

(** [record_item_result ~keeper_name ~item_id ~success] updates health
    state based on turn outcome. Success -> Healthy, Failure -> Unhealthy. *)
val record_item_result :
  keeper_name:string -> item_id:string -> success:bool -> unit

(** {1 Backward-compatible per-keeper health (deprecated)} *)

(** [is_healthy ~keeper_name] returns true if ANY item for this keeper
    is Healthy. Deprecated: use [is_item_healthy] for per-item routing.
    Kept for existing callers that haven't migrated yet. *)
val is_healthy : keeper_name:string -> bool

(** [set_health ~keeper_name status] sets health for the legacy
    per-cascade key. Kept for the background probe fiber. *)
val set_health : keeper_name:string -> health_status -> unit

(** {1 Cascade health scan} *)

(** [check_cascade_health ~base_path] scans the registry and computes
    the failure ratio for each active cascade.  Returns a list of
    (cascade_name, is_healthy) pairs.  This function performs I/O and
    should be called from the probe fiber, not the supervisor sweep. *)
val check_cascade_health :
  base_path:string -> (string * bool) list

(** {1 Background probe fiber} *)

(** [start_probe ~sw ~base_path ~interval_sec] spawns a background Eio
    fiber that runs [check_cascade_health] every [interval_sec] seconds
    and updates the internal cache.  The fiber exits when [sw] is
    cancelled. *)
val start_probe :
  sw:Eio.Switch.t -> base_path:string -> interval_sec:float -> unit
