type error =
  | Result_not_object
  | Result_absent
  | Export_projection_absent
  | Export_unavailable of string
  | Export_value_absent of string

let error_to_string = function
  | Result_not_object -> "canonical child result is not a structured object"
  | Result_absent -> "canonical child result is absent"
  | Export_projection_absent -> "canonical child result has no export projection"
  | Export_unavailable name -> "canonical child export is unavailable: " ^ name
  | Export_value_absent name -> "canonical child export has no value: " ^ name

open Result.Syntax

let select ~exports data =
  let* fields = match data with
    | `Assoc fields -> Ok fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error Result_not_object in
  let* available_exports = match List.assoc_opt "result" fields with
    | Some (`Assoc fields) ->
      (match List.assoc_opt "exports" fields with
       | Some (`Assoc fields) -> Ok fields
       | None when exports = [] -> Ok []
       | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
         Error Export_projection_absent)
    | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
      Error Result_absent in
  let rec collect reversed = function
    | [] -> Ok (List.rev reversed)
    | (export : Keeper_tool_plan.export) :: rest ->
      let* value = match List.assoc_opt export.name available_exports with
        | Some (`Assoc fields) when List.assoc_opt "available" fields = Some (`Bool true) ->
          (match List.assoc_opt "value" fields with
           | Some value -> Ok value
           | None -> Error (Export_value_absent export.name))
        | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) ->
          Error (Export_unavailable export.name) in
      collect ((export.name, value) :: reversed) rest in
  collect [] exports
