(** Dashboard_keeper_feature_proof -- keeper autonomy feature proof report.

    Combines persisted keeper runtime counters with the keeper tool-call
    quality aggregate to show which autonomy feature groups have current,
    executable evidence and which still need proof. *)

val json :
  config:Coord.config ->
  ?n:int ->
  ?window_hours:float ->
  ?success_threshold_pct:float ->
  ?now:float ->
  unit ->
  Yojson.Safe.t
(** Build the [/api/v1/dashboard/keeper-feature-proof] payload.

    [success_threshold_pct] is the minimum per-tool success percentage
    needed for a required tool to count as passing. The default is 80.0.
    [now] exists for deterministic tests; production callers omit it. *)
