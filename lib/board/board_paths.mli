(** Board persistence paths.

    Configuration-root helpers are used when capturing a store at startup.
    Every store file and directory mutation uses its captured workspace. *)

val board_base_path : unit -> string
val board_masc_dir : unit -> string
val capture_workspace_masc_dir : string -> string
(** Capture an explicit workspace directory. A relative input is anchored to
    the current working directory synchronously before the single
    [Fs_compat.realpath_lenient] call. Filesystem names are preserved without
    trimming; no directory is created. This binds a path, not ongoing symlink
    or resource identity.

    @raise Invalid_argument if the input is exactly empty. *)

type persisted_file = Posts | Comments | Reactions | Sub_boards | Votes | Deletion
val file_path : workspace_masc_dir:string -> persisted_file -> string
val posts_file : workspace_masc_dir:string -> string
(** [file_path ~workspace_masc_dir Posts]. *)
val workspace_masc_dir : Board_types.store -> string
(** Derive the state path from the store's sole immutable BasePath binding.
    This getter grants no filesystem authority. *)
val check_workspace :
  Board_types.store -> (unit, Board_workspace_binding.rejection) result
(** Recheck the captured root and any retained actual state-directory witness.
    Caller owns the persistence lock or a quiescent loader scope. *)
val observe_workspace :
  Board_types.store -> (Board_workspace_binding.observation, Board_workspace_binding.rejection) result
(** Same check, retaining an actual Present directory in the store's sole
    binding via an immutable refinement. Caller owns the persistence lock or
    a quiescent loader scope, including when no posts have been loaded. *)
val store_file_path : Board_types.store -> persisted_file -> string
(** Every read and write uses the store's captured workspace. *)
val persist_path : Board_types.store -> string
val comments_path : Board_types.store -> string
val reactions_path : Board_types.store -> string
val sub_boards_path : Board_types.store -> string
val ensure_dir : string -> unit
val ensure_masc_dir :
  Board_types.store -> (unit, Board_workspace_binding.rejection) result
(** Check before directory creation and retain an actual Present observation
    afterward, before payload I/O. A raised exception, including a reserved
    cause, comes back as a [Raised] rejection. A later refusal can follow
    directory creation; it is not a claim that all filesystem effects were
    absent. *)

val persisted_filename : persisted_file -> string
(** The basename {!file_path} gives a file below the workspace. *)
