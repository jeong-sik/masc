(** Ephemeral, connection-bound draft presence and latest-state notifications.
    No timers, persisted presence, or author-to-presence inference. *)
type source = Dashboard_connection | Keeper_turn of Ids.Turn_ref.t
type session
type error = Missing_session | Owner_mismatch
val join : base_path:string -> actor:string -> source:source -> target:Artifact_draft.target -> session
val id : session -> string
val leave : session -> unit
val find : base_path:string -> actor:string -> target:Artifact_draft.target -> session_id:string -> (session, error) result
val position : session -> Artifact_document_engine.selection option -> (unit, error) result
val publish : base_path:string -> draft:Artifact_draft.t -> content:string -> unit
val observe : session -> (Yojson.Safe.t * unit Eio.Promise.t) option
(** A session belongs to one connection's observing loop. Its first available
    document and each newer document sequence are included once; presence-only
    frames contain [document = null]. A new connection joins a fresh session,
    so its first available document is never borrowed from another observer.
    [None] means the session is closed, not that the document is unchanged.
    The returned pulse is captured with the frame under the room mutex. *)
