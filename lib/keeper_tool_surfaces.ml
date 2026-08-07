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
module Random = Stdlib.Random

(** Keeper_tool_surfaces — lightweight internal tool surface definitions.

    This module stays dependency-light so spawned agents, local workers, and
    strict worker flows can share allowlists without pulling in the full public
    capability registry.
*)

open Masc_domain

module SS = Set_util.StringSet


let dedupe_schemas (schemas : Masc_domain.tool_schema list) =
  let unique, _ =
    List.fold_left
      (fun (acc, seen) (schema : Masc_domain.tool_schema) ->
        if SS.mem schema.name seen then (acc, seen)
        else (schema :: acc, SS.add schema.name seen))
      ([], SS.empty)
      schemas
  in
  List.rev unique

let spawned_agent_public_tool_names : string list =
  Tool_catalog_surfaces.spawned_agent_surface_tools


