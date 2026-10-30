type error =
  | Tool_surface_unavailable of string
  | Skill_config_rejected of { diagnostics : Skill_source_config.diagnostic list }
  | Skill_config_unreadable of { detail : string }
  | Skill_source_unreadable of
      { source_id : string
      ; observation : Skill_catalog_snapshot.source_observation
      }
  | Skill_entry_unreadable of
      { reference : Skill_reference.t
      ; path : string
      ; detail : string
      }

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

type preparation =
  { projection : Keeper_skill_catalog.prepared
  ; catalog : Keeper_skill_catalog.t
  ; diagnostics : Keeper_skill_catalog.projection_diagnostic list
  ; inventory : Keeper_skill_inventory.t
  }

type t =
  { selected : selected list
  ; unprojectable : unprojectable list
  ; descriptor_authority : Keeper_tool_descriptor.t list option
  ; preparation : preparation option
  }

type partition =
  { instructions : selected list
  ; compositions : selected list
  }

type Agent_core.Error.carrier += Task_skill_resolution_error of error

(* A snapshot whose Skill configuration was rejected or unreadable holds no
   entries, so every pin would read as deleted. That is a configuration
   problem, not a stale pin, and it stops setup: the Task's procedure is not
   known to be unavailable, it is unknown. The service publishes such a
   snapshot over the last good one and a workspace without a published
   revision is captured as unreadable, so it does reach turns. With no
   reference there is nothing to misreport and no failure. *)
let require_configured snapshot references =
  match references, Skill_catalog_snapshot.config_state snapshot with
  | [], _ -> Ok ()
  | _ :: _, Skill_catalog_snapshot.Configured _ -> Ok ()
  | _ :: _, Config_rejected { diagnostics; _ } ->
    Error (Skill_config_rejected { diagnostics })
  | _ :: _, Config_unreadable { detail } -> Error (Skill_config_unreadable { detail })
;;

(* A pin that resolves to no entry is stale only when its source was read
   successfully. A configured snapshot still carries a scan per source, and a
   scan whose observation is not ready -- or whose read of the pinned package
   failed -- may still hold the Skill: downgrading that pin would run the turn
   without its procedure and misreport the cause as a deletion. A source the
   snapshot does not scan at all was unconfigured after the Task pinned it,
   which reads as deleted: building a configured snapshot refuses scans that
   omit a configured source. *)
let unreadable_pin_error ~snapshot ~reference = function
  | Skill_catalog_snapshot.Content_revision_mismatch _ -> None
  | Skill_catalog_snapshot.Identity_not_found identity ->
    let source_id = Skill_reference.identity_source_id_to_string identity in
    let scan =
      List.find_opt
        (fun (scan : Skill_catalog_snapshot.source_scan) ->
           String.equal
             (Skill_source_config.source_id_to_string scan.source.source.id)
             source_id)
        (Skill_catalog_snapshot.sources snapshot)
    in
    (match scan with
     | None -> None
     | Some scan ->
       (match scan.observation with
        | Skill_catalog_snapshot.Source_ready _ ->
          let package_id = Skill_reference.identity_package_id_to_string identity in
          let unreadable =
            List.find_opt
              (fun (rejection : Skill_catalog_snapshot.rejection) ->
                 String.equal
                   (Skill_source_config.source_id_to_string rejection.source_id)
                   source_id
                 && (match rejection.package_id with
                     | Some package ->
                       String.equal (Skill_reference.package_id_to_string package) package_id
                     | None -> false)
                 && (match rejection.reason with
                     | Skill_catalog_snapshot.Document_unreadable _ -> true
                     | Skill_catalog_snapshot.Document_rejected _
                     | Skill_catalog_snapshot.Exact_identity_duplicate _
                     | Skill_catalog_snapshot.Invalid_package_id _ -> false))
              (Skill_catalog_snapshot.rejections snapshot)
          in
          (match unreadable with
           | None -> None
           | Some rejection ->
             (match rejection.reason with
              | Skill_catalog_snapshot.Document_unreadable { path; detail } ->
                Some (Skill_entry_unreadable { reference; path; detail })
              | Skill_catalog_snapshot.Document_rejected _
              | Skill_catalog_snapshot.Exact_identity_duplicate _
              | Skill_catalog_snapshot.Invalid_package_id _ -> None))
        | (Skill_catalog_snapshot.Source_missing _
          | Skill_catalog_snapshot.Source_not_directory _
          | Skill_catalog_snapshot.Source_unavailable _
          | Skill_catalog_snapshot.Source_unresolved _) as observation ->
          Some (Skill_source_unreadable { source_id; observation })))
;;

module Preparation_key = struct
  type t = Keeper_skill_catalog.prepared
  let equal left right = left == right
  let hash projection =
    Hashtbl.hash
      (Skill_catalog_snapshot.snapshot_revision
         (Keeper_skill_catalog.prepared_snapshot projection))
end

module Preparations = Ephemeron.K1.Make (Preparation_key)

type preparation_slot =
  { construction_lock : Cross_context_mutex.t
  ; mutable value : preparation option
  }

let preparations : preparation_slot Preparations.t = Preparations.create 0
let preparations_mutex = Stdlib.Mutex.create ()

let preparation_of_projection projection =
  let snapshot = Keeper_skill_catalog.prepared_snapshot projection in
  Keeper_skill_preparation_observation.cache_access Keeper_skill_preparation_observation.Task_product ~snapshot
    ~descriptor_count:(fun () -> Keeper_skill_catalog.prepared_descriptor_count projection) @@ fun observation ->
  let slot = Stdlib.Mutex.protect preparations_mutex (fun () ->
    match Preparations.find_opt preparations projection with
    | Some slot -> slot
    | None ->
      Preparations.clean preparations;
      let slot = { construction_lock = Cross_context_mutex.create (); value = None } in
      Preparations.add preparations projection slot;
      slot)
  in
  Keeper_skill_preparation_observation.lookup_finished observation;
  Cross_context_mutex.with_lock slot.construction_lock (fun () ->
    Keeper_skill_preparation_observation.lock_acquired observation;
    match slot.value with
    | Some preparation ->
      Keeper_skill_preparation_observation.decided observation Keeper_skill_preparation_observation.Reused;
      preparation
    | None ->
      let catalog, diagnostics = Keeper_skill_catalog.prepared_catalog projection in
      let inventory = Keeper_skill_inventory.of_prepared projection in
      let preparation = { projection; catalog; diagnostics; inventory } in
      slot.value <- Some preparation;
      Keeper_skill_preparation_observation.decided observation Keeper_skill_preparation_observation.Constructed;
      preparation)
;;

(* Against a configured snapshot, a pinned reference it cannot give back is a
   Skill that is unavailable this turn rather than a setup failure
   (docs/SKILLS-FLOW.md section 2a): the snapshot holds the identity but the
   catalog cannot project the entry (an instruction body over the inline read
   boundary, #39138), or the pin no longer resolves because the Skill was
   edited or deleted after the Task pinned it. Failing setup for either would
   stop every turn of a Keeper whose current or held Task pins one, including
   turns about other Tasks, until that Task is released: no path re-pins a
   Task. The downgrade holds only for successfully scanned sources; a pin
   into an unreadable source or entry stops setup above instead. *)
(* Select the required result shape at construction: ordinary resolution needs
   only the selection; executable binding needs its coherent preparation too. *)
let resolve_requests ?descriptors ~snapshot ~finish requests =
  let tool_descriptors = match descriptors with
    | Some descriptors -> descriptors
    | None -> Keeper_tool_descriptor.all_descriptors () in
  let prepare = function
    | Some projection -> projection
    | None -> Keeper_skill_catalog.prepare_snapshot ~descriptors:tool_descriptors snapshot in
  let rec loop projection resolved unprojectable = function
    | [] ->
      let preparation = preparation_of_projection (prepare projection) in
      let selection={ selected = List.rev resolved; unprojectable = List.rev unprojectable;
        descriptor_authority = descriptors; preparation = Some preparation } in
      Ok (finish selection preparation)
    | (reference, task_ids) :: rest ->
      (match Skill_catalog_snapshot.resolve_reference snapshot reference with
       | Error resolution ->
         (match unreadable_pin_error ~snapshot ~reference resolution with
          | Some error -> Error error
          | None ->
            loop projection
              resolved
              ({ reference; reason = Pin_unresolved resolution; task_ids }
               :: unprojectable)
              rest)
       | Ok entry ->
         let projection = prepare projection in
         (match Keeper_skill_catalog.project_prepared_entry projection entry with
          | Keeper_skill_catalog.Projected skill ->
            loop (Some projection)
              ({ reference; skill; diagnostic = None; task_ids } :: resolved)
              unprojectable
              rest
          | Keeper_skill_catalog.Frozen_instruction { skill; diagnostic } ->
            loop (Some projection)
              ({ reference; skill; diagnostic = Some diagnostic; task_ids } :: resolved)
              unprojectable
              rest
          | Keeper_skill_catalog.Entry_unavailable error ->
            loop (Some projection)
              resolved
              ({ reference
               ; reason = Catalog_entry_unprojectable error
               ; task_ids
               }
               :: unprojectable)
              rest))
  in
  Result.bind (require_configured snapshot (List.map fst requests)) (fun () ->
    loop None [] [] requests)
;;

let resolve_with_task_ids ?descriptors ~snapshot ~task_ids references =
  resolve_requests ?descriptors ~snapshot ~finish:(fun selection _ -> selection)
    (List.map (fun reference -> reference, task_ids) references)
;;

let resolve ?descriptors ~snapshot references =
  resolve_with_task_ids ?descriptors ~snapshot ~task_ids:[] references
;;

let resolve_for_task ?descriptors ~snapshot ~task_id references =
  resolve_with_task_ids ?descriptors ~snapshot ~task_ids:[ task_id ] references
;;

let empty = { selected = []; unprojectable = []; descriptor_authority = None; preparation = None }

module Task_owner_set = Set.Make (String)

(* One row per exact reference, carrying every Task id that pinned it. *)
let merge_rows ~reference ~task_ids ~with_task_ids rows =
  let add_owners owners ids = List.fold_left
      (fun owners task_id -> Task_owner_set.add task_id owners) owners ids in
  let add (next_ordinal, indexed) candidate =
    let exact = reference candidate in
    match
      Skill_reference.Exact_map.find_opt exact indexed
    with
    | None ->
      next_ordinal + 1,
      Skill_reference.Exact_map.add exact (next_ordinal, candidate, None) indexed
    | Some (ordinal, known, owners) ->
      let owners = match owners with
        | None -> add_owners Task_owner_set.empty (task_ids known)
        | Some owners -> owners in
      let owners = add_owners owners (task_ids candidate) in
      next_ordinal,
      Skill_reference.Exact_map.add exact
        (ordinal, known, Some owners) indexed
  in
  let _, indexed = List.fold_left add (0, Skill_reference.Exact_map.empty) rows in
  (* Map key order must not reorder the first original rows. Ordinals belong
     to this fold only; enumeration needs no partial lookup or fallback row. *)
  Skill_reference.Exact_map.fold (fun _ row ordered -> row :: ordered) indexed []
  |> List.sort (fun (first, _, _) (next, _, _) -> Int.compare first next)
  |> List.map (fun (_, known, owners) ->
       match owners with
       | None -> known
       | Some owners ->
         (* The callbacks only read/rebuild immutable rows. No intermediate
            union escapes; emit one canonical owner list per repeated pin. *)
         with_task_ids known (Task_owner_set.elements owners))
;;

let same_descriptors first next =
  first == next || (List.length first=List.length next && List.for_all2 ( == ) first next)

let same_descriptor_binding first next = match first,next with
  | None,None -> true
  | Some first,Some next -> same_descriptors first next
  | None,Some _ | Some _,None -> false

let merge selections =
  let descriptor_authority = List.fold_left (fun authority selection ->
    match authority, selection.descriptor_authority with
    | None, other | other, None -> other
    | Some first, Some next when same_descriptors first next -> authority
    | Some _, Some _ -> invalid_arg "Task selections have different frozen Tool authority") None selections in
  let preparation = match selections with
    | ({preparation=Some first;_} as original) :: rest
      when List.for_all (fun selection ->
        same_descriptor_binding original.descriptor_authority selection.descriptor_authority
        && match selection.preparation with
           | Some next -> first.projection == next.projection | None -> false) rest -> Some first
    | [] | _ :: _ -> None in
  { descriptor_authority
  ; preparation
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

let resolve_observations_with_authority ~descriptor_authority ~snapshot ~current_task ~held_task_skills =
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
  let requests = current @ held
    |> List.concat_map (fun (task_id,references) ->
        List.map (fun reference -> reference,[task_id]) references)
    |> merge_rows ~reference:fst ~task_ids:snd
        ~with_task_ids:(fun (reference,_) task_ids -> reference,task_ids) in
  resolve_requests ?descriptors:descriptor_authority ~snapshot ~finish:(fun selection _ -> selection) requests
;;

let resolve_observations ~snapshot ~current_task ~held_task_skills =
  resolve_observations_with_authority ~descriptor_authority:None
    ~snapshot ~current_task ~held_task_skills

let descriptors selection = selection.descriptor_authority

let retain_surface ~snapshot ~descriptors preparation =
  Keeper_skill_preparation_observation.cache_access Keeper_skill_preparation_observation.Retained_turn_surface ~snapshot
    ~descriptor_count:(fun () -> List.length descriptors) (fun observation ->
      Keeper_skill_preparation_observation.decided observation Keeper_skill_preparation_observation.Reused;
      preparation)

let resolve_surface ~descriptors ~snapshot references =
  resolve_requests ~descriptors ~snapshot
    ~finish:(fun selection preparation ->
      selection, retain_surface ~snapshot ~descriptors preparation)
    (List.map (fun reference -> reference, []) references)

let bind_surface ~descriptors ~snapshot selection =
  let finish selection preparation =
    selection,retain_surface ~snapshot ~descriptors preparation in
  match selection.preparation, selection.descriptor_authority with
  | Some original, Some bound when same_descriptors bound descriptors
      && Keeper_skill_catalog.prepared_matches original.projection ~descriptors snapshot ->
      Ok (finish selection original)
  | None, _ | _, None | Some _, Some _ ->
    let requests = List.map (fun (row : selected) -> row.reference,row.task_ids) selection.selected
      @ List.map (fun (row : unprojectable) -> row.reference,row.task_ids) selection.unprojectable
      |> merge_rows ~reference:fst ~task_ids:snd
          ~with_task_ids:(fun (reference,_) task_ids -> reference,task_ids) in
    (* Resolution constructs the matching values together. Returning that product
       requires no second validation or optional-field recovery after binding. *)
    resolve_requests ~descriptors ~snapshot ~finish requests

let prepare_surface ~snapshot ~descriptors selection =
  match selection.preparation with
  | Some preparation when Keeper_skill_catalog.prepared_matches preparation.projection ~descriptors snapshot ->
      retain_surface ~snapshot ~descriptors preparation
  | Some _ | None ->
    Keeper_skill_catalog.prepare_snapshot ~descriptors snapshot |> preparation_of_projection
;;

let resolve_live_observations ~config ~keeper_name ~snapshot ~current_task ~held_task_skills =
  let exports = (Keeper_lane_addon_runtime.snapshot ~config ~keeper_name).exports in
  let descriptors = Keeper_tool_descriptor.all_descriptors ()
    @ List.map Keeper_lane_addon_descriptor.create exports in
  resolve_observations_with_authority ~descriptor_authority:(Some descriptors)
    ~snapshot ~current_task ~held_task_skills
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
  | Skill_config_rejected _ -> "task_skill_config_rejected"
  | Skill_config_unreadable _ -> "task_skill_config_unreadable"
  | Skill_source_unreadable _ -> "task_skill_source_unreadable"
  | Skill_entry_unreadable _ -> "task_skill_entry_unreadable"
;;

let source_observation_to_string = function
  | Skill_catalog_snapshot.Source_ready _ -> "ready"
  | Skill_catalog_snapshot.Source_missing { resolved_path } ->
    Printf.sprintf "source directory is missing: %s" resolved_path
  | Skill_catalog_snapshot.Source_not_directory { resolved_path; kind = _ } ->
    Printf.sprintf "source path is not a directory: %s" resolved_path
  | Skill_catalog_snapshot.Source_unavailable { resolved_path; operation; detail } ->
    Printf.sprintf "%s failed on %s: %s"
      (Skill_catalog_snapshot.source_operation_to_string operation)
      resolved_path
      detail
  | Skill_catalog_snapshot.Source_unresolved resolution ->
    (match resolution with
     | Skill_source_config.Resolved path ->
       Printf.sprintf "source did not resolve: %s" path
     | Skill_source_config.Anchor_unavailable anchor ->
       Printf.sprintf "source anchor is unavailable: %s"
         (Skill_source_config.anchor_to_string anchor)
     | Skill_source_config.Anchor_invalid { anchor; rejection } ->
       Printf.sprintf "source anchor is invalid: %s: %s"
         (Skill_source_config.anchor_to_string anchor)
         (Skill_source_config.anchor_rejection_to_string rejection)
     | Skill_source_config.Path_rejected rejection ->
       Printf.sprintf "source path is rejected: %s"
         (Skill_source_config.path_rejection_to_string rejection))
;;

let error_to_string = function
  | Tool_surface_unavailable detail -> "Lane Add-on tool surface unavailable: " ^ detail
  | Skill_config_rejected { diagnostics } ->
    "Skill configuration is rejected, so Task Skills cannot be resolved: "
    ^ String.concat "; " (List.map Skill_source_config.diagnostic_to_string diagnostics)
  | Skill_config_unreadable { detail } ->
    "Skill configuration is unreadable, so Task Skills cannot be resolved: " ^ detail
  | Skill_source_unreadable { source_id; observation } ->
    Printf.sprintf
      "Skill source %s was not read successfully, so a Task pin into it cannot be told apart from a deleted Skill: %s"
      source_id
      (source_observation_to_string observation)
  | Skill_entry_unreadable { reference; path; detail } ->
    Printf.sprintf "Skill %s could not be read (%s), so its Task pin cannot be told apart from a deleted Skill: %s"
      (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
      path
      detail
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
    | Orchestration _ | Media _
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

module Task_surface_map = Map.Make (String)

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
  let preparation = prepare_surface ~snapshot ~descriptors selection in
  let projection =
    Keeper_capability_surface.create_with_descriptors
      ~tool_descriptors:descriptors
      ~tool_deny
      ~sandbox_profile
      ~skill_names
      ~global_skill_catalog:preparation.catalog
      ~skill_inventory:preparation.inventory
      ~task_skills:(skills selection)
    |> Keeper_capability_surface.skill_projection
  in
  let task_ids, by_task =
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
    let reversed, by_task = List.fold_left
      (fun ((seen, by_task) as previous) task_id ->
         if Task_surface_map.mem task_id by_task then previous
         else task_id :: seen, Task_surface_map.add task_id [] by_task)
      ([], Task_surface_map.empty)
      (current @ held)
    in
    List.rev reversed, by_task
  in
  match task_ids with
  | [] -> []
  | _ :: _ ->
    (* A shared exact pin has one immutable surface in this projection, not
       one catalog lookup/diagnostic rendering per Task that pinned it. Only
       observed owners receive it; selection provenance cannot add a Task. *)
    let add_owned_surfaces by_task task_ids make_surfaces =
      let owners = List.sort_uniq String.compare task_ids
        |> List.filter (fun task_id -> Task_surface_map.mem task_id by_task) in
      match owners with
      | [] -> by_task
      | _ :: _ ->
        let surfaces = make_surfaces () in
        List.fold_left
          (fun by_task task_id ->
             Task_surface_map.update task_id
               (Option.map (List.rev_append surfaces)) by_task)
          by_task owners
    in
    let by_task = List.fold_left
      (fun by_task (row : selected) ->
         add_owned_surfaces by_task row.task_ids (fun () ->
           Keeper_skill_catalog.exact_surfaces projection ~task:[row.skill]))
      by_task selection.selected in
    let by_task = List.fold_left
      (fun by_task (row : unprojectable) ->
         add_owned_surfaces by_task row.task_ids (fun () ->
           [Keeper_skill_catalog.unprojectable_exact_surface row.reference
              ~diagnostic:(unavailable_reason_to_string row.reason)]))
      by_task selection.unprojectable in
    List.map
      (fun task_id ->
         task_id, Option.fold ~none:[] ~some:List.rev
           (Task_surface_map.find_opt task_id by_task))
      task_ids
;;
