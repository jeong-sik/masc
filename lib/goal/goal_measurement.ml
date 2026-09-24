let ( let* ) = Result.bind

type t = {
  id : string;
  goal_id : string;
  criterion_revision : string;
  observed_value : string;
  evidence : string;
  actor : string;
  recorded_at : string;
}

type error =
  | Invalid_request of string
  | Conflict of string
  | Store_error of string

let error_to_string = function
  | Invalid_request detail | Conflict detail | Store_error detail -> detail

let fields label expected = function
  | `Assoc members as json ->
      let names = List.map fst members in
      if List.length names <> List.length expected
         || List.sort String.compare names <> List.sort String.compare expected
      then Error (label ^ ": unexpected, missing, or duplicate field")
      else Ok json
  | _ -> Error (label ^ ": expected object")

let text json name =
  match Json_util.assoc_member_opt name json with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error ("goal_measurement: missing or blank " ^ name)

let decode json =
  let* json =
    fields "goal_measurement"
      [ "id"; "goal_id"; "criterion_revision"; "observed_value";
        "evidence"; "actor"; "recorded_at" ] json
  in
  let* id = text json "id" in
  let* goal_id = text json "goal_id" in
  let* criterion_revision = text json "criterion_revision" in
  let* observed_value = text json "observed_value" in
  let* evidence = text json "evidence" in
  let* actor = text json "actor" in
  let* recorded_at = text json "recorded_at" in
  Ok { id; goal_id; criterion_revision; observed_value; evidence; actor; recorded_at }

let to_yojson item =
  `Assoc
    [ "id", `String item.id
    ; "goal_id", `String item.goal_id
    ; "criterion_revision", `String item.criterion_revision
    ; "observed_value", `String item.observed_value
    ; "evidence", `String item.evidence
    ; "actor", `String item.actor
    ; "recorded_at", `String item.recorded_at
    ]

let path config =
  Filename.concat (Workspace_utils.masc_dir config) "goal_measurements.json"

let mirror_path config = path config ^ ".last-good"

let load config =
  let primary = path config in
  if not (Workspace_utils.path_exists config primary) then
    if Workspace_utils.path_exists config (mirror_path config) then
      Error "goal_measurement: primary missing after initialization"
    else Ok []
  else
    let* json = Workspace_utils.read_json_result config primary in
    let* json = fields "goal_measurements" [ "version"; "measurements" ] json in
    let* () =
      match Json_util.assoc_member_opt "version" json with
      | Some (`Int 1) -> Ok ()
      | _ -> Error "goal_measurement: unsupported store version"
    in
    match Json_util.assoc_member_opt "measurements" json with
    | Some (`List items) ->
        List.fold_right
          (fun item rest ->
             let* decoded = decode item in
             let* rest = rest in
             Ok (decoded :: rest))
          items (Ok [])
    | _ -> Error "goal_measurement: measurements must be a list"

let latest_for_goal config ~(goal : Goal_store.goal) =
  let* rows = load config in
  Ok
    (List.find_opt
       (fun row ->
          String.equal row.goal_id goal.id
          && String.equal row.criterion_revision goal.criterion_revision)
       rows)

let write config items =
  let json =
    `Assoc
      [ "version", `Int 1
      ; "measurements", `List (List.map to_yojson items)
      ]
  in
  let* () = Workspace_utils.write_json_result config (path config) json in
  (match Workspace_utils.write_json_result config (mirror_path config) json with
   | Ok () -> ()
   | Error detail ->
       Log.Misc.warn "goal_measurement: recovery mirror write failed: %s" detail);
  Ok ()

let record config ~goal_id ~criterion_revision ~observed_value ~evidence ~actor =
  let blank value = String.trim value = "" in
  if blank goal_id || blank criterion_revision || blank observed_value
     || blank evidence || blank actor
  then Error (Invalid_request "goal_measurement: all fields are required")
  else
    match
      Goal_store.transact_goal config ~goal_id (fun goal ->
        if not (String.equal goal.criterion_revision criterion_revision) then
          Ok (goal, Error (Conflict "goal_measurement: success criterion changed"))
        else
          match goal.metric, goal.target_value with
          | None, _ | _, None ->
              Ok (goal, Error (Conflict "goal_measurement: Goal has no declared metric and target"))
          | Some _, Some _ ->
              Workspace_utils.with_file_lock config (path config) (fun () ->
                let recorded =
                  let* previous = load config in
                  let item =
                    { id = Random_id.hex ~bytes:16
                    ; goal_id
                    ; criterion_revision
                    ; observed_value
                    ; evidence
                    ; actor
                    ; recorded_at = Masc_domain.now_iso ()
                    }
                  in
                  let* () = write config (item :: previous) in
                  Ok item
                in
                Ok (goal, Result.map_error (fun detail -> Store_error detail) recorded)))
    with
    | Ok (_, item) -> item
    | Error (Goal_store.Goal_not_found _) ->
        Error (Invalid_request "goal_measurement: Goal not found")
    | Error error -> Error (Store_error (Goal_store.write_error_to_string error))

let record_json config ~actor json =
  let decode =
    let* json =
    fields "goal_measurement.request"
      [ "goal_id"; "criterion_revision"; "observed_value"; "evidence" ] json
    in
    let* goal_id = text json "goal_id" in
    let* criterion_revision = text json "criterion_revision" in
    let* observed_value = text json "observed_value" in
    let* evidence = text json "evidence" in
    Ok (goal_id, criterion_revision, observed_value, evidence)
  in
  match decode with
  | Error detail -> Error (Invalid_request detail)
  | Ok (goal_id, criterion_revision, observed_value, evidence) ->
      record config ~goal_id ~criterion_revision ~observed_value ~evidence ~actor
