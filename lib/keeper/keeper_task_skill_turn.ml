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
  ; diagnostic : Keeper_skill_catalog.error option
  ; task_ids : string list
  }

type t = { selected : selected list }

type partition =
  { instructions : selected list
  ; compositions : selected list
  }

type task_scope =
  | No_task
  | Task of
      { task_id : string
      ; references : Skill_reference.t list
      }

type Agent_core.Error.carrier += Task_skill_resolution_error of error

let resolve_with_task_ids ~snapshot ~task_ids references =
  let rec loop resolved = function
    | [] -> Ok { selected = List.rev resolved }
    | reference :: rest ->
      (match Skill_catalog_snapshot.resolve_reference snapshot reference with
       | Error error -> Error (Reference_resolution_failed { reference; error })
       | Ok entry ->
         (match Keeper_skill_catalog.project_entry_or_fallback snapshot entry with
          | Keeper_skill_catalog.Projected skill ->
            loop ({ reference; skill; diagnostic = None; task_ids } :: resolved) rest
          | Keeper_skill_catalog.Frozen_instruction { skill; diagnostic } ->
            loop
              ({ reference; skill; diagnostic = Some diagnostic; task_ids } :: resolved)
              rest
          | Keeper_skill_catalog.Entry_unavailable error ->
            Error (Projection_failed { reference; error })))
  in
  loop [] references
;;

let resolve ~snapshot references =
  resolve_with_task_ids ~snapshot ~task_ids:[] references
;;

let resolve_for_task ~snapshot ~task_id references =
  resolve_with_task_ids ~snapshot ~task_ids:[ task_id ] references
;;

let empty = { selected = [] }

let merge selections =
  let add selected candidate =
    match
      List.find_opt
        (fun known -> Skill_reference.equal known.reference candidate.reference)
        selected
    with
    | None -> selected @ [ candidate ]
    | Some known ->
      let merged =
        { known with
          task_ids =
            List.sort_uniq String.compare (known.task_ids @ candidate.task_ids)
        }
      in
      List.map
        (fun existing ->
           if Skill_reference.equal existing.reference candidate.reference
           then merged
           else existing)
        selected
  in
  { selected = List.fold_left add [] (List.concat_map (fun t -> t.selected) selections) }
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

let partition selection =
  List.fold_left
    (fun partition selected ->
       match selected.skill.surface with
       | Keeper_skill_catalog.Instruction ->
         { partition with instructions = selected :: partition.instructions }
       | Keeper_skill_catalog.Composition _ ->
         { partition with compositions = selected :: partition.compositions })
    { instructions = []; compositions = [] }
    selection.selected
  |> fun partition ->
  { instructions = List.rev partition.instructions
  ; compositions = List.rev partition.compositions
  }
;;

let skills selection = List.map (fun selected -> selected.skill) selection.selected
