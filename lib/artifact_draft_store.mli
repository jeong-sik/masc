type error =
  | Invalid of string
  | Missing
  | Generation_conflict of Artifact_draft.target
  | Artifact_error of Published_artifact_store.error
  | Transform_error of Artifact_document_engine.error
  | Unavailable of string
  | Commit_uncertain of Artifact_draft.t
type view =
  { draft : Artifact_draft.t; content : string
  ; selection : (Artifact_draft.selection * int * int) option }
val error_message : error -> string
val view_to_json : view -> Yojson.Safe.t
val read : ?runner:Artifact_document_engine.runner -> base_path:string -> artifact_id:string -> unit -> (view, error) result
val execute : ?runner:Artifact_document_engine.runner -> base_path:string -> actor:string -> Artifact_draft.command -> (view, error) result
