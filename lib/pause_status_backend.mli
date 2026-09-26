(** Pause-status projection for workspace/tool surfaces. *)

val keeper_pause_status_json : Workspace.config -> (Yojson.Safe.t, string) result
(** [Error] when the Keeper directory could not be read. An unread census
    cannot establish that no Keeper is paused. *)
