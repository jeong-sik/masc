type approval_status =
  | Open
  | Approved
  | Rejected
  | Cancelled

let approval_status_to_string = function
  | Open -> "open"
  | Approved -> "approved"
  | Rejected -> "rejected"
  | Cancelled -> "cancelled"

let approval_status_to_yojson status =
  `String (approval_status_to_string status)

let approval_status_of_string = function
  | "open" -> Some Open
  | "approved" -> Some Approved
  | "rejected" -> Some Rejected
  | "cancelled" -> Some Cancelled
  | _ -> None

let approval_status_of_yojson = function
  | `String value ->
    (match approval_status_of_string value with
     | Some status -> Ok status
     | None -> Error ("approval_status_of_yojson: " ^ value))
  | json ->
    Error ("approval_status_of_yojson: " ^ Yojson.Safe.to_string json)

type approval_request =
  { id : string
  ; goal_id : string
  ; verification_request_id : string option
  ; opened_by : Goal_verification.goal_principal
  ; opened_at : string
  ; status : approval_status
  ; resolved_by : Goal_verification.goal_principal option
  ; resolved_at : string option
  ; resolution_note : string option
  }

type state =
  { version : int
  ; updated_at : string
  ; requests : approval_request list
  }

let request_status_is_open (request : approval_request) =
  request.status = Open

let approval_request_to_yojson (request : approval_request) =
  `Assoc
    [ "id", `String request.id
    ; "goal_id", `String request.goal_id
    ; ( "verification_request_id"
      , Json_util.string_opt_to_json request.verification_request_id )
    ; "opened_by", Goal_verification.goal_principal_to_yojson request.opened_by
    ; "opened_at", `String request.opened_at
    ; "status", approval_status_to_yojson request.status
    ; ( "resolved_by"
      , match request.resolved_by with
        | Some principal -> Goal_verification.goal_principal_to_yojson principal
        | None -> `Null )
    ; "resolved_at", Json_util.string_opt_to_json request.resolved_at
    ; "resolution_note", Json_util.string_opt_to_json request.resolution_note
    ]

let approval_request_of_yojson = function
  | `Assoc _ as json ->
    let string_field field =
      match Json_util.assoc_member_opt field json with
      | Some (`String value) when not (String.equal (String.trim value) "") ->
        Ok value
      | _ -> Error ("approval_request_of_yojson: invalid " ^ field)
    in
    let principal_field field =
      match Json_util.assoc_member_opt field json with
      | Some `Null | None -> Ok None
      | Some value ->
        Result.map Option.some (Goal_verification.goal_principal_of_yojson value)
    in
    (match
       ( string_field "id"
       , string_field "goal_id"
       , string_field "opened_at"
       , Json_util.assoc_member_opt "opened_by" json
       , Json_util.assoc_member_opt "status" json )
     with
     | ( Ok id
       , Ok goal_id
       , Ok opened_at
       , Some opened_by_json
       , Some status_json ) ->
       (match
          ( Goal_verification.goal_principal_of_yojson opened_by_json
          , approval_status_of_yojson status_json
          , principal_field "resolved_by" )
        with
        | Ok opened_by, Ok status, Ok resolved_by ->
          Ok
            { id
            ; goal_id
            ; verification_request_id =
                Json_util.get_string json "verification_request_id"
            ; opened_by
            ; opened_at
            ; status
            ; resolved_by
            ; resolved_at = Json_util.get_string json "resolved_at"
            ; resolution_note = Json_util.get_string json "resolution_note"
            }
        | Error msg, _, _ | _, Error msg, _ | _, _, Error msg -> Error msg)
     | Error msg, _, _, _, _
     | _, Error msg, _, _, _
     | _, _, Error msg, _, _ ->
       Error msg
     | _, _, _, _, _ ->
       Error "approval_request_of_yojson: invalid request")
  | json ->
    Error ("approval_request_of_yojson: " ^ Yojson.Safe.to_string json)

let state_to_yojson (state : state) =
  `Assoc
    [ "version", `Int state.version
    ; "updated_at", `String state.updated_at
    ; "requests", `List (List.map approval_request_to_yojson state.requests)
    ]

let state_of_yojson = function
  | `Assoc _ as json ->
    (match
       ( Json_util.assoc_member_opt "version" json
       , Json_util.assoc_member_opt "updated_at" json
       , Json_util.assoc_member_opt "requests" json )
     with
     | Some (`Int version), Some (`String updated_at), Some (`List requests_json) ->
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | row :: rest ->
           (match approval_request_of_yojson row with
            | Ok request -> collect (request :: acc) rest
            | Error msg -> Error msg)
       in
       Result.map
         (fun requests -> { version; updated_at; requests })
         (collect [] requests_json)
     | _ -> Error "goal_approval_state_of_yojson: invalid state")
  | json ->
    Error ("goal_approval_state_of_yojson: " ^ Yojson.Safe.to_string json)

let requests_path config =
  Filename.concat (Workspace_utils.masc_dir config) "goal_approvals.json"

let requests_recovery_path config =
  requests_path config ^ ".last-good"

let default_state () =
  { version = 1; updated_at = Masc_domain.now_iso (); requests = [] }

let ensure_dirs config =
  Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let read_recovery_state config ~primary_msg ~primary_context =
  let recovery = requests_recovery_path config in
  if Workspace_utils.path_exists config recovery
  then
    match Workspace_utils.read_json_result config recovery with
    | Ok recovery_json ->
      (match state_of_yojson recovery_json with
       | Ok state ->
         Log.Misc.warn
           "goal_approval: primary %s (%s), recovered from %s"
           primary_context
           primary_msg
           recovery;
         Ok state
       | Error recovery_msg ->
         let msg =
           Printf.sprintf
             "primary %s (%s), recovery corrupt (%s)"
             primary_context
             primary_msg
             recovery_msg
         in
         Log.Misc.error "goal_approval: %s" msg;
         Error msg)
    | Error recovery_msg ->
      let msg =
        Printf.sprintf
          "primary %s (%s), recovery read failed for %s: %s"
          primary_context
          primary_msg
          recovery
          recovery_msg
      in
      Log.Misc.error "goal_approval: %s" msg;
      Error msg
  else
    let msg =
      Printf.sprintf
        "primary %s (%s), no .last-good available"
        primary_context
        primary_msg
    in
    Log.Misc.warn "goal_approval: %s" msg;
    Error msg

let read_state_r config =
  ensure_dirs config;
  let path = requests_path config in
  if Workspace_utils.path_exists config path
  then
    match Workspace_utils.read_json_result config path with
    | Ok json ->
      (match state_of_yojson json with
       | Ok state -> Ok state
       | Error primary_msg ->
         read_recovery_state
           config
           ~primary_msg
           ~primary_context:"goal_approvals.json corrupt")
    | Error primary_msg ->
      read_recovery_state
        config
        ~primary_msg
        ~primary_context:"goal_approvals.json unreadable"
  else if Workspace_utils.path_exists config (requests_recovery_path config)
  then
    read_recovery_state
      config
      ~primary_msg:"missing"
      ~primary_context:"goal_approvals.json missing"
  else
    Ok (default_state ())

let read_state config =
  match read_state_r config with
  | Ok state -> state
  | Error msg ->
    Log.Misc.warn
      "goal_approval: using empty default state for read-only projection after \
       unrecoverable read failure: %s"
      msg;
    default_state ()

let write_state config state =
  ensure_dirs config;
  let json = state_to_yojson state in
  Workspace_utils.write_json config (requests_path config) json;
  Workspace_utils.write_json config (requests_recovery_path config) json

let update_state_result config f =
  let lock_path = requests_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
    match read_state_r config with
    | Error msg -> Error (`Read msg)
    | Ok state ->
      (match f state with
       | Error msg -> Error (`Update msg)
       | Ok (next_state, payload) ->
         write_state config next_state;
         Ok payload))

let gen_request_id () =
  Random_id.prefixed ~prefix:"approval-" ~bytes:16

let find_open_request_in_state state ~goal_id =
  state.requests
  |> List.filter (fun request ->
    String.equal request.goal_id goal_id && request_status_is_open request)
  |> List.rev
  |> List.find_opt (fun _ -> true)

let find_open_request config ~goal_id =
  read_state config |> find_open_request_in_state ~goal_id

let replace_request requests updated =
  List.map
    (fun request ->
      if String.equal request.id updated.id then updated else request)
    requests

let open_request config ~goal_id ?verification_request_id ~opened_by () =
  let opened_at = Masc_domain.now_iso () in
  match
    update_state_result config (fun state ->
       match find_open_request_in_state state ~goal_id with
       | Some _ ->
         Error "goal already has an open approval request"
       | None ->
         let request =
           { id = gen_request_id ()
           ; goal_id
           ; verification_request_id
           ; opened_by
           ; opened_at
           ; status = Open
           ; resolved_by = None
           ; resolved_at = None
           ; resolution_note = None
           }
         in
         Ok
           ( { version = state.version + 1
             ; updated_at = opened_at
             ; requests = state.requests @ [ request ]
             }
           , request ))
  with
  | Error (`Read msg) -> Error ("failed to read goal approval state: " ^ msg)
  | Error (`Update msg) -> Error msg
  | Ok request -> Ok request

let resolve_open_request config ~goal_id ~status ~resolved_by ?note () =
  if status = Open then
    Error "cannot resolve an approval request to open"
  else
    let resolved_at = Masc_domain.now_iso () in
    match
      update_state_result config (fun state ->
         match find_open_request_in_state state ~goal_id with
         | None ->
           Error "goal has no open approval request"
         | Some request ->
           let updated =
             { request with
               status
             ; resolved_by = Some resolved_by
             ; resolved_at = Some resolved_at
             ; resolution_note = note
             }
           in
           Ok
             ( { version = state.version + 1
               ; updated_at = resolved_at
               ; requests = replace_request state.requests updated
               }
             , updated ))
    with
    | Error (`Read msg) -> Error ("failed to read goal approval state: " ^ msg)
    | Error (`Update msg) -> Error msg
    | Ok request -> Ok request
