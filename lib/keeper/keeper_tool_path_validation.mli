(** Path / working-dir validation helpers for keeper repair flows. *)

val is_safe_subpath : parent:string -> child:string -> bool
(** [is_safe_subpath ~parent ~child] returns [true] when [child] is exactly
    [parent] or is contained below [parent]. Inputs are expected to be
    normalized absolute paths. *)

val validate_target_file :
  working_dir:string ->
  target_file:string option ->
  (string option, string) result
(** Validate that an optional target file is relative and contained inside
    [working_dir]. *)

val resolve_playground_working_dir :
  agent_name:string ->
  base_path:string ->
  working_dir_arg:string ->
  (string, string) result
(** Resolve and validate a keeper repair working directory under that
    keeper's own playground. *)
