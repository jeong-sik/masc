(** The seams of [Keeper_tool_filesystem_runtime] that tests bind through its
    [For_testing] module.

    [created_directory_dispatch_fault_key] carries a
    [created_directory_dispatch_fault], which names a stage of the creation of
    a directory and the exception to raise there.
    [before_write_authorization_key], [before_edit_snapshot_key] and
    [before_result_manifest_key] carry a hook that runs before a write is
    authorized, before an edit snapshot is stored, and before the artifact
    manifest of a successful write is attached.
    [Keeper_tool_filesystem_runtime] includes this module. *)
open Keeper_tool_filesystem_runtime_write_types

type created_directory_dispatch_fault =
  { fault_stage : created_directory_stage
  ; fault_exception : exn
  }

val created_directory_dispatch_fault_key :
  created_directory_dispatch_fault Eio.Fiber.key

val before_write_authorization_key : (unit -> unit) Eio.Fiber.key

val before_edit_snapshot_key : (unit -> unit) Eio.Fiber.key

val before_result_manifest_key : (unit -> unit) Eio.Fiber.key
