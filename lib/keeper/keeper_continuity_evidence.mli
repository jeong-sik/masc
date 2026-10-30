(** Read-only owner exports. These observations neither retire history nor
    certify remote receipt or semantic preservation. *)

val completed_boundary :
  config:Workspace.config -> keeper:string -> turn_ref:Ids.Turn_ref.t -> Yojson.Safe.t
(** Exact typed completed boundary in the trace's latest history generation.
    Missing/unreadable positions are explicit unavailable observations. *)

val read :
  config:Workspace.config -> keeper:string -> turn_ref:Ids.Turn_ref.t ->
  (Yojson.Safe.t, Keeper_provider_input_snapshot.read_error) result
(** Requires the requested turn's canonical manifest. Includes every retained
    attributed serialization, its immutable selection, an exact completed
    boundary and a current saved-state observation for readiness only. The
    caller provides the existing provider-input administrator boundary. *)
