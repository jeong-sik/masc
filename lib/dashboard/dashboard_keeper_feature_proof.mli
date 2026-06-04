(** Dashboard_keeper_feature_proof -- keeper autonomy feature proof report.

    Combines persisted keeper runtime counters with decision-log evidence to
    show which autonomy feature groups have current behavior evidence and which
    still need proof. *)

val json :
  config:Workspace.config ->
  ?window_hours:float ->
  ?now:float ->
  unit ->
  Yojson.Safe.t
(** Build the [/api/v1/dashboard/keeper-feature-proof] payload.

    [now] exists for deterministic tests; production callers omit it. *)
