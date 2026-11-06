open Keeper_tool_filesystem_runtime_write_types

type created_directory_dispatch_fault =
  { fault_stage : created_directory_stage
  ; fault_exception : exn
  }

let created_directory_dispatch_fault_key
      : created_directory_dispatch_fault Eio.Fiber.key
  =
  Eio.Fiber.create_key ()
;;

let before_write_authorization_key : (unit -> unit) Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let before_edit_snapshot_key : (unit -> unit) Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let before_result_manifest_key : (unit -> unit) Eio.Fiber.key = Eio.Fiber.create_key ()
