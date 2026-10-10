type error = Tool_surface_unavailable of string

type selected =
  { reference : Skill_reference.t
  ; skill : Keeper_skill_catalog.skill
  ; diagnostic : Keeper_skill_catalog.error option
  ; task_ids : string list
  }

type unavailable_reason =
  | Catalog_entry_unprojectable of Keeper_skill_catalog.error
  | Pin_unresolved of Skill_catalog_snapshot.reference_resolution_error

type unprojectable =
  { reference : Skill_reference.t
  ; reason : unavailable_reason
  ; task_ids : string list
  }

type t =
  { selected : selected list
  ; unprojectable : unprojectable list
  ; descriptor_authority : Keeper_tool_descriptor.t list option
  }

type partition =
  { instructions : selected list
  ; compositions : selected list
  }

type Agent_core.Error.carrier += Task_skill_resolution_error of error

(* A pinned reference the frozen snapshot cannot give back is a Skill that is
   unavailable this turn, never a setup failure (docs/SKILLS-FLOW.md section
   2a). Two cases: the snapshot holds the identity but the catalog cannot
   project the entry (an instruction body over the inline read boundary,
   #39138), and the pin no longer resolves because the Skill was edited or
   deleted after the Task pinned it. Failing setup for either would stop every
   turn of a Keeper whose current or held Task pins one, including turns about
   other Tasks, until that Task is released: no path re-pins a Task. *)
let resolve_with_task_ids ?descriptors ~snapshot ~task_ids references =
  let rec loop resolved unprojectable = function
    | [] -> Ok { selected = List.rev resolved; unprojectable = List.rev unprojectable; descriptor_authority = descriptors }
    | reference :: rest ->
      (match Skill_catalog_snapshot.resolve_reference snapshot reference with
       | Error resolution ->
         loop
           resolved
           ({ reference; reason = Pin_unresolved resolution; task_ids }
            :: unprojectable)
           rest
       | Ok entry ->
         (match Keeper_skill_catalog.project_entry_or_fallback ?descriptors snapshot entry with
          | Keeper_skill_catalog.Projected skill ->
            loop
              ({ reference; skill; diagnostic = None; task_ids } :: resolved)
              unprojectable
              rest
          | Keeper_skill_catalog.Frozen_instruction { skill; diagnostic } ->
            loop
              ({ reference; skill; diagnostic = Some diagnostic; task_ids } :: resolved)
              unprojectable
              rest
          | Keeper_skill_catalog.Entry_unavailable error ->
            loop
              resolved
              ({ reference
               ; reason = Catalog_entry_unprojectable error
               ; task_ids
               }
               :: unprojectable)
              rest))
  in
  loop [] [] references
;;

let resolve ~snapshot references =
  resolve_with_task_ids ~snapshot ~task_ids:[] references
;;

let resolve_for_task ~snapshot ~task_id references =
  resolve_with_task_ids ~snapshot ~task_ids:[ task_id ] references
;;

let empty = { selected = []; unprojectable = []; descriptor_authority = None }

(* One row per exact reference, carrying every Task id that pinned it. *)
let merge_rows ~reference ~task_ids ~with_task_ids rows =
  let add merged candidate =
    match
      List.find_opt
        (fun known -> Skill_reference.equal (reference known) (reference candidate))
        merged
    with
    | None -> merged @ [ candidate ]
    | Some known ->
      let merged_task_ids =
        List.sort_uniq String.compare (task_ids known @ task_ids candidate)
      in
      List.map
        (fun existing ->
           if Skill_reference.equal (reference existing) (reference candidate)
           then with_task_ids known merged_task_ids
           else existing)
        merged
  in
  List.fold_left add [] rows
;;

let merge selections =
  let descriptor_authority = List.fold_left (fun authority selection ->
    match authority, selection.descriptor_authority with
    | None, other | other, None -> other
    | Some first, Some next when List.length first = List.length next
        && List.for_all2 ( == ) first next -> authority
    | Some _, Some _ -> invalid_arg "Task selections have different frozen Tool authority") None selections in
  { descriptor_authority
  ; selected =
      merge_rows
        ~reference:(fun (row : selected) -> row.reference)
        ~task_ids:(fun (row : selected) -> row.task_ids)
        ~with_task_ids:(fun (row : selected) task_ids -> { row with task_ids })
        (List.concat_map (fun t -> t.selected) selections)
  ; unprojectable =
      merge_rows
        ~reference:(fun (row : unprojectable) -> row.reference)
        ~task_ids:(fun (row : unprojectable) -> row.task_ids)
        ~with_task_ids:(fun (row : unprojectable) task_ids -> { row with task_ids })
        (List.concat_map (fun t -> t.unprojectable) selections)
  }
;;

let resolve_observations ~snapshot ~current_task ~held_task_skills =
  let current =
    match current_task with
    | Keeper_world_observation_inputs.Current_task task
    | Recovered_current_task { task; _ } -> [ task.id, task.skills ]
    | No_current_task
    | Current_task_missing _
    | Current_task_unavailable _ -> []
  in
  let held =
    List.map
      (fun (entry : Keeper_world_observation_inputs.held_task_skills) ->
         entry.held_task_id, entry.held_skills)
      held_task_skills
  in
  let rec loop selections = function
    | [] -> Ok (merge (List.rev selections))
    | (task_id, references) :: rest ->
      (match resolve_for_task ~snapshot ~task_id references with
       | Error _ as error -> error
       | Ok selection -> loop (selection :: selections) rest)
  in
  loop [] (current @ held)
;;

let descriptors selection = selection.descriptor_authority

let with_descriptors ~descriptors ~snapshot selection =
  let requests = List.map (fun (row : selected) -> row.reference,row.task_ids) selection.selected
    @ List.map (fun (row : unprojectable) -> row.reference,row.task_ids) selection.unprojectable in
  let rec loop selections = function
    | [] -> Ok { (merge (List.rev selections)) with descriptor_authority = Some descriptors }
    | (reference, task_ids) :: rest ->
        Result.bind (resolve_with_task_ids ~descriptors ~snapshot ~task_ids [reference])
          (fun selected -> loop (selected :: selections) rest) in
  loop [] requests

let resolve_live_observations ~config ~keeper_name ~snapshot ~current_task ~held_task_skills =
  let exports = (Keeper_lane_addon_runtime.snapshot ~config ~keeper_name).exports in
  let descriptors = Keeper_tool_descriptor.all_descriptors ()
    @ List.map Keeper_lane_addon_descriptor.create exports in
  Result.bind (resolve_observations ~snapshot ~current_task ~held_task_skills)
    (with_descriptors ~descriptors ~snapshot)
;;

let unavailable_reason_code = function
  | Catalog_entry_unprojectable error -> Keeper_skill_catalog.error_code error
  | Pin_unresolved (Skill_catalog_snapshot.Identity_not_found _) ->
    "task_skill_identity_not_found"
  | Pin_unresolved (Skill_catalog_snapshot.Content_revision_mismatch _) ->
    "task_skill_content_revision_mismatch"
;;

let unavailable_reason_to_string = function
  | Catalog_entry_unprojectable error -> Keeper_skill_catalog.error_to_string error
  | Pin_unresolved (Skill_catalog_snapshot.Identity_not_found _) ->
    "the Skill is absent from the frozen snapshot; it was deleted or renamed after the Task pinned it"
  | Pin_unresolved
      (Skill_catalog_snapshot.Content_revision_mismatch { requested; observed; _ }) ->
    Printf.sprintf
      "the Skill content changed after the Task pinned it: pinned=%s current=%s"
      (Skill_reference.content_revision_to_string requested)
      (Skill_reference.content_revision_to_string observed)
;;

let unprojectable_to_string (row : unprojectable) =
  let pinned_by =
    match row.task_ids with
    | [] -> ""
    | task_ids -> " for task " ^ String.concat "," task_ids
  in
  Printf.sprintf
    "Task Skill %s is unavailable%s: %s"
    (Skill_reference.to_yojson row.reference |> Yojson.Safe.to_string)
    pinned_by
    (unavailable_reason_to_string row.reason)
;;

let unprojectable_to_yojson (row : unprojectable) =
  `Assoc
    [ "reference", Skill_reference.to_yojson row.reference
    ; "task_ids", `List (List.map (fun task_id -> `String task_id) row.task_ids)
    ; "error_code", `String (unavailable_reason_code row.reason)
    ; "detail", `String (unavailable_reason_to_string row.reason)
    ]
;;

let error_code = function
  | Tool_surface_unavailable _ -> "lane_addon_surface_unavailable"
;;

let error_to_string = function
  | Tool_surface_unavailable detail -> "Lane Add-on tool surface unavailable: " ^ detail
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

let task_ids_for_reference selection reference =
  selection.selected
  |> List.find_map (fun (selected : selected) ->
       if Skill_reference.equal selected.reference reference
       then Some selected.task_ids
       else None)
  |> Option.value ~default:[]
;;

let executable_selection ~projection selection =
  let selected =
    List.filter
      (fun (selected : selected) ->
         Keeper_skill_catalog.exact_is_executable projection selected.reference)
      selection.selected
  in
  { selection with selected }
;;

(* One computation feeds every surface that advertises a turn's per-task
   Skills: the unified turn prompt, the direct turn prompt, and the dashboard
   prompt preview. The preview regression that motivated this (#31076 review
   P1) came from the preview reassembling the projection by hand and passing
   nothing, which rendered every Task Skill as unavailable while the real turn
   advertised it. Callers pass the already-frozen [selection]; this function
   never re-resolves, so the turn-boundary freeze contract stays intact.

   The projection comes from [Keeper_capability_surface.create], the call the
   executable bundle makes, so a composition the surface withholds is
   advertised as unavailable here too rather than as a callable tool. *)
let exact_task_surfaces
      ~snapshot
      ~tool_deny
      ~sandbox_profile
      ~skill_names
      ~selection
      ~current_task
      ~held_task_skills
  =
  let descriptors = match selection.descriptor_authority with
    | Some descriptors -> descriptors
    | None -> Keeper_tool_descriptor.all_descriptors () in
  let global, _ = Keeper_skill_catalog.of_snapshot ~descriptors snapshot in
  let projection =
    Keeper_capability_surface.create_with_descriptors
      ~tool_descriptors:descriptors
      ~tool_deny
      ~sandbox_profile
      ~skill_names
      ~global_skill_catalog:global
      ~skill_inventory:(Keeper_skill_inventory.of_snapshot ~descriptors snapshot)
      ~task_skills:(skills selection)
    |> Keeper_capability_surface.skill_projection
  in
  let task_ids =
    let current =
      match current_task with
      | Keeper_world_observation_inputs.Current_task task
      | Recovered_current_task { task; _ } -> [ task.id ]
      | No_current_task
      | Current_task_missing _
      | Current_task_unavailable _ -> []
    in
    let held =
      List.map
        (fun (entry : Keeper_world_observation_inputs.held_task_skills) ->
           entry.held_task_id)
        held_task_skills
    in
    List.fold_left
      (fun seen task_id ->
         if List.mem task_id seen then seen else seen @ [ task_id ])
      []
      (current @ held)
  in
  List.map
    (fun task_id ->
       let task =
         selection.selected
         |> List.filter (fun (selected : selected) ->
              List.mem task_id selected.task_ids)
         |> List.map (fun (selected : selected) -> selected.skill)
       in
       let unavailable =
         selection.unprojectable
         |> List.filter (fun (row : unprojectable) -> List.mem task_id row.task_ids)
         |> List.map (fun (row : unprojectable) ->
              Keeper_skill_catalog.unprojectable_exact_surface
                row.reference
                ~diagnostic:(unavailable_reason_to_string row.reason))
       in
       task_id, Keeper_skill_catalog.exact_surfaces projection ~task @ unavailable)
    task_ids
;;
