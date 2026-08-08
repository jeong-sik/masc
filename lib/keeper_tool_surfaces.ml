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
