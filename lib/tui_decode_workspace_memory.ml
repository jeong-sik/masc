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

type available_inventory = {
  generated_at : float;
  ledger_sha256 : string;
  claim_count : int;
  conflict_count : int;
  excluded_count : int;
  classified_count : int;
  briefing : briefing;
}

type inventory =
  | Missing of { generated_at : float }
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
    match status with
    | "missing" ->
      let* () = require_exact_object_fields "missing workspace memory inventory"
        [ "schema"; "generated_at"; "status" ] json in
      Ok (Missing { generated_at })
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
          })
    | other -> Error ("unknown workspace memory inventory status: " ^ other)
;;
