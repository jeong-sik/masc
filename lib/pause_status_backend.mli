(** Pause-status projection for workspace/tool surfaces. *)

val keeper_pause_status_json : Workspace.config -> Yojson.Safe.t
(** Renders workspace keeper pause state.  The payload includes
    [keeper_names_known], [keeper_name_discovery_read_errors], and
    [read_errors] so unreadable keeper metadata is not collapsed into an
    authoritative "not paused" result. *)
