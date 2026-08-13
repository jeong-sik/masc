(** Capability-backed reader for the Agent Core execution-journal SSOT.

    Filesystem effects stop at this module.  Callers receive the pure typed
    projection from {!Keeper_agent_core_execution_inventory_core}; raw record
    payloads and filesystem paths are never returned. *)

type inventory = Keeper_agent_core_execution_inventory_core.t

type read_error =
  | Filesystem_unavailable
  | Journal_root_not_directory
  | Journal_root_unreadable

val read : base_path:string -> (inventory, read_error) result
(** Read a point-in-time startup/operator inventory.  A missing SSOT root is an
    empty inventory.  An unreadable or unsafe root is a typed failure. *)

val to_yojson : inventory -> Yojson.Safe.t
val read_error_to_string : read_error -> string
