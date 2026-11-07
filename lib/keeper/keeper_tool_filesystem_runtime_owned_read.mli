(** The Read tool of [Keeper_tool_filesystem_runtime] for a file under an
    ownership root.

    [default_owned_target] picks the directory and the relative path of a read
    that names no [cwd]. [resolve_owned_read_target] returns the absolute
    target, or a refusal that names an empty path or a cwd that lies outside
    the ownership root, is not a directory, or is missing. [read_owned_bytes]
    reads the first [max_bytes] bytes of that target.
    [owned_read_failure_class] says whether a failed read is the caller's to
    correct or the runtime's, and [handle_owned_read_file_with_outcome] runs
    one Read and returns its tool outcome.
    [Keeper_tool_filesystem_runtime] includes this module. *)

val default_owned_target :
  ownership_root:string -> path:string -> string * string

val read_owned_bytes :
  ownership_root:string -> path:string -> ?cwd:string -> max_bytes:int -> unit ->
  (string, string) result

val handle_owned_read_file_with_outcome :
  ownership_root:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
