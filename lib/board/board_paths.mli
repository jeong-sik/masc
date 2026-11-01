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

type persisted_file = Posts | Comments | Reactions | Sub_boards | Votes
val file_path : workspace_masc_dir:string -> persisted_file -> string
val posts_file : workspace_masc_dir:string -> string
(** [file_path ~workspace_masc_dir Posts]. The shared blob store's maintenance
    pass takes this to read every workspace's posts
    ([Tool_blob_maintenance.run ~board_posts_file]); that library sits below
    Board and does not repeat the name. *)
val store_file_path : Board_types.store -> persisted_file -> string
(** Every read and write uses the store's captured workspace. *)
val persist_path : Board_types.store -> string
val comments_path : Board_types.store -> string
val reactions_path : Board_types.store -> string
val sub_boards_path : Board_types.store -> string
val ensure_dir : string -> unit
val ensure_masc_dir : Board_types.store -> unit
