(** Autoresearch_file — Target file validation and atomic code change
    application.

    Validates file paths (no [..] traversal, no symlink escape outside
    [workdir]), reads file contents, and writes new content atomically
    via temp-file rename.

    @since 2.80.0 *)

(** [has_path_traversal path] returns [true] when [path] is exactly
    [..], contains [../], or ends with [/..]. *)
val has_path_traversal : string -> bool

(** [resolve_target_file_path ~workdir target_file] returns the
    absolute path inside [workdir] without requiring the file to
    exist. Existing parent directories are resolved via [realpath];
    symlink escapes are rejected. Errors on empty / absolute /
    traversal-containing [target_file]. *)
val resolve_target_file_path :
  workdir:string -> string -> (string, string) result

(** [validate_target_file ~workdir target_file] resolves the path and
    additionally requires the file to exist, be a regular file, and
    stay inside [workdir] under [realpath]. Returns the resolved
    absolute path. *)
val validate_target_file :
  workdir:string -> string -> (string, string) result

(** Load a file in full. *)
val read_file : string -> string

(** [apply_code_change ~workdir ~target_file ~new_content] validates
    the path, reads the original content, then atomically replaces
    [target_file] with [new_content] via a same-directory temp file.
    Returns [Ok original_content] on success (for rollback reference)
    or [Error reason]. *)
val apply_code_change :
  workdir:string ->
  target_file:string ->
  new_content:string ->
  (string, string) result
