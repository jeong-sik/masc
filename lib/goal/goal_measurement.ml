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

(* Evidence the verification store can read: its reference classifier, plus
   the artifact path check its snapshotter applies (an [artifact:] path that
   is empty, absolute, or has [.]/[..]/empty segments snapshots as an invalid
   reference). Both are calls into Workspace_verification_store, not copies.
   A row is only built after this passes, when a request records it and when
   the store is read. *)
let evidence_reference value =
  let reference = String.trim value in
  let refused () =
    Error
      ("goal_measurement: evidence must be one of "
       ^ String.concat ", " Workspace_verification_store.resolvable_reference_forms)
  in
  match Workspace_verification_store.classify_evidence_reference reference with
  | Workspace_verification_store.Artifact_reference path ->
      if Workspace_verification_store.valid_producer_relative_path path
      then Ok reference
      else refused ()
  | Workspace_verification_store.Note_reference _
  | Workspace_verification_store.Collaboration_reference _ -> Ok reference
  | Workspace_verification_store.Unresolvable_reference -> refused ()

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
  let* evidence = Result.bind (text json "evidence") evidence_reference in
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

let read_optional config file =
  match Workspace_utils.key_of_path config file with
  | None -> Error "goal_measurement: store path is outside workspace"
  | Some key ->
      (match Workspace_utils.backend_get config ~key with
       | Error error ->
           Error ("goal_measurement: store read failed: " ^ Backend_types.show_error error)
       | Ok None -> Ok None
       | Ok (Some bytes) ->
           (try Ok (Some (Yojson.Safe.from_string bytes))
            with Yojson.Json_error detail ->
              Error ("goal_measurement: invalid JSON: " ^ detail)))

let load config =
  let primary = path config in
  let* primary_json = read_optional config primary in
  match primary_json with
  | None ->
      let* mirror_json = read_optional config (mirror_path config) in
      (match mirror_json with
       | None -> Ok []
       | Some _ -> Error "goal_measurement: primary missing after initialization")
  | Some json ->
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

let latest rows (goal : Goal_store.goal) =
  List.find_opt
    (fun row ->
       String.equal row.goal_id goal.id
       && String.equal row.criterion_revision goal.criterion_revision)
    rows

let projection records (goal : Goal_store.goal) =
  match records with
  | Error reason ->
      `Assoc [ "state", `String "unavailable"; "reason", `String reason ]
  | Ok rows ->
      (match latest rows goal with
       | None -> `Assoc [ "state", `String "not_recorded" ]
       | Some row ->
           `Assoc [ "state", `String "reported"
                  ; "record", to_yojson row ])

let write config items =
  let json =
    `Assoc
      [ "version", `Int 1
      ; "measurements", `List (List.map to_yojson items)
      ]
  in
  let* committed = Workspace_utils.write_json_commit_result config (path config) json in
  (match committed.mirror_error with
   | None -> ()
   | Some detail ->
       Log.Misc.warn "goal_measurement: local mirror write failed after commit: %s" detail);
  (match Workspace_utils.write_json_result config (mirror_path config) json with
   | Ok () -> ()
   | Error detail ->
       Log.Misc.warn "goal_measurement: recovery mirror write failed: %s" detail);
  Ok ()

let remove_goal config ~goal_id =
  Workspace_utils.with_file_lock config (path config) (fun () ->
    let* previous = load config in
    let remaining =
      List.filter (fun row -> not (String.equal row.goal_id goal_id)) previous
    in
    if List.length remaining = List.length previous then Ok ()
    else write config remaining)

let record config ~goal_id ~criterion_revision ~observed_value ~evidence ~actor =
  let blank value = String.trim value = "" in
  if blank goal_id || blank criterion_revision || blank observed_value
     || blank evidence || blank actor
  then Error (Invalid_request "goal_measurement: all fields are required")
  else
    match evidence_reference evidence with
    | Error detail -> Error (Invalid_request detail)
    | Ok evidence ->
    (* The Goal phase is not consulted. An observation never moves the phase,
       so recording one on a Completed or Dropped Goal changes no lifecycle
       truth: it says the metric was seen again after the Goal closed, and a
       Reopen (Completed/Dropped -> Executing, same criterion revision) shows
       that latest value instead of an older one. *)
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
                  (* The product reads one current observation per Goal. A
                     replacement also removes records for retired criterion
                     revisions, keeping this snapshot bounded by Goal count. *)
                  let remaining =
                    List.filter (fun row -> not (String.equal row.goal_id goal_id)) previous
                  in
                  let* () = write config (item :: remaining) in
                  Ok item
                in
                Ok (goal, Result.map_error (fun detail -> Store_error detail) recorded)))
    with
    | Ok (_, Ok item) ->
        Goal_projection_generation.advance ();
        Ok item
    | Ok (_, Error error) -> Error error
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
