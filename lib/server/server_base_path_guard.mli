(** Startup guards for runtime base-path selection. *)

val implicit_base_path_resolution_source : string
(** Resolution marker used when no explicit base path was provided. *)

val guard_self_repo_base_path : string -> unit
(** [guard_self_repo_base_path base_path] aborts process startup when
    [base_path] points at the server source repository that produced the
    running executable. *)

val guard_implicit_base_path :
  resolution_source:string -> normalized_base_path:string -> unit
(** [guard_implicit_base_path ~resolution_source ~normalized_base_path]
    aborts process startup when the base path was selected implicitly. *)
