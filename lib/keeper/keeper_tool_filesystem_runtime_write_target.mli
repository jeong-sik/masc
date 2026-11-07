(** The file system pieces that a write of [Keeper_tool_filesystem_runtime]
    stands on.

    [resolve_write_attribution] is [Keeper_write_attribution.resolve].
    [created_file_permissions] and [created_directory_permissions] are the
    permissions of a file and of a directory that a write creates.
    [replacement_file_permissions] gives the permissions of the file that
    replaces [leaf] in [parent_dir]: those of an existing regular file,
    [created_file_permissions] for a symbolic link or a missing entry, and an
    error for any other kind of entry. [same_file_resource] compares the
    device and the inode of two stats, and [load_open_file] reads an open file
    to its end.
    [with_confined_write_parent] opens the root of a confined path and its
    deepest existing parent directory, then calls its continuation with them,
    the missing parent components and the leaf; it is built from
    [with_deepest_existing_parent] and [split_leaf_components].
    [with_open_directory_components] opens a chain of directories below a
    parent and calls [on_missing] when one of them does not exist.
    [Keeper_tool_filesystem_runtime] includes this module. *)

val resolve_write_attribution :
  base_dir:string -> file_path:string -> Agent_observation.file_attribution

val created_file_permissions : int

val created_directory_permissions : int

val same_file_resource : Eio.File.Stat.t -> Eio.File.Stat.t -> bool

val replacement_file_permissions :
  parent_dir:[> Eio.Fs.dir_ty ] Eio.Path.t ->
  leaf:string -> (int, string) result

val load_open_file : [> Eio.Flow.source_ty ] Eio.Std.r -> string

val with_open_directory_components :
  on_missing:(unit -> 'a) ->
  ([< `Close | `Dir > `Dir ] as 'b) Eio.Path.t ->
  string list -> ('b Eio.Path.t -> 'a) -> 'a

val split_leaf_components : 'a list -> ('a list * 'a) option

val with_confined_write_parent :
  Keeper_alerting_path.confined_path ->
  (root_dir:([< `Close | `Dir > `Dir ] as 'a) Eio.Path.t ->
   parent_dir:'a Eio.Path.t ->
   parent_components:string list ->
   missing_parents:string list -> leaf:string -> ('b, string) result) ->
  ('b, string) result
