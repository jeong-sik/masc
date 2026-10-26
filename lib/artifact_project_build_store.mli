type error =
  | Invalid of string
  | Missing
  | Source_error of Artifact_project_source_store.error
  | Unavailable of string
  | Commit_uncertain of { id : string; message : string }
type file = { path : string; body : Tool_output.artifact_ref; content : string }
val error_message : error -> string
val save : base_path:string -> source_id:string -> author:string -> Artifact_project_build.input ->
  (Artifact_project_build.t, error) result
(** Verify the existing source and worker receipt; durably store lock and all
    output files before publishing the new immutable build metadata. *)
val read : base_path:string -> id:string -> (Artifact_project_build.t, error) result
(** Read metadata and source association. Payloads are validated when read. *)
val restore : base_path:string -> id:string -> (Artifact_project_build.input, error) result
(** Read all payloads, validate them and reconstruct the worker result. *)
val read_file : base_path:string -> id:string -> path:string option ->
  (Artifact_project_build.t * file, error) result
(** Read one exact graph path, or the entry HTML for None. This function does not
    execute content or serve HTTP. Auth/ACL and isolated browser origins belong
    to the eventual caller; source and dependency records may contain secrets. *)
