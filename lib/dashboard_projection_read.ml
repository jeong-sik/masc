type t = Reuse | Current

type completeness = Complete | Partial of string
type observation = {
  json : Yojson.Safe.t;
  next_deadline_unix : float option;
  completeness : completeness;
}

let combine_completeness left right = match left, right with
  | Complete, Complete -> Complete
  | Partial detail, Complete | Complete, Partial detail -> Partial detail
  | Partial left, Partial right -> Partial (left ^ "; " ^ right)

let keeper_completeness ~listing ~unread =
  let listing = match listing with
    | Keeper_snapshot_unread.Not_listed | Listed -> Complete
    | Unreadable detail -> Partial ("Keeper roster: " ^ detail) in
  List.fold_left (fun outcome (row : Keeper_snapshot_unread.t) ->
    let detail = match row.reason with Keeper_snapshot_unread.Meta_read_failed detail | Row_raised detail -> detail in
    combine_completeness outcome (Partial (Printf.sprintf "Keeper %s: %s" row.name detail)))
    listing unread

let json_with_read_diagnostics observation =
  let completeness, error = match observation.completeness with
    | Complete -> "complete", `Null
    | Partial detail -> "partial", `String detail in
  match observation.json with
  | `Assoc fields ->
      let diagnostics = match List.assoc_opt "projection_diagnostics" fields with
        | Some (`Assoc entries) -> entries
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None -> [] in
      let diagnostics = ["read_completeness", `String completeness; "read_error", error]
        @ List.remove_assoc "read_error" (List.remove_assoc "read_completeness" diagnostics) in
      `Assoc (("projection_diagnostics", `Assoc diagnostics)
        :: List.remove_assoc "projection_diagnostics" fields)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      invalid_arg "Dashboard read must retain an object body"

exception Incomplete_read of string
