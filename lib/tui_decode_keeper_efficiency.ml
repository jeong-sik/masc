(** See [.mli]. *)

let expected_schema = "masc.keeper-efficiency/v1"

type keeper_month = {
  keeper : string;
  turns : int;
  input_tokens : int;
  output_tokens : int;
  cost_usd : float;
  calls : int;
  failed : int;
  deferred : int;
  tool_ms : float;
}

type fleet = {
  turns_total : int;
  calls_per_turn : float;
  tool_s_per_turn : float;
  output_tokens_per_turn : float;
  input_tokens_per_turn : float;
  cost_usd_per_turn : float;
}

type month_view = {
  month : string;
  generated_at : float;
  days_covered : int;
  keepers : keeper_month list;
  fleet : fleet;
}

type decode_error =
  | Not_an_object
  | Unexpected_schema of string
  | Missing_field of string
  | Invalid_field of { field : string; detail : string }
  | Malformed_json of { line_number : int option; detail : string }

let decode_error_to_string = function
  | Not_an_object -> "efficiency month view: body is not a JSON object"
  | Unexpected_schema schema ->
    Printf.sprintf "efficiency month view: schema %S is not %S" schema expected_schema
  | Missing_field field -> Printf.sprintf "efficiency month view: missing %s" field
  | Invalid_field { field; detail } ->
    Printf.sprintf "efficiency month view: invalid %s: %s" field detail
  | Malformed_json { line_number; detail } ->
    Printf.sprintf "efficiency month view: malformed JSON (line %s): %s"
      (match line_number with Some n -> string_of_int n | None -> "?")
      detail
;;

let member fields name = List.assoc_opt name fields

let int_field fields name =
  match member fields name with
  | None -> Error (Missing_field name)
  | Some (`Int n) when n >= 0 -> Ok n
  | Some (`Int _) -> Error (Invalid_field { field = name; detail = "negative" })
  | Some _ -> Error (Invalid_field { field = name; detail = "not an integer" })
;;

let float_field fields name =
  match member fields name with
  | None -> Error (Missing_field name)
  | Some (`Float v) when not (Float.is_nan v) ->
    if v = infinity || v = neg_infinity then
      Error (Invalid_field { field = name; detail = "not finite" })
    else if v < 0.0 then Error (Invalid_field { field = name; detail = "negative" })
    else Ok v
  | Some _ -> Error (Invalid_field { field = name; detail = "not a number" })
;;

let string_field fields name =
  match member fields name with
  | None -> Error (Missing_field name)
  | Some (`String s) when s <> "" -> Ok s
  | Some (`String _) -> Error (Invalid_field { field = name; detail = "empty" })
  | Some _ -> Error (Invalid_field { field = name; detail = "not a string" })
;;

let keeper_of_json json =
  match json with
  | `Assoc fields ->
    let open Result.Syntax in
    let* keeper = string_field fields "keeper" in
    let* turns = int_field fields "turns" in
    let* input_tokens = int_field fields "input_tokens" in
    let* output_tokens = int_field fields "output_tokens" in
    let* cost_usd = float_field fields "cost_usd" in
    let* calls = int_field fields "calls" in
    let* failed = int_field fields "failed" in
    let* deferred = int_field fields "deferred" in
    let* tool_ms = float_field fields "tool_ms" in
    Ok { keeper; turns; input_tokens; output_tokens; cost_usd; calls; failed; deferred; tool_ms }
  | _ -> Error Not_an_object
;;

let fleet_of_json json =
  match json with
  | `Assoc fields ->
    let open Result.Syntax in
    let* turns_total = int_field fields "turns_total" in
    let* calls_per_turn = float_field fields "calls_per_turn" in
    let* tool_s_per_turn = float_field fields "tool_s_per_turn" in
    let* output_tokens_per_turn = float_field fields "output_tokens_per_turn" in
    let* input_tokens_per_turn = float_field fields "input_tokens_per_turn" in
    let* cost_usd_per_turn = float_field fields "cost_usd_per_turn" in
    Ok
      { turns_total
      ; calls_per_turn
      ; tool_s_per_turn
      ; output_tokens_per_turn
      ; input_tokens_per_turn
      ; cost_usd_per_turn
      }
  | _ -> Error Not_an_object
;;

let of_json json =
  match json with
  | `Assoc fields ->
    let open Result.Syntax in
    let* schema = string_field fields "schema" in
    let* () =
      if String.equal schema expected_schema then Ok ()
      else Error (Unexpected_schema schema)
    in
    let* month = string_field fields "month" in
    let* () =
      match String.split_on_char '-' month with
      | [ year; mon ] ->
        let digits s = String.for_all (fun c -> c >= '0' && c <= '9') s in
        if
          String.length year = 4 && digits year
          && String.length mon = 2 && digits mon
          && int_of_string mon >= 1
          && int_of_string mon <= 12
        then Ok ()
        else Error (Invalid_field { field = "month"; detail = "not YYYY-MM" })
      | _ -> Error (Invalid_field { field = "month"; detail = "not YYYY-MM" })
    in
    let* generated_at = float_field fields "generated_at" in
    let* days_covered = int_field fields "days_covered" in
    let* keepers =
      match member fields "keepers" with
      | None -> Error (Missing_field "keepers")
      | Some (`List rows) ->
        List.fold_left
          (fun acc json ->
             let open Result.Syntax in
             let* acc = acc in
             let* row = keeper_of_json json in
             Ok (acc @ [ row ]))
          (Ok []) rows
      | Some _ -> Error (Invalid_field { field = "keepers"; detail = "not a list" })
    in
    let* fleet =
      match member fields "fleet" with
      | None -> Error (Missing_field "fleet")
      | Some fleet_json -> fleet_of_json fleet_json
    in
    Ok { month; generated_at; days_covered; keepers; fleet }
  | _ -> Error Not_an_object
;;

let keeper_row view ~keeper =
  List.find_opt (fun (row : keeper_month) -> String.equal row.keeper keeper) view.keepers
;;
