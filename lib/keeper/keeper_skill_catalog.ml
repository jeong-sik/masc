module Catalog = Keeper_tool_composition_catalog

type surface =
  | Instruction
  | Composition of Catalog.entry

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
  ; conformance : Agent_core.Skill_document.conformance
  ; reference : Skill_reference.t option
  ; provenance : provenance option
  ; composition_span : Keeper_skill_body_ast.span option
  ; surface : surface
  }

type composition =
  { entry : Catalog.entry
  ; provenance : provenance option
  ; span : Keeper_skill_body_ast.span option
  }

type t = skill list

type named_skill_error = Missing_named_skill of { name : string }

type error =
  | Definition_rejected of
      { directory : string
      ; diagnostics : Agent_core.Skill_document.diagnostic list
      }
  | Unterminated_composition_block of { skill : string }
  | Multiple_composition_blocks of
      { skill : string
      ; count : int
      }
  | Composition_rejected of
      { skill : string
      ; error : Catalog.error
      }
  | Not_exactly_one_composition of
      { skill : string
      ; count : int
      }
  | Composition_name_mismatch of
      { skill : string
      ; declared : string
      }
  | Composition_info_near_miss of
      { skill : string
      ; info : string
      }
  | Removed_invocation_policy of
      { skill : string
      ; field : string
      }
  | Duplicate_skill of { name : string }

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
  | Frozen_instruction of
      { skill : skill
      ; diagnostic : error
      }
  | Entry_unavailable of error

type turn_unavailable =
  | Composition_tool_name_collision of
      { tool_name : string
      ; selected : Skill_reference.t
      ; unavailable : Skill_reference.t
      }
  | Composition_tool_name_collision_unattributed of
      { tool_name : string
      ; selected_name : string
      ; unavailable_name : string
      }

type turn_projection =
  { catalog : t
  ; unavailable : turn_unavailable list
  }

type exact_surface_availability =
  | Instruction_tool
  | Composition_tool of { tool_name : string }
  | Exact_unavailable of { diagnostic : string }

type exact_surface =
  { reference : Skill_reference.t
  ; availability : exact_surface_availability
  }

let composition_fence_info = "toml composition"
let composition_fence_open = "```" ^ composition_fence_info

let composition_blocks body =
  Keeper_skill_body_ast.parse body
  |> Keeper_skill_body_ast.fenced_code_blocks
  |> List.filter
       (fun (block : Keeper_skill_body_ast.fenced_code_block) ->
          String.equal block.info composition_fence_info)
  |> fun blocks ->
  match
    List.find_opt
      (fun (block : Keeper_skill_body_ast.fenced_code_block) ->
         not block.terminated)
      blocks
  with
  | Some _ -> Error `Unterminated
  | None -> Ok blocks
;;

(* The fence info string is an exact contract, so an info string that only
   normalizes to it — case, tabs, doubled spaces — currently yields a silent
   instruction skill and no composition tool. Surface that near-miss as an
   advisory diagnostic without touching the projection. Normalization is a
   closed rewrite (ASCII lowercase + whitespace collapse), not a fuzzy
   classifier: a genuinely different info string stays an ordinary code block
   with no diagnostic. *)
let composition_info_near_misses body =
  Keeper_skill_body_ast.parse body
  |> Keeper_skill_body_ast.fenced_code_blocks
  |> List.filter_map (fun (block : Keeper_skill_body_ast.fenced_code_block) ->
       if String.equal block.info composition_fence_info
       then None
       else (
         let normalized =
           String.lowercase_ascii block.info
           |> String.map (function
                | '\t' -> ' '
                | ch -> ch)
           |> String.split_on_char ' '
           |> List.filter (fun segment -> not (String.equal segment ""))
           |> String.concat " "
         in
         if String.equal normalized composition_fence_info
         then Some block.info
         else None))
;;

let composition_of_block ~skill block =
  match Catalog.parse block.Keeper_skill_body_ast.body with
  | Error error -> Error (Composition_rejected { skill; error })
  | Ok catalog ->
    (match Catalog.entries catalog with
     | [ entry ] ->
       if String.equal entry.Catalog.name skill
       then Ok entry
       else
         Error (Composition_name_mismatch { skill; declared = entry.Catalog.name })
     | entries ->
       Error (Not_exactly_one_composition { skill; count = List.length entries }))
;;

let reject_invocation_policy ~skill
      (extensions : (string * Agent_core.Skill_document.extension_value) list) =
  match
    List.find_opt
      (fun (field, _) ->
         String.equal field "disable-model-invocation"
         || String.equal field "masc-composition-tool")
      extensions
  with
  | None -> Ok ()
  | Some (field, _) -> Error (Removed_invocation_policy { skill; field })
;;

let parse_document ~conformance (document : Agent_core.Skill_document.t) =
  let { Agent_core.Skill_document.name
      ; description
      ; body
      ; extensions
      ; _
      }
    = document
  in
  match reject_invocation_policy ~skill:name extensions with
  | Error _ as error -> error
  | Ok () ->
    (match composition_blocks body with
     | Error `Unterminated ->
       Error (Unterminated_composition_block { skill = name })
     | Ok [] ->
       Ok
         { name
         ; description
         ; body
         ; conformance
         ; reference = None
         ; provenance = None
         ; composition_span = None
         ; surface = Instruction
         }
     | Ok [ block ] ->
       (match composition_of_block ~skill:name block with
        | Error _ as error -> error
        | Ok entry ->
          Ok
            { name
            ; description
            ; body
            ; conformance
            ; reference = None
            ; provenance = None
            ; composition_span = Some block.span
            ; surface = Composition entry
            })
     | Ok blocks ->
       Error
         (Multiple_composition_blocks
            { skill = name; count = List.length blocks }))
;;

let parse_skill ~directory content =
  match Agent_core.Skill_document.decode ~directory_name:directory content with
  | Unloadable diagnostics -> Error (Definition_rejected { directory; diagnostics })
  | Loaded { document; conformance } -> parse_document ~conformance document
;;

let empty = []

let partition_documents documents =
  let rec build parsed rejected = function
    | [] ->
      ( List.sort
          (fun left right -> String.compare left.name right.name)
          (List.rev parsed)
      , List.rev rejected )
    | (directory, content) :: rest ->
      (match parse_skill ~directory content with
       | Error error -> build parsed ({ directory; error } :: rejected) rest
       | Ok skill ->
         if List.exists (fun known -> String.equal known.name skill.name) parsed
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

let fallback_instruction_of_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  let document = entry.document in
  { name = document.name
  ; description = document.description
  ; body = document.body
  ; conformance = entry.conformance
  ; reference = Some (Skill_catalog_snapshot.entry_reference entry)
  ; provenance = provenance_of_entry snapshot entry
  ; composition_span = None
  ; surface = Instruction
  }
;;

let composition_projection_failed = function
  | Unterminated_composition_block _
  | Multiple_composition_blocks _
  | Composition_rejected _
  | Not_exactly_one_composition _
  | Composition_name_mismatch _ ->
    true
  | Definition_rejected _
  | Composition_info_near_miss _
  | Removed_invocation_policy _
  | Duplicate_skill _ ->
    false
;;

let project_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  parse_document ~conformance:entry.conformance entry.document
  |> Result.map (fun skill ->
    { skill with
      reference = Some (Skill_catalog_snapshot.entry_reference entry)
    ; provenance = provenance_of_entry snapshot entry
    })
;;

let project_entry_or_fallback snapshot (entry : Skill_catalog_snapshot.entry) =
  match project_entry snapshot entry with
  | Ok skill -> Projected skill
  | Error diagnostic when composition_projection_failed diagnostic ->
    Frozen_instruction
      { skill = fallback_instruction_of_entry snapshot entry; diagnostic }
  | Error error -> Entry_unavailable error
;;

let project_entries snapshot entries =
  entries
  |> List.fold_left
       (fun (catalog, diagnostics) (entry : Skill_catalog_snapshot.entry) ->
          match project_entry_or_fallback snapshot entry with
          | Projected skill ->
            let diagnostics =
              match skill.surface with
              | Composition _ -> diagnostics
              | Instruction ->
                (* Advisory only: the entry stays a projected instruction
                   skill; the diagnostic tells the author why no composition
                   tool appeared. *)
                List.fold_left
                  (fun diagnostics info ->
                     { identity = entry.identity
                     ; error =
                         Composition_info_near_miss { skill = skill.name; info }
                     }
                     :: diagnostics)
                  diagnostics
                  (composition_info_near_misses skill.body)
            in
            skill :: catalog, diagnostics
          | Frozen_instruction { skill; diagnostic } ->
            skill :: catalog, { identity = entry.identity; error = diagnostic } :: diagnostics
          | Entry_unavailable error ->
            catalog, { identity = entry.identity; error } :: diagnostics)
       ([], [])
  |> fun (catalog, diagnostics) -> List.rev catalog, List.rev diagnostics
;;

let of_snapshot snapshot =
  project_entries snapshot (Skill_catalog_snapshot.effective_entries snapshot)
;;

let all_entries_of_snapshot snapshot =
  project_entries snapshot (Skill_catalog_snapshot.entries snapshot)
;;

let same_exact_reference (left : skill) (right : skill) =
  match left.reference, right.reference with
  | Some left, Some right -> Skill_reference.equal left right
  | Some _, None | None, Some _ | None, None -> false
;;

let composition_tool_name (skill : skill) =
  match skill.surface with
  | Instruction -> None
  | Composition entry -> Some (Catalog.tool_name entry)
;;

let collision ~tool_name ~(selected : skill) ~(unavailable : skill) =
  match selected.reference, unavailable.reference with
  | Some selected, Some unavailable ->
    Composition_tool_name_collision { tool_name; selected; unavailable }
  | _ ->
    Composition_tool_name_collision_unattributed
      { tool_name
      ; selected_name = selected.name
      ; unavailable_name = unavailable.name
      }
;;

let project_turn ~global ~task =
  let add (selected, unavailable) (skill : skill) =
    if List.exists (same_exact_reference skill) selected
    then selected, unavailable
    else
      match composition_tool_name skill with
      | None -> selected @ [ skill ], unavailable
      | Some tool_name ->
        (match
           List.find_opt
             (fun known ->
                match composition_tool_name known with
                | Some known_name -> String.equal tool_name known_name
                | None -> false)
             selected
         with
         | None -> selected @ [ skill ], unavailable
         | Some winner ->
           selected, collision ~tool_name ~selected:winner ~unavailable:skill :: unavailable)
  in
  List.fold_left add ([], []) (task @ skills global)
  |> fun (catalog, unavailable) -> { catalog; unavailable = List.rev unavailable }
;;

let turn_unavailable_to_string = function
  | Composition_tool_name_collision { tool_name; selected; unavailable } ->
    Printf.sprintf
      "composition tool %S is already provided by exact Skill %s; exact Skill %s is unavailable"
      tool_name
      (Skill_reference.to_yojson selected |> Yojson.Safe.to_string)
      (Skill_reference.to_yojson unavailable |> Yojson.Safe.to_string)
  | Composition_tool_name_collision_unattributed
      { tool_name; selected_name; unavailable_name } ->
    Printf.sprintf
      "composition tool %S is already provided by Skill %S; Skill %S has no exact snapshot reference and is unavailable"
      tool_name
      selected_name
      unavailable_name
;;

let exact_skill catalog reference =
  List.find_opt
    (fun (skill : skill) ->
       match skill.reference with
       | Some known -> Skill_reference.equal known reference
       | None -> false)
    (skills catalog)
;;

let collision_for_reference unavailable reference =
  List.find_opt
    (function
      | Composition_tool_name_collision { unavailable; _ } ->
        Skill_reference.equal unavailable reference
      | Composition_tool_name_collision_unattributed _ -> false)
    unavailable
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
           | Some { surface = Composition entry; _ } ->
             Composition_tool { tool_name = Catalog.tool_name entry }
           | None ->
             let diagnostic =
               match collision_for_reference projection.unavailable reference with
               | Some collision -> turn_unavailable_to_string collision
               | None ->
                 Printf.sprintf
                   "exact Task Skill is unavailable in the executable turn projection: %s"
                   (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
             in
             Exact_unavailable { diagnostic }
         in
         Some { reference; availability })
    task
;;

let exact_surface_to_yojson surface =
  let kind, tool_name, diagnostic =
    match surface.availability with
    | Instruction_tool ->
      "instruction", Some Catalog.skill_tool_name, None
    | Composition_tool { tool_name } ->
      "composition", Some tool_name, None
    | Exact_unavailable { diagnostic } ->
      "unavailable", None, Some diagnostic
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
  List.filter_map
    (fun skill ->
       match skill.surface with
       | Instruction -> Some (skill.name, skill.description, skill.body)
       | Composition _ -> None)
    catalog
;;

let instruction_names_for catalog names =
  let rec resolve instruction_names = function
    | [] -> Ok (List.rev instruction_names)
    | name :: rest ->
      (match find catalog name with
       | None -> Error (Missing_named_skill { name })
       | Some skill ->
         (match skill.surface with
          | Instruction -> resolve (name :: instruction_names) rest
          | Composition _ -> resolve instruction_names rest))
  in
  resolve [] names
;;

let compositions catalog =
  List.filter_map
    (fun skill ->
       match skill.surface with
       | Instruction -> None
       | Composition entry ->
         Some
           { entry
           ; provenance = skill.provenance
           ; span = skill.composition_span
           })
    catalog
;;

let composition_entries catalog =
  List.map (fun composition -> composition.entry) (compositions catalog)
;;

let surface_to_string = function
  | Instruction -> "instruction"
  | Composition _ -> "composition"
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
  | Unterminated_composition_block _ -> "unterminated_composition_block"
  | Multiple_composition_blocks _ -> "multiple_composition_blocks"
  | Composition_rejected _ -> "composition_rejected"
  | Not_exactly_one_composition _ -> "not_exactly_one_composition"
  | Composition_name_mismatch _ -> "composition_name_mismatch"
  | Composition_info_near_miss _ -> "composition_info_near_miss"
  | Removed_invocation_policy _ -> "removed_invocation_policy"
  | Duplicate_skill _ -> "duplicate_skill"
;;

let error_to_string = function
  | Definition_rejected { directory; diagnostics } ->
    Printf.sprintf
      "skill directory %S: %s"
      directory
      (String.concat
         "; "
         (List.map Agent_core.Skill_document.diagnostic_to_string diagnostics))
  | Unterminated_composition_block { skill } ->
    Printf.sprintf
      "skill %S: a %s block is never closed"
      skill
      composition_fence_open
  | Multiple_composition_blocks { skill; count } ->
    Printf.sprintf
      "skill %S: %d %s blocks; a composition skill declares exactly one"
      skill
      count
      composition_fence_open
  | Composition_rejected { skill; error } ->
    Printf.sprintf
      "skill %S: composition block rejected: %s"
      skill
      (Catalog.error_to_string error)
  | Not_exactly_one_composition { skill; count } ->
    Printf.sprintf
      "skill %S: composition block declares %d compositions; exactly one is required"
      skill
      count
  | Composition_name_mismatch { skill; declared } ->
    Printf.sprintf
      "skill %S: composition name %S must equal the skill name"
      skill
      declared
  | Composition_info_near_miss { skill; info } ->
    Printf.sprintf
      "skill %S: fence info %S reads like %S but does not match it exactly, so \
       the block stayed an ordinary code block and the skill an instruction; \
       write the info string exactly as %S to declare a composition"
      skill
      info
      composition_fence_info
      composition_fence_info
  | Removed_invocation_policy { skill; field } ->
    Printf.sprintf
      "skill %S: %s is unsupported; the composition fence alone determines the surface"
      skill
      field
  | Duplicate_skill { name } -> "duplicate skill name: " ^ name
;;
