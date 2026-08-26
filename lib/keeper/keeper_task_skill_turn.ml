type error =
  | Reference_resolution_failed of
      { reference : Skill_reference.t
      ; error : Skill_catalog_snapshot.reference_resolution_error
      }
  | Projection_failed of
      { reference : Skill_reference.t
      ; error : Keeper_skill_catalog.error
      }

type selected =
  { reference : Skill_reference.t
  ; skill : Keeper_skill_catalog.skill
  }

type t = { selected : selected list }

type task_scope =
  | No_task
  | Task of
      { task_id : string
      ; references : Skill_reference.t list
      }

type Agent_core.Error.carrier += Task_skill_resolution_error of error

let resolve ~snapshot references =
  let rec loop resolved = function
    | [] -> Ok { selected = List.rev resolved }
    | reference :: rest ->
      (match Skill_catalog_snapshot.resolve_reference snapshot reference with
       | Error error -> Error (Reference_resolution_failed { reference; error })
       | Ok entry ->
         (match Keeper_skill_catalog.project_entry snapshot entry with
          | Error error -> Error (Projection_failed { reference; error })
          | Ok skill -> loop ({ reference; skill } :: resolved) rest))
  in
  loop [] references
;;

let error_code = function
  | Reference_resolution_failed
      { error = Skill_catalog_snapshot.Identity_not_found _; _ } ->
    "task_skill_identity_not_found"
  | Reference_resolution_failed
      { error = Skill_catalog_snapshot.Content_revision_mismatch _; _ } ->
    "task_skill_content_revision_mismatch"
  | Projection_failed _ -> "task_skill_projection_failed"
;;

let reference_json reference =
  Skill_reference.to_yojson reference |> Yojson.Safe.to_string
;;

let error_to_string = function
  | Reference_resolution_failed
      { reference; error = Skill_catalog_snapshot.Identity_not_found _ } ->
    Printf.sprintf "Task Skill identity is absent from the frozen snapshot: %s"
      (reference_json reference)
  | Reference_resolution_failed
      { reference
      ; error =
          Skill_catalog_snapshot.Content_revision_mismatch
            { requested; observed; _ }
      } ->
    Printf.sprintf
      "Task Skill content revision does not match the frozen snapshot: reference=%s requested=%s observed=%s"
      (reference_json reference)
      (Skill_reference.content_revision_to_string requested)
      (Skill_reference.content_revision_to_string observed)
  | Projection_failed { reference; error } ->
    Printf.sprintf
      "Task Skill cannot be projected from the frozen snapshot: reference=%s error=%s"
      (reference_json reference)
      (Keeper_skill_catalog.error_to_string error)
;;

let core_error error =
  Agent_core.Error.Internal_carried
    { message = error_to_string error
    ; carrier = Task_skill_resolution_error error
    }
;;

let of_core_error = function
  | Agent_core.Error.Internal_carried
      { carrier = Task_skill_resolution_error error; _ } ->
    Some error
  | ( Agent_core.Error.Api _
    | Provider _
    | Agent _
    | Mcp _
    | Config _
    | Serialization _
    | Io _
    | Orchestration _
    | Internal _
    | Internal_carried _ ) ->
    None
;;

let scope_of_observation = function
  | Keeper_world_observation_inputs.Current_task task
  | Recovered_current_task { task; _ } ->
    Task { task_id = task.id; references = task.skills }
  | No_current_task
  | Current_task_missing _
  | Current_task_unavailable _ ->
    No_task
;;

let references = function
  | No_task -> []
  | Task { references; _ } -> references
;;
