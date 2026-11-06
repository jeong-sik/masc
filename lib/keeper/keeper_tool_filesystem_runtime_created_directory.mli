(** The creation of the missing parent directories of a write in
    [Keeper_tool_filesystem_runtime].

    [created_directory_operation] runs one step of the creation of a
    directory and returns the failure of its stage instead of raising; only a
    cancellation is raised again. [sync_created_directory] syncs a directory
    and reports the outcome.
    [create_and_commit_directory_component] creates one directory below
    [parent_dir], validates the capability it opens on it, applies the
    permissions, and syncs the child and the parent. It returns the opened
    child only when every step succeeded, together with the
    [created_directory_commit] that records the effect.
    [with_created_parent_directories] creates the missing components one by
    one and calls its continuation with the deepest directory and the commits.
    It calls [on_interrupted] with the commit of a directory it created when a
    cancellation or an exception interrupts the work that follows.
    [Keeper_tool_filesystem_runtime] includes this module. *)
open Keeper_tool_filesystem_runtime_write_types

val with_created_parent_directories :
  on_interrupted:(created_directory_commit ->
                  'a) ->
  permissions:int ->
  ([< `Close | `Dir > `Dir ] as 'b) Eio.Path.t ->
  string list ->
  (created_parents:created_directory_commit
                   list ->
   'b Eio.Path.t ->
   ('c, content_write_error)
   result) ->
  ('c, content_write_error)
  result
