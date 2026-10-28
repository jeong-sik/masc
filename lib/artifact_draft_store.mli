type error =
  | Invalid of string
  | Missing
  | Generation_conflict of Artifact_draft.target
  | Discussion_conflict of string
  | Artifact_error of Published_artifact_store.error
  | Transform_error of Artifact_document_engine.error
  | Unavailable of string
  | Commit_uncertain of Artifact_draft.t
type view =
  { draft : Artifact_draft.t; content : string
  ; selection : (Artifact_draft.selection * int * int) option }
type checkpoint_outcome = Checkpointed of view | Already_current of view
type checkpoint_error =
  | Draft_error of error
  | Sequence_conflict of { expected : int; actual : int }
  | Draft_snapshot_changed
  | Published_content_mismatch
  | Published_base_mismatch
  | Published_format_mismatch
val error_message : error -> string
val checkpoint_error_message : checkpoint_error -> string
val view_to_json : view -> Yojson.Safe.t
val read : ?runner:Artifact_document_engine.runner -> base_path:string -> artifact_id:string -> unit -> (view, error) result
val execute : ?runner:Artifact_document_engine.runner -> base_path:string -> actor:string -> Artifact_draft.command -> (view, error) result
val checkpoint : ?runner:Artifact_document_engine.runner -> base_path:string -> actor:string ->
  target:Artifact_draft.target -> expected_sequence:int -> revision:int -> unit ->
  (checkpoint_outcome, checkpoint_error) result
(** Bind a shared draft to an exact latest publication. A change requires the
    same target, observed sequence, draft snapshot, base format and byte-identical
    published source. Publication and draft use their existing locks in that order; an
    uncertain draft commit is returned without retry. [Already_current]
    observes that the requested publication is already the draft's base; it
    does not certify which request installed it or discard later edits. A later
    publication or draft edit can occur after this observation returns. *)
