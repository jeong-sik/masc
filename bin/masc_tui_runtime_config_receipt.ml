type durability =
  | Durable
  | Durability_unconfirmed

type config_state =
  | Configured
  | Rejected
  | Unreadable

type skill_application =
  | Skill_published of
      { input_source_revision : string
      ; snapshot_revision : string
      ; catalog_revision : string
      ; config_state : config_state
      }
  | Skill_unchanged of
      { input_source_revision : string
      ; snapshot_revision : string
      ; catalog_revision : string
      ; config_state : config_state
      }
  | Skill_superseded of
      { commit_order : string
      ; applied_order : string
      }
  | Skill_workspace_retired of { input_source_revision : string }
  | Skill_invalid_workspace

type routing_status =
  | Routing_active
  | Routing_applied

type keeper_overlay_status =
  | Keeper_not_configured
  | Keeper_pending_restart
  | Keeper_applied
  | Keeper_preempted_by_env
  | Keeper_mixed

type applied_at =
  | Not_applied
  | Applied_at_string of string
  | Applied_at_int of int
  | Applied_at_float of float

type application =
  { operation : string
  ; routing_status : routing_status
  ; routing_requires_restart : bool
  ; routing_applied_at : applied_at
  ; keeper_status : keeper_overlay_status
  ; keeper_requires_restart : bool
  ; keeper_applied_at : applied_at
  ; keeper_configured_count : int
  ; keeper_pending_keys : string list
  ; keeper_applied_keys : string list
  ; keeper_preempted_keys : string list
  ; skills : skill_application
  }

type t =
  { source_revision : string
  ; order : string
  ; durability : durability
  ; application : application
  }

let exact_fields expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  let expected = List.sort String.compare expected in
  if actual = expected then Ok () else Error "runtime config receipt fields are invalid"
;;

let field key fields =
  match List.filter (fun (name, _) -> String.equal name key) fields with
  | [ (_, value) ] -> Ok value
  | [] -> Error (Printf.sprintf "missing field %s" key)
  | _ -> Error (Printf.sprintf "duplicate field %s" key)
;;

let string_field key fields =
  match field key fields with
  | Ok (`String value) when not (String.equal value "") -> Ok value
  | Ok _ | Error _ -> Error (Printf.sprintf "invalid string field %s" key)
;;

let bool_field key fields =
  match field key fields with
  | Ok (`Bool value) -> Ok value
  | Ok _ | Error _ -> Error (Printf.sprintf "invalid boolean field %s" key)
;;

let nonnegative_int_field key fields =
  match field key fields with
  | Ok (`Int value) when value >= 0 -> Ok value
  | Ok _ | Error _ -> Error (Printf.sprintf "invalid non-negative integer field %s" key)
;;

let string_list_field key fields =
  match field key fields with
  | Ok (`List values) ->
    let rec decode acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> decode (value :: acc) rest
      | _ :: _ -> Error (Printf.sprintf "invalid string-list field %s" key)
    in
    decode [] values
  | Ok _ | Error _ -> Error (Printf.sprintf "invalid string-list field %s" key)
;;

let timestamp_field key fields =
  match field key fields with
  | Ok `Null -> Ok Not_applied
  | Ok (`String value) when not (String.equal value "") -> Ok (Applied_at_string value)
  | Ok (`Int value) -> Ok (Applied_at_int value)
  | Ok (`Float value) when Float.is_finite value -> Ok (Applied_at_float value)
  | Ok _ | Error _ -> Error (Printf.sprintf "invalid timestamp field %s" key)
;;

let config_state_of_string = function
  | "configured" -> Ok Configured
  | "rejected" -> Ok Rejected
  | "unreadable" -> Ok Unreadable
  | _ -> Error "invalid Skill config_state"
;;

let decode_ready fields =
  let open Result.Syntax in
  let* () =
    exact_fields
      [ "state"
      ; "input_source_revision"
      ; "snapshot_revision"
      ; "catalog_revision"
      ; "config_state"
      ]
      fields
  in
  let* input_source_revision = string_field "input_source_revision" fields in
  let* snapshot_revision = string_field "snapshot_revision" fields in
  let* catalog_revision = string_field "catalog_revision" fields in
  let* config_state_label = string_field "config_state" fields in
  let* config_state = config_state_of_string config_state_label in
  Ok (input_source_revision, snapshot_revision, catalog_revision, config_state)
;;

let decode_skill_application ~source_revision ~order = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* state = string_field "state" fields in
    (match state with
     | "published" | "unchanged" ->
       let* input, snapshot_revision, catalog_revision, config_state =
         decode_ready fields
       in
       if not (String.equal input source_revision)
       then Error "Skill input revision does not match runtime commit"
       else if String.equal state "published"
       then
         Ok
           (Skill_published
              { input_source_revision = input
              ; snapshot_revision
              ; catalog_revision
              ; config_state
              })
       else
         Ok
           (Skill_unchanged
              { input_source_revision = input
              ; snapshot_revision
              ; catalog_revision
              ; config_state
              })
     | "superseded" ->
       let* () = exact_fields [ "state"; "commit_order"; "applied_order" ] fields in
       let* commit_order = string_field "commit_order" fields in
       let* applied_order = string_field "applied_order" fields in
       if String.equal commit_order order
       then Ok (Skill_superseded { commit_order; applied_order })
       else Error "Skill commit order does not match runtime commit"
     | "workspace_retired" ->
       let* () = exact_fields [ "state"; "input_source_revision" ] fields in
       let* input_source_revision = string_field "input_source_revision" fields in
       if String.equal input_source_revision source_revision
       then Ok (Skill_workspace_retired { input_source_revision })
       else Error "retired Skill input revision does not match runtime commit"
     | "invalid_workspace" ->
       let* () = exact_fields [ "state" ] fields in
       Ok Skill_invalid_workspace
     | _ -> Error "unknown Skill application state")
  | _ -> Error "Skill application receipt must be an object"
;;

let routing_status_of_string = function
  | "active" -> Ok Routing_active
  | "applied" -> Ok Routing_applied
  | _ -> Error "invalid routing application status"
;;

let keeper_status_of_string = function
  | "not_configured" -> Ok Keeper_not_configured
  | "pending_restart" -> Ok Keeper_pending_restart
  | "applied" -> Ok Keeper_applied
  | "preempted_by_env" -> Ok Keeper_preempted_by_env
  | "mixed" -> Ok Keeper_mixed
  | _ -> Error "invalid Keeper overlay application status"
;;

let decode_application ~source_revision ~order = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* () = exact_fields [ "operation"; "routing"; "keeper_overlay"; "skills" ] fields in
    let* operation = string_field "operation" fields in
    let* routing = field "routing" fields in
    let* keeper = field "keeper_overlay" fields in
    let* skills_json = field "skills" fields in
    let* routing_status, routing_requires_restart, routing_applied_at =
      match routing with
      | `Assoc routing_fields ->
        let* () = exact_fields [ "status"; "requires_restart"; "applied_at" ] routing_fields in
        let* status_label = string_field "status" routing_fields in
        let* status = routing_status_of_string status_label in
        let* requires_restart = bool_field "requires_restart" routing_fields in
        let* applied_at = timestamp_field "applied_at" routing_fields in
        Ok (status, requires_restart, applied_at)
      | _ -> Error "routing application receipt must be an object"
    in
    let* ( keeper_status
         , keeper_requires_restart
         , keeper_applied_at
         , keeper_configured_count
         , keeper_pending_keys
         , keeper_applied_keys
         , keeper_preempted_keys ) =
      match keeper with
      | `Assoc keeper_fields ->
        let* () =
          exact_fields
            [ "status"
            ; "configured_count"
            ; "requires_restart"
            ; "pending_keys"
            ; "applied_keys"
            ; "preempted_keys"
            ; "applied_at"
            ]
            keeper_fields
        in
        let* status_label = string_field "status" keeper_fields in
        let* status = keeper_status_of_string status_label in
        let* requires_restart = bool_field "requires_restart" keeper_fields in
        let* configured_count = nonnegative_int_field "configured_count" keeper_fields in
        let* pending_keys = string_list_field "pending_keys" keeper_fields in
        let* applied_keys = string_list_field "applied_keys" keeper_fields in
        let* preempted_keys = string_list_field "preempted_keys" keeper_fields in
        let* applied_at = timestamp_field "applied_at" keeper_fields in
        Ok
          ( status
          , requires_restart
          , applied_at
          , configured_count
          , pending_keys
          , applied_keys
          , preempted_keys )
      | _ -> Error "Keeper overlay application receipt must be an object"
    in
    let* skills = decode_skill_application ~source_revision ~order skills_json in
    Ok
      { operation
      ; routing_status
      ; routing_requires_restart
      ; routing_applied_at
      ; keeper_status
      ; keeper_requires_restart
      ; keeper_applied_at
      ; keeper_configured_count
      ; keeper_pending_keys
      ; keeper_applied_keys
      ; keeper_preempted_keys
      ; skills
      }
  | _ -> Error "runtime config application receipt must be an object"
;;

let decode = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* ok = bool_field "ok" fields in
    let* state = string_field "state" fields in
    if not ok
    then Error "runtime config response is not successful"
    else if not (String.equal state "committed")
    then Error "runtime config response is not committed"
    else
      let* commit = field "commit" fields in
      let* application = field "application" fields in
      (match commit with
       | `Assoc commit_fields ->
         let* () = exact_fields [ "source_revision"; "order"; "durability" ] commit_fields in
         let* source_revision = string_field "source_revision" commit_fields in
         let* order = string_field "order" commit_fields in
         let* durability =
           match string_field "durability" commit_fields with
           | Ok "durable" -> Ok Durable
           | Ok "unconfirmed" -> Ok Durability_unconfirmed
           | Ok _ | Error _ -> Error "runtime config durability is invalid"
         in
         let* application = decode_application ~source_revision ~order application in
         Ok { source_revision; order; durability; application }
       | _ -> Error "runtime config commit receipt is missing")
  | _ -> Error "runtime config commit response must be an object"
;;

let config_state_to_string = function
  | Configured -> "configured"
  | Rejected -> "rejected"
  | Unreadable -> "unreadable"
;;

let summary receipt =
  let durability =
    match receipt.durability with
    | Durable -> "durable"
    | Durability_unconfirmed -> "durability-unconfirmed"
  in
  let routing =
    match receipt.application.routing_status with
    | Routing_active -> "routing-active"
    | Routing_applied -> "routing-applied"
  in
  let keeper =
    match receipt.application.keeper_status with
    | Keeper_not_configured -> "keeper-not-configured"
    | Keeper_pending_restart -> "keeper-pending-restart"
    | Keeper_applied -> "keeper-applied"
    | Keeper_preempted_by_env -> "keeper-preempted-by-env"
    | Keeper_mixed -> "keeper-mixed"
  in
  let skills =
    match receipt.application.skills with
    | Skill_published { config_state; _ } ->
      "skills-published/" ^ config_state_to_string config_state
    | Skill_unchanged { config_state; _ } ->
      "skills-unchanged/" ^ config_state_to_string config_state
    | Skill_superseded { applied_order; _ } ->
      "skills-superseded-by/" ^ applied_order
    | Skill_workspace_retired _ -> "skills-workspace-retired"
    | Skill_invalid_workspace -> "skills-invalid-workspace"
  in
  Printf.sprintf
    "commit=%s %s %s %s %s"
    receipt.order
    durability
    routing
    keeper
    skills
;;
