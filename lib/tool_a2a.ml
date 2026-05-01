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

(** A2A tools - Agent-to-Agent protocol.
    All tool handlers removed (poll_events, heartbeat_result pruned).
    Module retained for dispatch interface compatibility. *)

(* Context required by a2a tools *)
type context = {
  config: Coord.config;
  agent_name: string;
}

type tool_result = bool * string

(* Dispatch function - returns None if tool not handled *)
let dispatch _ctx ~name:_ ~args:_ : tool_result option =
  None

let schemas : Types.tool_schema list = []

let tool_required_permission _name = None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_a2a
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
