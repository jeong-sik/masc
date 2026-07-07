type projection_state =
  | Needs_evidence
  | Source_snapshot_stale
  | Artifact_missing
  | Verified

type projection =
  { target_post_id : string
  ; state : projection_state
  ; total_count : int
  ; allowed_count : int
  ; rejected_count : int
  ; artifact_missing_count : int
  ; artifact_unknown_count : int
  ; missing_source_snapshot_count : int
  ; stale_source_snapshot_count : int
  ; artifact_not_verified_count : int
  ; latest_decision : string option
  ; latest_recorded_at : float option
  }

val sidecar_filename : string
val sidecar_path : unit -> string
val projection_state_to_string : projection_state -> string
val projection_to_yojson : projection -> Yojson.Safe.t
val projection_lookup : unit -> string -> projection option
