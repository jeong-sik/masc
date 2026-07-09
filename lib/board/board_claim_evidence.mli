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

(** [post_has_high_risk_evidence post_id] scans the sidecar ledger and
    returns [true] if any record targeting [post_id] carries typed claims
    beyond [opinion_or_routing] — i.e. artifact_exists, artifact_missing,
    artifact_created, artifact_endorsed, verification_endorsement,
    task_completion, pr_state, or retraction_ack.

    This is used by the board claim gate to determine whether a post
    should be treated as high-risk even when the replying keeper does
    not declare explicit claims in their tool arguments. *)
val post_has_high_risk_evidence : string -> bool
