type surface =
  | Instruction

type provenance =
  { identity : Skill_catalog_snapshot.identity
  ; source : Skill_source_config.source
  ; source_root : string option
  ; resource_read_max_bytes : Skill_source_config.resource_read_max_bytes option
  ; directory : string
  }

type skill =
  { name : string
  ; description : string
  ; body : string
  ; reference : Skill_reference.t option
  ; provenance : provenance option
  ; surface : surface
  }

type t = skill list

type error =
  | Definition_rejected of
      { directory : string
      ; diagnostics : Agent_core.Skill_document.diagnostic list
      }
  | Duplicate_skill of { name : string }
  | Body_blank of { skill : string }

type rejected_document =
  { directory : string
  ; error : error
  }

type projection_diagnostic =
  { identity : Skill_catalog_snapshot.identity
  ; error : error
  }

type entry_projection =
  | Projected of skill
  | Entry_unavailable of error

type turn_unavailable =
  | Configured_skill_name_unavailable of { name : string }

type configured_name_unavailable = Configured_name_unavailable of string

type turn_projection =
  { catalog : t
  ; unavailable : turn_unavailable list
  }

type exact_surface_availability =
  | Instruction_tool
  | Exact_unavailable of { diagnostic : string }

type exact_surface =
  { reference : Skill_reference.t
  ; availability : exact_surface_availability
  }

let readable_instruction (skill : skill) =
  if Agent_core.Skill_document.is_blank skill.body
  then Error (Body_blank { skill = skill.name })
  else Ok skill
;;

let parse_document (document : Agent_core.Skill_document.t) =
  readable_instruction
    { name = document.name
    ; description = document.description
    ; body = document.body
    ; reference = None
    ; provenance = None
    ; surface = Instruction
    }
;;

let parse_skill ?(descriptors = []) ~directory content =
  ignore (descriptors : Keeper_tool_descriptor.t list);
  match Agent_core.Skill_document.decode ~directory_name:directory content with
  | Unloadable diagnostics -> Error (Definition_rejected { directory; diagnostics })
  | Loaded document -> parse_document document
;;

type authored_source_error =
  | Source_too_large of { bytes : int; max_bytes : int }
  | Invalid_document of error

let validate_authored_source ~descriptors ~directory source_text =
  let max_bytes = 1_048_576 in
  let bytes = String.length source_text in
  if bytes > max_bytes
  then Error (Source_too_large { bytes; max_bytes })
  else
    parse_skill ~descriptors ~directory source_text
    |> Result.map_error (fun error -> Invalid_document error)
;;

let empty = []

let partition_documents documents =
  let rec build (parsed : skill list) rejected = function
    | [] ->
      ( List.sort
          (fun (left : skill) (right : skill) -> String.compare left.name right.name)
          (List.rev parsed)
      , List.rev rejected )
    | (directory, content) :: rest ->
      (match parse_skill ~directory content with
       | Error error -> build parsed ({ directory; error } :: rejected) rest
       | Ok (skill : skill) ->
         if List.exists (fun (known : skill) -> String.equal known.name skill.name) parsed
         then
           build
             parsed
             ({ directory; error = Duplicate_skill { name = skill.name } } :: rejected)
             rest
         else build (skill :: parsed) rejected rest)
  in
  build [] [] documents
;;

let skills catalog = catalog

let provenance_of_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  let resource_read_max_bytes =
    match Skill_catalog_snapshot.config_state snapshot with
    | Configured { config; _ } -> config.resource_read_max_bytes
    | Config_rejected _ | Config_unreadable _ -> None
  in
  Skill_catalog_snapshot.sources snapshot
  |> fun sources -> List.nth_opt sources entry.source_index
  |> Option.map (fun scan ->
       let source_root =
         match scan.Skill_catalog_snapshot.observation with
         | Source_ready { resolved_path; _ } -> Some resolved_path
         | Source_missing _
         | Source_not_directory _
         | Source_unavailable _
         | Source_unresolved _ ->
           None
       in
       { identity = entry.identity
       ; source = scan.Skill_catalog_snapshot.source.source
       ; source_root
       ; resource_read_max_bytes
       ; directory = entry.directory
       })
;;

let entry_projection_of snapshot (entry : Skill_catalog_snapshot.entry) =
  match parse_document entry.document with
  | Ok skill ->
    Projected
      { skill with
        reference = Some (Skill_catalog_snapshot.entry_reference entry)
      ; provenance = provenance_of_entry snapshot entry
      }
  | Error error -> Entry_unavailable error
;;

type projected_entry =
  { snapshot_entry : Skill_catalog_snapshot.entry
  ; projection : entry_projection
  ; effective : bool
  }

let projected_entry_of snapshot (entry : Skill_catalog_snapshot.entry) =
  { snapshot_entry = entry
  ; projection = entry_projection_of snapshot entry
  ; effective = Skill_catalog_snapshot.is_effective_identity snapshot entry.identity
  }
;;

type prepared =
  { snapshot : Skill_catalog_snapshot.t
  ; descriptors : Keeper_tool_descriptor.t list
  ; entries : projected_entry list
  ; entries_by_identity : projected_entry Skill_reference.Identity_map.t
  }

module Preparation_snapshot_key = struct
  type t = Skill_catalog_snapshot.t
  let equal left right = left == right
  let hash snapshot = Hashtbl.hash (Skill_catalog_snapshot.snapshot_revision snapshot)
end

module Preparation_descriptor_key = struct
  type t = Keeper_tool_descriptor.t
  let equal left right = left == right
  let hash descriptor = Hashtbl.hash descriptor.Keeper_tool_descriptor.id
end

module Preparation_snapshots = Ephemeron.K1.Make (Preparation_snapshot_key)
module Preparation_bindings = Ephemeron.Kn.Make (Preparation_descriptor_key)

type preparation_slot =
  { construction_lock : Cross_context_mutex.t
  ; mutable value : prepared option
  }

let preparations : preparation_slot Preparation_bindings.t Preparation_snapshots.t =
  Preparation_snapshots.create 0
;;

let preparations_mutex = Stdlib.Mutex.create ()

let preparation_slot ~descriptors snapshot =
  let keys = Array.of_list descriptors in
  Stdlib.Mutex.protect preparations_mutex (fun () ->
    let bindings =
      match Preparation_snapshots.find_opt preparations snapshot with
      | Some bindings -> bindings
      | None ->
        Preparation_snapshots.clean preparations;
        let bindings = Preparation_bindings.create 0 in
        Preparation_snapshots.add preparations snapshot bindings;
        bindings
    in
    match Preparation_bindings.find_opt bindings keys with
    | Some slot -> slot
    | None ->
      Preparation_bindings.clean bindings;
      let slot = { construction_lock = Cross_context_mutex.create (); value = None } in
      Preparation_bindings.add bindings keys slot;
      slot)
;;

let prepared_matches prepared ~descriptors snapshot =
  prepared.snapshot == snapshot
  && (prepared.descriptors == descriptors
      || (List.length prepared.descriptors = List.length descriptors
          && List.for_all2 ( == ) prepared.descriptors descriptors))
;;

let prepared_snapshot prepared = prepared.snapshot
let prepared_descriptor_count prepared = List.length prepared.descriptors

let prepare_snapshot ~descriptors snapshot =
  Keeper_skill_preparation_observation.cache_access
    Keeper_skill_preparation_observation.Projection
    ~snapshot
    ~descriptor_count:(fun () -> List.length descriptors)
  @@ fun observation ->
  let slot = preparation_slot ~descriptors snapshot in
  Keeper_skill_preparation_observation.lookup_finished observation;
  Cross_context_mutex.with_lock slot.construction_lock (fun () ->
    Keeper_skill_preparation_observation.lock_acquired observation;
    match slot.value with
    | Some prepared ->
      Keeper_skill_preparation_observation.decided
        observation
        Keeper_skill_preparation_observation.Reused;
      prepared
    | None ->
      let entries =
        List.map (projected_entry_of snapshot) (Skill_catalog_snapshot.entries snapshot)
      in
      let entries_by_identity =
        List.fold_left
          (fun index (entry : projected_entry) ->
             Skill_reference.Identity_map.add entry.snapshot_entry.identity entry index)
          Skill_reference.Identity_map.empty
          entries
      in
      let prepared = { snapshot; descriptors; entries; entries_by_identity } in
      slot.value <- Some prepared;
      Keeper_skill_preparation_observation.decided
        observation
        Keeper_skill_preparation_observation.Constructed;
      prepared)
;;

let project_prepared_entry prepared (entry : Skill_catalog_snapshot.entry) =
  match Skill_reference.Identity_map.find_opt entry.identity prepared.entries_by_identity with
  | Some projected when projected.snapshot_entry == entry -> projected.projection
  | Some _ | None -> entry_projection_of prepared.snapshot entry
;;

let project_entry_or_fallback
      ?(descriptors = Keeper_tool_descriptor.all_descriptors ())
      snapshot
      entry
  =
  project_prepared_entry (prepare_snapshot ~descriptors snapshot) entry
;;

let fold_prepared_entries prepared ~init ~f =
  List.fold_left
    (fun acc (entry : projected_entry) ->
       f acc entry.snapshot_entry entry.projection ~effective:entry.effective)
    init
    prepared.entries
;;

let catalog_of_projected_entries projected_entries =
  projected_entries
  |> List.fold_left
       (fun (catalog, diagnostics) { snapshot_entry; projection; effective = _ } ->
          match projection with
          | Projected skill -> skill :: catalog, diagnostics
          | Entry_unavailable error ->
            catalog, { identity = snapshot_entry.identity; error } :: diagnostics)
       ([], [])
  |> fun (catalog, diagnostics) -> List.rev catalog, List.rev diagnostics
;;

let prepared_catalog prepared =
  prepared.entries
  |> List.filter (fun (projected : projected_entry) -> projected.effective)
  |> catalog_of_projected_entries
;;

let of_snapshot ?(descriptors = Keeper_tool_descriptor.all_descriptors ()) snapshot =
  prepared_catalog (prepare_snapshot ~descriptors snapshot)
;;

let all_entries_of_snapshot
      ?(descriptors = Keeper_tool_descriptor.all_descriptors ())
      snapshot
  =
  let preparation = prepare_snapshot ~descriptors snapshot in
  catalog_of_projected_entries preparation.entries
;;

let same_exact_reference (left : skill) (right : skill) =
  match left.reference, right.reference with
  | Some left, Some right -> Skill_reference.equal left right
  | Some _, None | None, Some _ | None, None -> false
;;

let project_turn ~names ~global ~task =
  let candidates = task @ skills global in
  let selected_candidates, configured_unavailable =
    match names with
    | None -> candidates, []
    | Some names ->
      let selected =
        List.filter
          (fun (skill : skill) -> List.exists (String.equal skill.name) names)
          candidates
      in
      let unavailable =
        names
        |> Json_util.dedupe_keep_order
        |> List.filter_map (fun name ->
             if List.exists (fun (skill : skill) -> String.equal skill.name name) candidates
             then None
             else Some (Configured_skill_name_unavailable { name }))
      in
      selected, unavailable
  in
  let catalog =
    List.fold_left
      (fun selected skill ->
         if List.exists (same_exact_reference skill) selected
         then selected
         else selected @ [ skill ])
      []
      selected_candidates
  in
  { catalog; unavailable = configured_unavailable }
;;

let turn_unavailable_to_string = function
  | Configured_skill_name_unavailable { name } ->
    Printf.sprintf "configured Keeper Skill name %S is unavailable" name
;;

let configured_names_unavailable projection =
  List.map
    (function
      | Configured_skill_name_unavailable { name } -> Configured_name_unavailable name)
    projection.unavailable
;;

let configured_name_unavailable_to_yojson (Configured_name_unavailable name) =
  `Assoc
    [ "name", `String name
    ; "reason", `String "not_in_turn_skill_catalog"
    ]
;;

let exact_skill catalog reference =
  List.find_opt
    (fun (skill : skill) ->
       match skill.reference with
       | Some known -> Skill_reference.equal known reference
       | None -> false)
    (skills catalog)
;;

let exact_is_executable projection reference =
  Option.is_some (exact_skill projection.catalog reference)
;;

let exact_surfaces projection ~task =
  List.filter_map
    (fun (skill : skill) ->
       match skill.reference with
       | None -> None
       | Some reference ->
         let availability =
           match exact_skill projection.catalog reference with
           | Some { surface = Instruction; _ } -> Instruction_tool
           | None ->
             Exact_unavailable
               { diagnostic =
                   Printf.sprintf
                     "exact Task Skill is unavailable in the executable turn projection: %s"
                     (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
               }
         in
         Some { reference; availability })
    task
;;

let exact_surface_to_yojson surface =
  let kind, tool_name, diagnostic =
    match surface.availability with
    | Instruction_tool -> "instruction", Some "keeper_skill", None
    | Exact_unavailable { diagnostic } -> "unavailable", None, Some diagnostic
  in
  `Assoc
    ([ "reference", Skill_reference.to_yojson surface.reference
     ; "kind", `String kind
     ]
     @ Option.to_list (Option.map (fun value -> "tool_name", `String value) tool_name)
     @ Option.to_list
         (Option.map (fun value -> "diagnostic", `String value) diagnostic))
;;

let find catalog name =
  List.find_opt (fun skill -> String.equal skill.name name) catalog
;;

let instruction_entries catalog =
  List.map (fun skill -> skill.name, skill.description, skill.body) catalog
;;

let surface_to_string = function
  | Instruction -> "instruction"
;;

let provenance_to_yojson provenance =
  let source = provenance.source in
  `Assoc
    [ "identity", Skill_catalog_snapshot.identity_to_yojson provenance.identity
    ; "directory", `String provenance.directory
    ; ( "source"
      , `Assoc
          [ "id", `String (Skill_source_config.source_id_to_string source.id)
          ; "anchor", `String (Skill_source_config.anchor_to_string source.anchor)
          ; "path", `String source.configured_path
          ; "access", `String (Skill_source_config.access_to_string source.access)
          ] )
    ]
;;

let error_code = function
  | Definition_rejected _ -> "definition_rejected"
  | Duplicate_skill _ -> "duplicate_skill"
  | Body_blank _ -> "body_blank"
;;

let error_to_string = function
  | Definition_rejected { directory; diagnostics } ->
    Printf.sprintf
      "skill directory %S: %s"
      directory
      (String.concat
         "; "
         (List.map Agent_core.Skill_document.diagnostic_to_string diagnostics))
  | Duplicate_skill { name } -> "duplicate skill name: " ^ name
  | Body_blank { skill } ->
    Printf.sprintf
      "skill %S: body is blank; keeper_skill returns the body as the instruction"
      skill
;;

let unprojectable_exact_surface reference ~diagnostic =
  { reference; availability = Exact_unavailable { diagnostic } }
;;
