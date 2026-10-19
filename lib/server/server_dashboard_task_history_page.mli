(** One shared protocol for HTTP/1 and H2. No cached cursor pages. *)
type status = [ `OK | `Bad_request | `Conflict | `Service_unavailable ]
val read : config:Workspace.config -> task_id:string option ->
  limit:string option -> cursor:string option -> status * Yojson.Safe.t
(** [limit] is a required positive per-response demand, not a history cap.
    Original Task/workspace and physical continuation are checked by the
    producer. Failures never publish an advanced cursor or an empty success. *)
