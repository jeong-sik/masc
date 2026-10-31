module C = Fixture_types.Control
module D = Fixture_types.Tui_decode
module Names = Map.Make (String)

type t = { source : C.roster; names : C.liveness Names.t }

let prepare source =
  let observed, errors =
    match source with
    | C.Roster_unobserved -> [], []
    | C.Roster_partial { observed; total = _ }
    | C.Roster_complete observed -> observed, []
    | C.Roster_invalid { observed; errors; complete = _ } -> observed, errors
  in
  let observed = List.fold_left
      (fun index (row : D.keeper_runtime) ->
        Names.update row.kr_name
          (function None -> Some (C.Present row) | Some _ as first -> first) index)
      Names.empty observed in
  let errors = List.fold_left
      (fun index (name, detail) ->
        Names.update name
          (function None -> Some (C.Invalid detail) | Some _ as first -> first) index)
      Names.empty errors in
  { source; names = Names.union (fun _ error _ -> Some error) errors observed }

let view prepared = prepared.source

let liveness prepared name =
  match Names.find_opt name prepared.names with
  | Some reading -> reading
  | None ->
      match prepared.source with
      | C.Roster_unobserved | C.Roster_partial _ -> C.Unobserved
      | C.Roster_complete _ -> C.Absent
      | C.Roster_invalid { complete; _ } -> if complete then C.Absent else C.Unobserved
