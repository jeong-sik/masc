open Schedule_domain

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; grants : Schedule_domain.execution_grant list
  }

type store_error =
  | Schedule_already_exists
  | Schedule_not_found
  | Grant_already_recorded
  | Invalid_initial_status of string
  | Grant_validation_failed of Schedule_domain.grant_error

let ( let* ) = Result.bind

let store_error_to_string = function
  | Schedule_already_exists -> "schedule already exists"
  | Schedule_not_found -> "schedule not found"
  | Grant_already_recorded -> "grant already recorded"
  | Invalid_initial_status reason -> "invalid initial schedule status: " ^ reason
  | Grant_validation_failed err ->
    "grant validation failed: " ^ Schedule_domain.grant_error_to_string err
;;

(* NDT-OK: store boundary timestamp for projection metadata; replay uses the
   persisted [updated_at] value instead of recomputing it. *)
let now () = Unix.gettimeofday ()

let schedules_path config =
  Filename.concat (Workspace_utils.masc_dir config) "schedules.json"
;;

let recovery_path config = schedules_path config ^ ".last-good"

let ensure_dirs config = Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let default_state () =
  { version = 1; updated_at = now (); schedules = []; grants = [] }
;;

let state_to_yojson (state : state) =
  `Assoc
    [ "version", `Int state.version
    ; "updated_at", `Float state.updated_at
    ; ( "schedules"
      , `List (List.map Schedule_domain.schedule_request_to_yojson state.schedules)
      )
    ; "grants", `List (List.map Schedule_domain.execution_grant_to_yojson state.grants)
    ]
;;

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error ("expected int field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let float_field name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some _ -> Error ("expected float field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let list_field name fields =
  match List.assoc_opt name fields with
  | Some (`List value) -> Ok value
  | Some _ -> Error ("expected list field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let collect_results parse rows =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      let* value = parse row in
      loop (value :: acc) rest
  in
  loop [] rows
;;

let state_of_yojson = function
  | `Assoc fields ->
    let* version = int_field "version" fields in
    let* updated_at = float_field "updated_at" fields in
    let* schedules_json = list_field "schedules" fields in
    let* grants_json = list_field "grants" fields in
    let* schedules =
      collect_results Schedule_domain.schedule_request_of_yojson schedules_json
    in
    let* grants =
      collect_results Schedule_domain.execution_grant_of_yojson grants_json
    in
    Ok { version; updated_at; schedules; grants }
  | json -> Error ("state_of_yojson: " ^ Yojson.Safe.to_string json)
;;

let read_state config =
  ensure_dirs config;
  let path = schedules_path config in
  if Workspace_utils.path_exists config path then
    match Workspace_utils.read_json_result config path with
    | Ok json ->
      (match state_of_yojson json with
       | Ok state -> state
       | Error _ ->
         let recovery = recovery_path config in
         if Workspace_utils.path_exists config recovery then
           match Workspace_utils.read_json_result config recovery with
           | Ok recovery_json ->
             (match state_of_yojson recovery_json with
              | Ok state -> state
              | Error _ -> default_state ())
           | Error _ -> default_state ()
         else
           default_state ())
    | Error _ ->
      let recovery = recovery_path config in
      if Workspace_utils.path_exists config recovery then
        match Workspace_utils.read_json_result config recovery with
        | Ok recovery_json ->
          (match state_of_yojson recovery_json with
           | Ok state -> state
           | Error _ -> default_state ())
        | Error _ -> default_state ()
      else
        default_state ()
  else
    default_state ()
;;

let write_state config state =
  ensure_dirs config;
  let json = state_to_yojson state in
  Workspace_utils.write_json config (schedules_path config) json;
  Workspace_utils.write_json config (recovery_path config) json
;;

let bump_state state ~schedules ~grants =
  { version = state.version + 1; updated_at = now (); schedules; grants }
;;

let find_schedule state schedule_id =
  List.find_opt
    (fun (request : Schedule_domain.schedule_request) ->
      String.equal request.schedule_id schedule_id)
    state.schedules
;;

let replace_schedule schedules (updated : schedule_request) =
  List.map
    (fun (request : schedule_request) ->
      if String.equal request.schedule_id updated.schedule_id then
        updated
      else
        request)
    schedules
;;

let grant_exists state grant_id =
  List.exists
    (fun (grant : Schedule_domain.execution_grant) ->
      String.equal grant.grant_id grant_id)
    state.grants
;;

let has_approved_grant state schedule_id =
  List.exists
    (fun (grant : execution_grant) ->
      String.equal grant.schedule_id schedule_id
      &&
      match grant.decision with
      | Approve -> true
      | Reject _ -> false)
    state.grants
;;

let list_schedules config = (read_state config).schedules

let get_schedule config ~schedule_id = find_schedule (read_state config) schedule_id

let validate_initial_request (request : Schedule_domain.schedule_request) =
  if Schedule_domain.is_terminal request.status then
    Error (Invalid_initial_status "terminal requests cannot be inserted")
  else if Schedule_domain.requires_separate_human_grant request then
    match request.status with
    | Pending_approval -> Ok ()
    | _ ->
      Error
        (Invalid_initial_status
           "side-effecting requests must start pending approval")
  else
    match request.status with
    | Scheduled -> Ok ()
    | _ ->
      Error
        (Invalid_initial_status
           "requests without approval requirements must start scheduled")
;;

let insert_request config (request : Schedule_domain.schedule_request) =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let state = read_state config in
    match find_schedule state request.schedule_id with
    | Some _ -> Error Schedule_already_exists
    | None ->
      let* () = validate_initial_request request in
      let schedules = request :: state.schedules in
      let next_state = bump_state state ~schedules ~grants:state.grants in
      write_state config next_state;
      Ok request)
;;

let record_grant config (grant : Schedule_domain.execution_grant) =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let state = read_state config in
    if grant_exists state grant.grant_id then
      Error Grant_already_recorded
    else (
      match find_schedule state grant.schedule_id with
      | None -> Error Schedule_not_found
      | Some request ->
        match Schedule_domain.apply_execution_grant request grant with
        | Error err -> Error (Grant_validation_failed err)
        | Ok updated_request ->
          let schedules = replace_schedule state.schedules updated_request in
          let grants = grant :: state.grants in
          let next_state = bump_state state ~schedules ~grants in
          write_state config next_state;
          Ok updated_request))
;;

let refresh_due config ~now =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let state = read_state config in
    let changed = ref 0 in
    let schedules =
      List.map
        (fun request ->
          let updated = Schedule_domain.mark_due ~now request in
          if updated.Schedule_domain.status <> request.Schedule_domain.status then
            incr changed;
          updated)
        state.schedules
    in
    if !changed = 0 then
      Ok (state, 0)
    else (
      let next_state = bump_state state ~schedules ~grants:state.grants in
      write_state config next_state;
      Ok (next_state, !changed)))
;;

let due_execution_candidates state =
  state.schedules
  |> List.filter (fun (request : schedule_request) ->
    match request.status with
    | Due ->
      (not (requires_separate_human_grant request))
      || has_approved_grant state request.schedule_id
    | Pending_approval | Scheduled | Running | Succeeded | Failed | Rejected | Cancelled
    | Expired ->
      false)
;;
