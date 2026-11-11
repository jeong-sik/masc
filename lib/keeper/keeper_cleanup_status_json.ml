open Keeper_cleanup_status

let envelope_field = "keeper_cleanup"
let pass_field = "pass"
let rows_field = "rows"
let started_at_field = "started_at"
let interval_sec_field = "interval_sec"
let owners_field = "owners"
let without_meta_field = "without_meta"
let unreadable_field = "unreadable"
let no_step_field = "no_step"
let switched_off_field = "switched_off"
let scheduled_field = "scheduled"
let still_running_field = "still_running"
let steps_field = "steps"
let enabled_field = "enabled"
let selected_field = "selected"
let keeper_field = "keeper"
let step_field = "step"
let finished_at_field = "finished_at"
let reclaimed_at_field = "reclaimed_at"
let outcome_field = "outcome"
let report_field = "report"
let reason_field = "reason"
let reclaimed_name = "reclaimed"
let deferred_name = "deferred"
let not_running_name = "not_running"
let failed_name = "failed"
let cleaned_field = "cleaned"
let removed_field = "removed"
let skipped_field = "skipped"
let failed_field = "failed"
let freed_kib_field = "freed_kib"
let available_kib_field = "available_kib"

let builds_to_json ({ cleaned; failed } : builds) : Yojson.Safe.t =
  `Assoc [ cleaned_field, `Int cleaned; failed_field, `Int failed ]
;;

let workspace_to_json ({ removed; skipped; failed; freed_kib; available_kib } : workspace)
  : Yojson.Safe.t
  =
  `Assoc
    [ removed_field, `Int removed
    ; skipped_field, `Int skipped
    ; failed_field, `Int failed
    ; freed_kib_field, `Int freed_kib
    ; available_kib_field, `Int available_kib
    ]
;;

let outcome_to_fields (report_to_json : 'report -> Yojson.Safe.t)
  : 'report outcome -> (string * Yojson.Safe.t) list
  = function
  | Reclaimed report ->
    [ outcome_field, `String reclaimed_name; report_field, report_to_json report ]
  | Deferred reason -> [ outcome_field, `String deferred_name; reason_field, `String reason ]
  | Not_running -> [ outcome_field, `String not_running_name ]
  | Failed reason -> [ outcome_field, `String failed_name; reason_field, `String reason ]
;;

let row_to_json (row : row) : Yojson.Safe.t =
  let outcome =
    match row.attempt with
    | Guest_builds outcome -> outcome_to_fields builds_to_json outcome
    | Remote_workspace outcome -> outcome_to_fields workspace_to_json outcome
  in
  `Assoc
    ([ keeper_field, `String row.keeper
     ; step_field, `String (Keeper_cleanup_step.to_string (step row.attempt))
     ; finished_at_field, `Float row.finished_at
     ; reclaimed_at_field, Json_util.float_opt_to_json row.reclaimed_at
     ]
     @ outcome)
;;

let step_pass_to_json ({ step; enabled; selected } : step_pass) : Yojson.Safe.t =
  `Assoc
    [ step_field, `String (Keeper_cleanup_step.to_string step)
    ; enabled_field, `Bool enabled
    ; selected_field, `Int selected
    ]
;;

let unreadable_to_json ({ keeper; reason } : unreadable) : Yojson.Safe.t =
  `Assoc [ keeper_field, `String keeper; reason_field, `String reason ]
;;

let pass_to_json (pass : pass) : Yojson.Safe.t =
  `Assoc
    [ started_at_field, `Float pass.started_at
    ; interval_sec_field, `Float pass.interval_sec
    ; owners_field, `Int pass.owners
    ; without_meta_field, `Int pass.without_meta
    ; unreadable_field, `List (List.map unreadable_to_json pass.unreadable)
    ; no_step_field, `Int pass.no_step
    ; switched_off_field, `Int pass.switched_off
    ; scheduled_field, `Int pass.scheduled
    ; ( still_running_field
      , `List (List.map (fun keeper -> `String keeper) pass.still_running) )
    ; steps_field, `List (List.map step_pass_to_json pass.steps)
    ]
;;

let to_json t : Yojson.Safe.t =
  let pass =
    match t.pass with
    | None -> `Null
    | Some pass -> pass_to_json pass
  in
  `Assoc [ pass_field, pass; rows_field, `List (List.map row_to_json t.rows) ]
;;

type reading =
  { read_pass : (pass option, string) result
  ; read_rows : row list
  ; unread_rows : string list
  ; unknown_fields : string list
  }

let ( let* ) = Result.bind

let object_fields ~surface : Yojson.Safe.t -> ((string * Yojson.Safe.t) list, string) result
  = function
  | `Assoc fields -> Ok fields
  | _ -> Error (surface ^ " must be an object")
;;

let field ~surface name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" surface name)
;;

let int_field ~surface name fields =
  let* value = field ~surface name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be an integer" surface name)
;;

let count_field ~surface name fields =
  let* value = int_field ~surface name fields in
  if value >= 0
  then Ok value
  else Error (Printf.sprintf "%s.%s must not be negative" surface name)
;;

let bool_field ~surface name fields =
  let* value = field ~surface name fields in
  match value with
  | `Bool value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be a boolean" surface name)
;;

(* A reason is the step's or the Owner's own text and is read as written,
   blank included. *)
let reason_of_fields ~surface fields =
  let* value = field ~surface reason_field fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be a string" surface reason_field)
;;

let list_field ~surface name fields =
  let* value = field ~surface name fields in
  match value with
  | `List items -> Ok items
  | _ -> Error (Printf.sprintf "%s.%s must be an array" surface name)
;;

let item_surface ~surface name index = Printf.sprintf "%s.%s[%d]" surface name index

(* Every item or the first one refused. *)
let items_of_json ~surface name read fields =
  let* items = list_field ~surface name fields in
  let rec loop index read_items = function
    | [] -> Ok (List.rev read_items)
    | item :: rest ->
      let* item = read ~surface:(item_surface ~surface name index) item in
      loop (index + 1) (item :: read_items) rest
  in
  loop 0 [] items
;;

let step_of_fields ~surface fields =
  let* name = Json_util.require_field_string ~surface step_field fields in
  match Keeper_cleanup_step.of_string name with
  | Some step -> Ok step
  | None ->
    Error (Printf.sprintf "%s.%s %S is not a step this build knows" surface step_field name)
;;

let builds_of_json ~surface json =
  let* fields = object_fields ~surface json in
  let* () =
    Json_util.reject_unknown_fields ~surface ~allowed:[ cleaned_field; failed_field ] fields
  in
  let* cleaned = count_field ~surface cleaned_field fields in
  let* failed = count_field ~surface failed_field fields in
  Ok ({ cleaned; failed } : builds)
;;

let workspace_of_json ~surface json =
  let* fields = object_fields ~surface json in
  let* () =
    Json_util.reject_unknown_fields
      ~surface
      ~allowed:
        [ removed_field; skipped_field; failed_field; freed_kib_field; available_kib_field ]
      fields
  in
  let* removed = count_field ~surface removed_field fields in
  let* skipped = count_field ~surface skipped_field fields in
  let* failed = count_field ~surface failed_field fields in
  let* freed_kib = int_field ~surface freed_kib_field fields in
  let* available_kib = count_field ~surface available_kib_field fields in
  Ok ({ removed; skipped; failed; freed_kib; available_kib } : workspace)
;;

let row_fields =
  [ keeper_field; step_field; finished_at_field; reclaimed_at_field; outcome_field ]
;;

(* Each outcome carries its own fields beside the row's, and no others. *)
let outcome_of_fields ~surface report_of_json fields =
  let only carried =
    Json_util.reject_unknown_fields ~surface ~allowed:(row_fields @ carried) fields
  in
  let* name = Json_util.require_field_string ~surface outcome_field fields in
  if String.equal name reclaimed_name
  then
    let* () = only [ report_field ] in
    let* report = field ~surface report_field fields in
    let* report = report_of_json ~surface:(surface ^ "." ^ report_field) report in
    Ok (Reclaimed report)
  else if String.equal name deferred_name
  then
    let* () = only [ reason_field ] in
    let* reason = reason_of_fields ~surface fields in
    Ok (Deferred reason)
  else if String.equal name not_running_name
  then
    let* () = only [] in
    Ok Not_running
  else if String.equal name failed_name
  then
    let* () = only [ reason_field ] in
    let* reason = reason_of_fields ~surface fields in
    Ok (Failed reason)
  else Error (Printf.sprintf "%s.%s %S is not an outcome" surface outcome_field name)
;;

let reclaimed_at_of_fields ~surface fields =
  let* value = field ~surface reclaimed_at_field fields in
  match value with
  | `Null -> Ok None
  | `Float value -> Ok (Some value)
  | `Int value -> Ok (Some (float_of_int value))
  | _ -> Error (Printf.sprintf "%s.%s must be a number or null" surface reclaimed_at_field)
;;

let row_of_json ~surface json =
  let* fields = object_fields ~surface json in
  let* keeper = Json_util.require_field_string ~surface keeper_field fields in
  let* step = step_of_fields ~surface fields in
  let* finished_at = Json_util.require_field_float ~surface finished_at_field fields in
  let* reclaimed_at = reclaimed_at_of_fields ~surface fields in
  let* attempt =
    match step with
    | Keeper_cleanup_step.Guest_builds ->
      let* outcome = outcome_of_fields ~surface builds_of_json fields in
      Ok (Guest_builds outcome)
    | Keeper_cleanup_step.Remote_workspace ->
      let* outcome = outcome_of_fields ~surface workspace_of_json fields in
      Ok (Remote_workspace outcome)
  in
  Ok ({ keeper; attempt; finished_at; reclaimed_at } : row)
;;

let unreadable_of_json ~surface json =
  let* fields = object_fields ~surface json in
  let* () =
    Json_util.reject_unknown_fields ~surface ~allowed:[ keeper_field; reason_field ] fields
  in
  let* keeper = Json_util.require_field_string ~surface keeper_field fields in
  let* reason = reason_of_fields ~surface fields in
  Ok ({ keeper; reason } : unreadable)
;;

let step_pass_of_json ~surface json =
  let* fields = object_fields ~surface json in
  let* () =
    Json_util.reject_unknown_fields
      ~surface
      ~allowed:[ step_field; enabled_field; selected_field ]
      fields
  in
  let* step = step_of_fields ~surface fields in
  let* enabled = bool_field ~surface enabled_field fields in
  let* selected = count_field ~surface selected_field fields in
  Ok { step; enabled; selected }
;;

let pass_of_json ~surface json =
  let* fields = object_fields ~surface json in
  let* () =
    Json_util.reject_unknown_fields
      ~surface
      ~allowed:
        [ started_at_field
        ; interval_sec_field
        ; owners_field
        ; without_meta_field
        ; unreadable_field
        ; no_step_field
        ; switched_off_field
        ; scheduled_field
        ; still_running_field
        ; steps_field
        ]
      fields
  in
  let* started_at = Json_util.require_field_float ~surface started_at_field fields in
  let* interval_sec = Json_util.require_field_float ~surface interval_sec_field fields in
  let* owners = count_field ~surface owners_field fields in
  let* without_meta = count_field ~surface without_meta_field fields in
  let* unreadable = items_of_json ~surface unreadable_field unreadable_of_json fields in
  let* no_step = count_field ~surface no_step_field fields in
  let* switched_off = count_field ~surface switched_off_field fields in
  let* scheduled = count_field ~surface scheduled_field fields in
  let* still_running =
    Json_util.require_field_string_list ~surface still_running_field fields
  in
  let* steps = items_of_json ~surface steps_field step_pass_of_json fields in
  Ok
    { started_at
    ; interval_sec
    ; owners
    ; without_meta
    ; unreadable
    ; no_step
    ; switched_off
    ; scheduled
    ; still_running
    ; steps
    }
;;

let read_json json =
  let surface = envelope_field in
  let* fields = object_fields ~surface json in
  (* Every name is allowed here, so this refuses only a repeated one. *)
  let* () =
    Json_util.reject_unknown_fields ~surface ~allowed:(List.map fst fields) fields
  in
  let* rows = list_field ~surface rows_field fields in
  let read_pass =
    let* value = field ~surface pass_field fields in
    match value with
    | `Null -> Ok None
    | pass -> Result.map Option.some (pass_of_json ~surface:(surface ^ "." ^ pass_field) pass)
  in
  let rows =
    List.mapi
      (fun index row -> row_of_json ~surface:(item_surface ~surface rows_field index) row)
      rows
  in
  Ok
    { read_pass
    ; read_rows = List.filter_map Result.to_option rows
    ; unread_rows =
        List.filter_map
          (function
            | Ok (_ : row) -> None
            | Error reason -> Some reason)
          rows
    ; unknown_fields =
        List.filter_map
          (fun (name, _) ->
            if String.equal name pass_field || String.equal name rows_field
            then None
            else Some name)
          fields
    }
;;
