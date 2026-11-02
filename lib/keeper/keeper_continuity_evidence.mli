(** Read-only owner exports. These observations neither retire history nor
    certify remote receipt or semantic preservation. *)

val schema : string
(** Canonical JSON schema identifier ([masc.keeper-continuity-evidence.v1]). *)

val max_request_scan_rows : int
(** Maximum backward lookback rows inspected in [Continuity_requests] before
    failing closed as unavailable. *)

val completed_boundary :
  config:Workspace.config -> keeper:string -> turn_ref:Ids.Turn_ref.t -> Yojson.Safe.t
(** Exact typed completed boundary in the trace's latest history generation.
    When multiple records in that generation state an atom position for
    [turn_ref], the latest record wins; a subsequent [History_restarted]
    for the same trace clears earlier generations. Missing or unreadable
    positions are explicit unavailable observations. *)

val read :
  config:Workspace.config -> keeper:string -> turn_ref:Ids.Turn_ref.t ->
  (Yojson.Safe.t, Keeper_provider_input_snapshot.read_error) result
(** Requires the requested turn's canonical manifest. Includes every retained
    attributed [masc.continuity-request.v3] serialization for [turn_ref]
    (skipping legacy [v1]/[v2] rows and explicitly unbound [turn_ref: null]
    rows while recording [scanned_rows] and [skipped_unattributed_rows] and
    failing closed on malformed rows, owner mismatch, or exceeding
    [max_request_scan_rows]), its immutable selection, an exact completed
    boundary and a current saved-state observation for readiness only. The
    caller provides the existing provider-input administrator boundary. *)
