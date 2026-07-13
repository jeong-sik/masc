(** Exact Keeper tool-schema projection.

    This module validates the descriptor/registry join and exposes the complete
    descriptor-declared model surface. It does not classify tool meaning,
    select a subset for a turn, or authorize execution. *)

module StringSet = Set_util.StringSet

let tool_name_set names =
  List.fold_left (fun names name -> StringSet.add name names) StringSet.empty names
;;

let dedupe_tool_schemas (schemas : Masc_domain.tool_schema list) =
  let _, schemas_rev =
    List.fold_left
      (fun (seen, schemas_rev) (schema : Masc_domain.tool_schema) ->
         if StringSet.mem schema.name seen
         then seen, schemas_rev
         else StringSet.add schema.name seen, schema :: schemas_rev)
      (StringSet.empty, [])
      schemas
  in
  List.rev schemas_rev
;;

let missing_canonical_schema_names descriptors =
  descriptors
  |> List.filter_map (fun (descriptor : Keeper_tool_descriptor.t) ->
    match descriptor.input_schema_source with
    | Keeper_tool_descriptor.Missing_canonical_registry ->
      Some descriptor.internal_name
    | Keeper_tool_descriptor.Descriptor_owned
    | Keeper_tool_descriptor.Canonical_registry -> None)
  |> List.sort_uniq String.compare
;;

let descriptors_for_handler name =
  Keeper_tool_descriptor.descriptors_for_internal name
;;

let registered_handler_schemas schemas =
  schemas
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
    match descriptors_for_handler schema.name with
    | [] -> false
    | _ :: _ -> true)
  |> dedupe_tool_schemas
;;

let registered_handler_schema_names () =
  Keeper_tool_registry.masc_schemas_snapshot ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;

let duplicate_descriptor_handler_names schemas =
  schemas
  |> List.filter_map (fun (schema : Masc_domain.tool_schema) ->
    match descriptors_for_handler schema.name with
    | _ :: _ :: _ -> Some schema.name
    | [] | [ _ ] -> None)
  |> List.sort_uniq String.compare
;;

let invalid_model_schema_details descriptors =
  descriptors
  |> List.filter_map (fun (descriptor : Keeper_tool_descriptor.t) ->
    match Keeper_tool_descriptor.model_schema_errors descriptor with
    | [] -> None
    | errors ->
      Some
        (`Assoc
           [ "tool_name", `String descriptor.internal_name
           ; "errors", Json_util.json_string_list errors
           ]))
;;

let inject_masc_schemas schemas =
  let registered = registered_handler_schemas schemas in
  let descriptors = Keeper_tool_descriptor.all_descriptors () in
  let missing_schemas = missing_canonical_schema_names descriptors in
  let invalid_schemas = invalid_model_schema_details descriptors in
  let duplicates = duplicate_descriptor_handler_names registered in
  (match missing_schemas, invalid_schemas, duplicates with
   | [], [], [] -> ()
   | _, _, _ ->
     Log.Keeper.emit
       Log.Error
       ~keeper_name:"system"
       ~category:Log.Tool
       ~details:
         (`Assoc
            [ "error_kind", `String "invalid_keeper_tool_descriptor_coverage"
            ; "missing_schema_tool_names", Json_util.json_string_list missing_schemas
            ; "invalid_schemas", `List invalid_schemas
            ; "duplicate_tool_names", Json_util.json_string_list duplicates
            ])
       "keeper tool descriptor join contains excluded entries");
  Keeper_tool_registry.set_masc_schemas registered
;;

let all_keeper_model_tool_schemas () =
  Keeper_tool_descriptor.model_visible_descriptors ()
  |> List.concat_map (fun (descriptor : Keeper_tool_descriptor.t) ->
    Keeper_tool_descriptor.keeper_model_names descriptor
    |> List.map (fun name ->
      { Masc_domain.name
      ; description = descriptor.description
      ; input_schema = descriptor.input_schema
      }))
  |> dedupe_tool_schemas
;;

let keeper_model_tool_schemas = all_keeper_model_tool_schemas

let keeper_model_tool_names () =
  keeper_model_tool_schemas ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;
