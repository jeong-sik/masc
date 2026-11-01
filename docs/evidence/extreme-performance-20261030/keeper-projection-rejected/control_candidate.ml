open Fixture_types
include Control
let find_row rows name =
  List.find_opt
    (fun (row : Decode.keeper_runtime) -> String.equal row.kr_name name)
    rows

let liveness_of_roster roster name =
  match roster with
  | Roster_invalid { observed; errors; complete } -> (
      match List.assoc_opt name errors with
      | Some detail -> Invalid detail
      | None -> (match find_row observed name with
          | Some row -> Present row
          | None -> if complete then Absent else Unobserved))
  | Roster_unobserved -> Unobserved
  | Roster_partial { observed; total = _ } -> (
      match find_row observed name with
      | Some row -> Present row
      | None ->
          (* Rows are missing from this roster, so this name may be one of
             them. That is not evidence of a stopped fiber. *)
          Unobserved)
  | Roster_complete rows -> (
      match find_row rows name with
      | Some row -> Present row
      | None -> Absent)

module Roster_names = Map.Make (String)

let liveness_reader roster =
  let observed, errors, missing =
    match roster with
    | Roster_unobserved -> [], [], Unobserved
    | Roster_partial { observed; total = _ } -> observed, [], Unobserved
    | Roster_invalid { observed; errors; complete } ->
        observed, errors, (if complete then Absent else Unobserved)
    | Roster_complete observed -> observed, [], Absent
  in
  let first_rows =
    List.fold_left
      (fun index (row : Decode.keeper_runtime) ->
        Roster_names.update row.kr_name
          (function None -> Some (Present row) | Some _ as first -> first) index)
      Roster_names.empty observed
  in
  let first_errors =
    List.fold_left
      (fun index (name, detail) ->
        Roster_names.update name
          (function None -> Some (Invalid detail) | Some _ as first -> first) index)
      Roster_names.empty errors
  in
  let entries = Roster_names.union (fun _ error _ -> Some error) first_errors first_rows in
  fun name ->
    match Roster_names.find_opt name entries with
    | Some reading -> reading
    | None -> missing


