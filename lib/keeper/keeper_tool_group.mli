(** The [keeper.tools] group vocabulary (RFC-0389). See the implementation
    for why this is a leaf. *)

type t =
  | Execute_group
  | Search_files_group
  | Filesystem_group
  | Board_group
  | Voice_group
  | Workspace_group
  | Surface_group
  | Memory_group
  | Meta_group
  | Core_group

val to_string : t -> string
(** The name as it appears in [keeper.tools.groups]. *)

val name : t -> string
(** Same as [to_string]; the reading the TOML round-trip uses. *)

val of_string : string -> t option
(** Strict inverse of [to_string]: [None] for any unknown name, so callers
    decide between rejecting (the TOML loader) and warning (a stale row read
    back from a store written by a future build). *)
