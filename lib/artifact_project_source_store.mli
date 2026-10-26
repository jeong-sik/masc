type error =
  | Invalid of string
  | Missing
  | Unavailable of string
  | Commit_uncertain of { id : string; message : string }
val error_message : error -> string
val read_metadata : base_path:string -> id:string -> (Artifact_project_source.t, error) result
(** Owned immutable metadata only; does not materialize source payloads. *)
val save : base_path:string -> author:string -> Artifact_project_source.request ->
  (Artifact_project_source.t, error) result
(** Store every file durably before the immutable metadata. A new save gets a new
    identity; a commit-uncertain outcome must be reconciled by reading its id. *)
val read : base_path:string -> id:string ->
  (Artifact_project_source.t * Artifact_project_source.request, error) result
(** Validate owned metadata and every content address before reconstructing the
    worker request. Missing/damaged referenced files are unavailable, not missing
    project sources. Authorization belongs to the eventual authenticated caller. *)
