(** CDAL runtime health projection.

    Surfaces whether the proof/verdict writer appears active, dormant,
    missing, or still writing verdicts without task scope. *)

val snapshot_json :
  ?base_dir:string ->
  ?proof_root:string ->
  ?now:float ->
  ?stale_age_seconds:float ->
  ?recent_limit:int ->
  unit ->
  Yojson.Safe.t
