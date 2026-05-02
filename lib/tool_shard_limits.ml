module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** SSOT constants for tool schemas and runtime handlers that would
    otherwise form a dependency cycle (Tool_shard ↔ Keeper_exec_fs).

    These integers live in a leaf module with no dependencies so both
    sides can import the same value. *)

let keeper_fs_read_default_max_bytes = 20_000
let keeper_fs_read_default_max_bytes_string =
  Int.to_string keeper_fs_read_default_max_bytes
