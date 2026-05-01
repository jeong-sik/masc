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

(** Tool_token — parse-once proof that a tool name exists in a dispatch table.

    See [tool_token.mli] for API documentation. *)

type t = { name : string; minted_at : float }

let mint_with ~validate ~name =
  if validate name then
    Ok { name; minted_at = Unix.gettimeofday () }
  else
    Error (Printf.sprintf "not in current tool set: %s" name)


