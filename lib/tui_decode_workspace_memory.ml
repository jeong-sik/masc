open Result.Syntax
open Tui_decode_fields

type briefing_status =
  | Pending
  | Current
  | Stale
  | Unavailable

type building_pass = {
  target : int;
  remaining : int;
}

type briefing = {
  status : briefing_status;
  building : building_pass option;
}

type absence_counts = {
  facts : int;
  absent : int;
  available_stores : int;
  missing_stores : int;
}
type ordinary_absence =
  | Absence_complete of absence_counts
  | Absence_partial of { counts : absence_counts; unavailable_stores : int }
  | Absence_unavailable of string

type available_inventory = {
  generated_at : float;
  ledger_sha256 : string;
  claim_count : int;
  conflict_count : int;
  excluded_count : int;
  classified_count : int;
  briefing : briefing;
  ordinary_absence : ordinary_absence;
}

type inventory =
  | Missing of { generated_at : float; ordinary_absence : ordinary_absence }
  | Available of available_inventory

let expected_schema = "workspace.memory.inventory.v1"

let decode_building_pass json =
  let* () = require_exact_object_fields "briefing building pass" [ "target"; "remaining" ] json in
  let* target = required_nonnegative_int_field json "target" in
  let* remaining = required_nonnegative_int_field json "remaining" in
  if remaining > target then
    Error (Printf.sprintf "building remaining (%d) exceeds target (%d)" remaining target)
  else
    Ok { target; remaining }
;;

let decode_briefing json =
  match member "status" json with
  | `String "unavailable" ->
    let* () = require_exact_object_fields "unavailable briefing" [ "status" ] json in
    Ok { status = Unavailable; building = None }
  | `String status_str ->
    let* status =
      match status_str with
      | "pending" -> Ok Pending
      | "current" -> Ok Current
      | "stale" -> Ok Stale
      | other -> Error ("unknown briefing status: " ^ other)
    in
    let* () = require_exact_object_fields "briefing" [ "status"; "building" ] json in
    let* building =
      match member "building" json with
      | `Null -> Ok None
      | `Assoc _ as b_json ->
        let* pass = decode_building_pass b_json in
        Ok (Some pass)
      | other -> field_type_error "briefing" "building" other
    in
    Ok { status; building }
  | other -> field_type_error "briefing" "status" other
;;

let decode_ordinary_absence json =
  let* status = required_string_field json "status" in
  match status with
  | "unavailable" ->
    let* () = require_exact_object_fields "unavailable ordinary absence" ["status"; "detail"] json in
    let* detail = required_nonempty_string_field json "detail" in
    if String.trim detail = "" then Error "ordinary absence failure detail must be nonblank"
    else Ok (Absence_unavailable detail)
  | "complete" | "partial" ->
    let* () = require_exact_object_fields "ordinary absence"
      (["status"; "facts"; "absent"; "available_stores"; "missing_stores"]
       @ if status = "partial" then ["unavailable_stores"] else []) json in
    let* facts = required_nonnegative_int_field json "facts" in
    let* absent = required_nonnegative_int_field json "absent" in
    let* available_stores = required_nonnegative_int_field json "available_stores" in
    let* missing_stores = required_nonnegative_int_field json "missing_stores" in
    if absent > facts || (available_stores = 0 && facts <> 0)
    then Error "ordinary absence counts disagree with observed facts/stores"
    else
      let counts = { facts; absent; available_stores; missing_stores } in
      if status = "complete" then Ok (Absence_complete counts)
      else
        let* unavailable_stores = required_nonnegative_int_field json "unavailable_stores" in
        if unavailable_stores = 0 then Error "partial ordinary absence requires an unavailable store"
        else Ok (Absence_partial { counts; unavailable_stores })
  | other -> Error ("unknown ordinary absence status: " ^ other)
;;

let decode_inventory json =
  let* schema = required_string_field json "schema" in
  if not (String.equal schema expected_schema) then
    Error ("unsupported workspace memory inventory schema: " ^ schema)
  else
    let* generated_at =
      match member "generated_at" json with
      | `Float f when f >= 0.0 -> Ok f
      | `Int i when i >= 0 -> Ok (float_of_int i)
      | other -> field_type_error "workspace memory inventory" "generated_at" other
    in
    let* status = required_string_field json "status" in
    let* absence_json = required_object_field json "ordinary_absence" in
    let* ordinary_absence = decode_ordinary_absence absence_json in
    match status with
    | "missing" ->
      let* () = require_exact_object_fields "missing workspace memory inventory"
        [ "schema"; "generated_at"; "status"; "ordinary_absence" ] json in
      let all_absent = match ordinary_absence with
        | Absence_complete counts | Absence_partial { counts; _ } -> counts.absent = counts.facts
        | Absence_unavailable _ -> true in
      if all_absent then Ok (Missing { generated_at; ordinary_absence })
      else Error "a missing ledger cannot have classified ordinary facts"
    | "available" ->
      let* () = require_exact_object_fields "available workspace memory inventory"
        [ "schema"
        ; "generated_at"
        ; "status"
        ; "semantic_verification"
        ; "ledger_sha256"
        ; "claim_count"
        ; "conflict_count"
        ; "excluded_count"
        ; "classified_count"
        ; "briefing"
        ; "ordinary_absence"
        ] json in
      let* verification = required_string_field json "semantic_verification" in
      if not (String.equal verification "not_performed") then
        Error ("unexpected semantic_verification: " ^ verification)
      else
        let* ledger_sha256 = required_nonempty_string_field json "ledger_sha256" in
        let* claim_count = required_nonnegative_int_field json "claim_count" in
        let* conflict_count = required_nonnegative_int_field json "conflict_count" in
        let* excluded_count = required_nonnegative_int_field json "excluded_count" in
        let* classified_count = required_nonnegative_int_field json "classified_count" in
        let* briefing_json = required_object_field json "briefing" in
        let* briefing = decode_briefing briefing_json in
        Ok (Available
          { generated_at
          ; ledger_sha256
          ; claim_count
          ; conflict_count
          ; excluded_count
          ; classified_count
          ; briefing
          ; ordinary_absence
          })
    | other -> Error ("unknown workspace memory inventory status: " ^ other)
;;
