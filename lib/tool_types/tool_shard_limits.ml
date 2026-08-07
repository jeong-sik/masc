(** SSOT constants for tool schemas and runtime handlers that would
    otherwise form a dependency cycle (Tool_shard ↔ Keeper_tool_filesystem_runtime).

    These integers live in a leaf module with no dependencies so both
    sides can import the same value. *)

let read_file_default_max_bytes = 20_000
let read_file_default_max_bytes_string =
  Int.to_string read_file_default_max_bytes
