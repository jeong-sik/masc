module Check = Masc.Published_artifact_check
module Catalog = Masc_tui_resource_catalog
module Fetched = Masc_tui_fetched

type inventory =
  { checks : Check.t list
  ; diagnostics : (string * string) list
  ; received_at : float }
type status = Known of Check.t option | Unknown of string

let ( let* ) = Result.bind
let fields names = function
  | `Assoc fields when List.length fields = List.length names
      && List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | `Assoc _ -> Error "invalid or duplicate confirmation inventory fields"
  | _ -> Error "expected confirmation inventory object"
let traverse f values = List.fold_right (fun value rest ->
  let* value = f value in let* rest = rest in Ok (value :: rest)) values (Ok [])

let of_json ~received_at json =
  let* root = fields ["checks"; "diagnostics"] json in
  match List.assoc_opt "checks" root, List.assoc_opt "diagnostics" root with
  | Some (`List checks), Some (`List diagnostics) ->
    let* checks = traverse Check.of_json checks in
    let targets = List.map (fun (check : Check.t) -> check.target.id, check.target.revision) checks in
    let* () = if List.length targets = List.length (List.sort_uniq compare targets)
      then Ok () else Error "duplicate artifact revision confirmation" in
    let* diagnostics = traverse (fun diagnostic ->
      let* fields = fields ["file"; "error"] diagnostic in
      match List.assoc_opt "file" fields, List.assoc_opt "error" fields with
      | Some (`String file), Some (`String error) -> Ok (file, error)
      | _ -> Error "invalid confirmation diagnostic") diagnostics in
    Ok { checks; diagnostics; received_at }
  | _ -> Error "invalid confirmation inventory"

let resolve inventory (report : Catalog.report) =
  if Fetched.in_flight inventory then Unknown "confirmation query in progress"
  else match Fetched.view_for ~equal:Unit.equal inventory ~key:() with
    | Absent -> Unknown "confirmation inventory has not been read"
    | Loading -> Unknown "confirmation query in progress"
    | Stale (_, detail) | Failed detail -> Unknown detail
    | Ready { diagnostics = _ :: _; _ } -> Unknown "some confirmation records could not be read"
    | Ready { checks; diagnostics = []; _ } ->
      match List.find_opt (fun (check : Check.t) ->
        check.target.id = report.id && check.target.revision = report.revision.revision) checks with
      | Some check when check.target.body_sha256 <> report.revision.body.sha256 ->
        Unknown "confirmation record refers to a different report body"
      | (Some _ | None) as check -> Known check

let unchecked_on_day ~reports_complete ~day ~entries inventory =
  if not reports_complete then None
  else
    (* Validate the check inventory even when today's report set is empty. *)
    let authoritative = not (Fetched.in_flight inventory)
      && match Fetched.view_for ~equal:Unit.equal inventory ~key:() with
         | Ready { diagnostics = []; _ } -> true
         | Ready { diagnostics = _ :: _; _ } | Absent | Loading | Stale _ | Failed _ -> false in
    if not authoritative then None
    else List.fold_left (fun count entry ->
      match count, entry with
      | None, (Catalog.Mcp _ | Report _) -> None
      | Some count, Catalog.Mcp _ -> Some count
      | Some count, Catalog.Report report ->
        match resolve inventory report with
        | Unknown _ -> None
        | Known check ->
          let unchecked = match check with
            | None -> true
            | Some check -> check.state = Check.Unchecked in
          Some (if unchecked && Catalog.on_day day entry then count + 1 else count)) (Some 0) entries

let label = function
  | Unknown _ -> "? check unknown"
  | Known None | Known (Some {state=Check.Unchecked;_}) -> "○ unchecked"
  | Known (Some {state=Check.Checked;_}) -> "✓ checked"

let description status = match status with
  | Unknown detail -> "Confirmation unknown: " ^ detail
  | Known None -> "No confirmation for this exact report revision."
  | Known (Some check) -> label status ^ " · " ^ check.changed_by ^ " · " ^ check.changed_at
