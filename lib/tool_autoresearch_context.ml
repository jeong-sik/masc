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

(** Shared context for autoresearch tool handlers. *)

type t = {
  base_path : string;
  agent_name : string option;
  start_operation :
    (goal:string ->
    target_file:string ->
    (Yojson.Safe.t, string) Stdlib.result)
    option;
  config : Coord.config option;
  sw : Eio.Switch.t option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}
