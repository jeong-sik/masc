type admitted = { requested : int; maximum : int option; usable_input : int }
type error =
  | Invalid_catalog of string
  | Model_absent of string
  | Requested_above_maximum of { model : string; requested : int; maximum : int }
let error_to_string = function
  | Invalid_catalog detail -> "Codex context catalog is invalid: " ^ detail
  | Model_absent model -> "Codex context catalog does not declare model " ^ model
  | Requested_above_maximum {model; requested; maximum} ->
    Printf.sprintf "Codex model %s requested context %d exceeds selected client maximum %d" model requested maximum
let ( let* ) = Result.bind
let resolve ~model ~requested json =
  let* rows = match json with
    | `Assoc fields -> (match List.assoc_opt "models" fields with
        | Some (`List rows) -> Ok rows | _ -> Error (Invalid_catalog "models array is absent"))
    | _ -> Error (Invalid_catalog "catalog is not an object") in
  let rows = List.filter_map (function
    | `Assoc fields when List.assoc_opt "slug" fields = Some (`String model) -> Some fields
    | _ -> None) rows in
  let* fields = match rows with
    | [] -> Error (Model_absent model)
    | [fields] when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
    | _ -> Error (Invalid_catalog "duplicate model or model fields") in
  let* maximum = match List.assoc_opt "max_context_window" fields with
    | None | Some `Null -> Ok None
    | Some (`Int value) when value > 0 -> Ok (Some value)
    | _ -> Error (Invalid_catalog "max_context_window is not a positive integer") in
  let* percent = match List.assoc_opt "effective_context_window_percent" fields with
    | Some (`Int value) when value > 0 && value <= 100 -> Ok value
    | _ -> Error (Invalid_catalog "effective_context_window_percent is absent or invalid") in
  let* () = match maximum with
    | Some maximum when requested > maximum -> Error (Requested_above_maximum {model; requested; maximum})
    | Some _ | None -> Ok () in
  if requested <= 0 then Error (Invalid_catalog "requested context must be positive")
  else
    (* Split the percentage arithmetic to avoid overflow on operator input. *)
    let usable_input = (requested / 100 * percent) + (requested mod 100 * percent / 100) in
    Ok {requested; maximum; usable_input}
