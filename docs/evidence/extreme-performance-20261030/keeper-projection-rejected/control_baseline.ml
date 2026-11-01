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


