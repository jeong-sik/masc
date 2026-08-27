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

let composition_fence_open = "```toml composition"

let composition_blocks body =
  Keeper_skill_body_ast.parse body
  |> Keeper_skill_body_ast.fenced_code_blocks
  |> List.filter
       (fun (block : Keeper_skill_body_ast.fenced_code_block) ->
          String.equal block.info "toml composition")
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
         || String.equal field "masc-composition-tool"
         || String.equal field "allowed-tools")
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

let of_snapshot snapshot =
  Skill_catalog_snapshot.effective_entries snapshot
  |> List.fold_left
       (fun (catalog, diagnostics) (entry : Skill_catalog_snapshot.entry) ->
          match project_entry snapshot entry with
          | Ok skill ->
            skill :: catalog, diagnostics
          | Error error when composition_projection_failed error ->
            ( fallback_instruction_of_entry snapshot entry :: catalog
            , { identity = entry.identity; error } :: diagnostics )
          | Error error ->
            catalog, { identity = entry.identity; error } :: diagnostics)
       ([], [])
  |> fun (catalog, diagnostics) -> List.rev catalog, List.rev diagnostics
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
  | Removed_invocation_policy { skill; field } ->
    Printf.sprintf
      "skill %S: %s is unsupported; the composition fence alone determines the surface"
      skill
      field
  | Duplicate_skill { name } -> "duplicate skill name: " ^ name
;;
