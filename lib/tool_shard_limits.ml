(** SSOT constants for tool schemas and runtime handlers that would
    otherwise form a dependency cycle (Tool_shard ↔ Keeper_exec_fs).

    These integers live in a leaf module with no dependencies so both
    sides can import the same value. *)

let keeper_fs_read_default_max_bytes = 20_000
let keeper_fs_read_default_max_bytes_string =
  string_of_int keeper_fs_read_default_max_bytes
