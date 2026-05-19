(** CDAL runtime health projection.

    Surfaces whether the proof/verdict writer appears active, dormant,
    missing, writing verdicts without task scope, or leaving stale incomplete
    proof bundles behind. *)

val snapshot_json :
  ?base_dir:string ->
  ?proof_root:string ->
  ?now:float ->
  ?stale_age_seconds:float ->
  ?recent_limit:int ->
  ?proof_scan_limit:int ->
  ?stale_incomplete_run_seconds:float ->
  unit ->
  Yojson.Safe.t
