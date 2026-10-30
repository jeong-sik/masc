(** Whole-tree revisions of builtin Skill packages. A revision covers every
    directory, file path, file digest and mode, so two trees with one revision
    hold the same files. Nothing here reads the filesystem. *)

type entry_kind = Directory | File

type entry = { kind : entry_kind; path : string; mode : int; digest : string }
(** [path] is relative to the package root and [""] for the root itself.
    [digest] is the hex SHA-256 of a file's bytes and [""] for a directory. *)

val release_mode : entry_kind -> int
(** The mode every published directory and file has. *)

val file_digest : string -> string
(** Hex SHA-256 of a file's bytes. *)

val revision : entry list -> string

val bundled_entries : (string * string) list -> entry list
(** The entries of a package made of these relative files and their bytes,
    with release modes. *)

val with_release_modes : entry list -> entry list

val recorded : string -> string
(** The content of a receipt or move note that records this revision. *)
