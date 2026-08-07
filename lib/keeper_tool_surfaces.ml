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

    This module stays dependency-light so spawned agents can share
    allowlists without pulling in the full public capability registry.
*)

open Masc_domain

let lookup_schemas_by_name_exn ~label all_schemas values =
  let requested =
    values
    |> List.map String.trim
    |> List.filter (fun value -> not (String.equal value ""))
    |> Json_util.dedupe_keep_order
  in
  let by_name = Hashtbl.create (List.length all_schemas) in
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
      if not (Hashtbl.mem by_name schema.name) then
        Hashtbl.add by_name schema.name schema)
    all_schemas;
  let missing =
    requested
    |> List.filter (fun tool_name -> not (Hashtbl.mem by_name tool_name))
  in
  (match missing with [] -> () | _ ->
    invalid_arg
      (Printf.sprintf "%s: unknown tool schema(s): %s" label
         (String.concat ", " missing)));
  (* Guard above ensures all names exist *)
  requested |> List.filter_map (Hashtbl.find_opt by_name)

let spawned_agent_public_tool_names : string list =
  Tool_catalog_surfaces.spawned_agent_surface_tools


