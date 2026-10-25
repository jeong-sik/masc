(** Ephemeral, connection-bound draft presence and latest-state notifications.
    No timers, persisted presence, or author-to-presence inference. *)
type session
type error = Missing_session | Owner_mismatch
val join : base_path:string -> actor:string -> target:Artifact_draft.target -> session
val id : session -> string
val leave : session -> unit
val find : base_path:string -> actor:string -> target:Artifact_draft.target -> session_id:string -> (session, error) result
val position : session -> Artifact_document_engine.selection option -> (unit, error) result
val publish : base_path:string -> draft:Artifact_draft.t -> content:string -> unit
val observe : session -> (Yojson.Safe.t * unit Eio.Promise.t) option
