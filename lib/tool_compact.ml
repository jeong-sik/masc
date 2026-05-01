open Base
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

(** Tool_compact — OAS-backed compaction pipeline.

    masc_compact_context removed: pruned from surfaces.
    Compaction is now handled internally by OAS agent lifecycle.

    @since 2.95.0 — Issue #1441 *)

(* All schemas removed — tool pruned *)
let schemas : Types.tool_schema list = []

type tool_result = bool * string

let dispatch ~name:_ ~args:_ : tool_result option = None
