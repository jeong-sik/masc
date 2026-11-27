(** Observation-only filesystem-space facts.

    This module never admits, delays, pauses, or rejects Keeper work. It
    records actual typed [ENOSPC] failures, probes filesystem capacity via
    POSIX [statvfs(2)], and projects an observational health classification
    for [/health?full=1]. *)

type disk_snapshot =
  { path : string
  ; filesystem : string
  ; total_bytes : int
  ; used_bytes : int
  ; available_bytes : int
  ; capacity_percent : float
  ; available_percent : float
  ; mounted_on : string
  }

type snapshot_result =
  | Snapshot of disk_snapshot
  | Probe_error of string

(** Observational disk health classification. Never used to gate, throttle,
    or reject Keeper work. *)
type health_status =
  | Healthy
  | Low_space
  | Critical_space
  | Exhausted_enospc
  | Probe_unavailable

val low_space_available_pct : float
val critical_space_available_pct : float
val critical_space_available_bytes : int
val enospc_recent_window_sec : float

val health_status_to_string : health_status -> string
val classify_health :
  ?now:float ->
  enospc_observations:int ->
  last_enospc_ts:float option ->
  snapshot_result ->
  health_status

val note_exception : ?site:string -> exn -> unit
(** Record and log only typed [Unix_error (ENOSPC, _, _)]. *)

val reset_for_tests : unit -> unit
val observation_fields : unit -> (string * Yojson.Safe.t) list
val snapshot_json : ?now:float -> masc_root:string -> unit -> Yojson.Safe.t
