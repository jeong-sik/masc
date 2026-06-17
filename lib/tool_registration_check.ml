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

(** Tool_registration_check — Startup validation of keeper tool policy coverage.

    Startup validation placeholder. Policy-driven validation removed
    with keeper_tool_policy_config deletion. *)

type validation_result = {
  orphan_toml : string list;
  uncovered : string list;
}

type policy_config = { configured_tools : string list }

let add_names names tbl =
  List.iter (fun name -> Hashtbl.replace tbl name ()) names;
  tbl

let registered_tool_names () =
  Config.raw_all_tool_schemas
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)

let registered_tool_name_set () =
  Hashtbl.create 512
  |> add_names (registered_tool_names ())

let validate () : validation_result =
  Log.Server.warn
    "tool_registration_check.validate is a placeholder; policy-driven startup \
     validation is disabled";
  { orphan_toml = []; uncovered = [] }

let log_validation_result (r : validation_result) =
  (match r.orphan_toml with
  | [] -> ()
  | _ ->
    Log.Server.warn "tool_policy unknown tool names (%d): %s"
      (List.length r.orphan_toml)
      (String.concat ", " (List.filteri (fun i _ -> i < 10) r.orphan_toml)));
  (match r.uncovered with
  | [] -> ()
  | _ ->
    Log.Server.info "tool_policy reverse coverage (%d): %s"
      (List.length r.uncovered)
      (String.concat ", " (List.filteri (fun i _ -> i < 10) r.uncovered)))
