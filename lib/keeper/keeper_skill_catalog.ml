module Catalog = Keeper_tool_composition_catalog

type surface =
  | Instruction
  | Composition of Catalog.entry

type provenance =
  { identity : Skill_catalog_snapshot.identity
  ; source : Skill_source_config.source
  ; directory : string
  }

type skill =
  { name : string
  ; description : string
  ; body : string
  ; model_invocable : bool
  ; reference : Skill_reference.t option
  ; provenance : provenance option
  ; surface : surface
  }

type composition =
  { entry : Catalog.entry
  ; provenance : provenance option
  }

type t = skill list

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
  | Duplicate_skill of { name : string }

type projection_diagnostic =
  { identity : Skill_catalog_snapshot.identity
  ; error : error
  }

let composition_fence_open = "```toml composition"
let fence_close = "```"

(* A fence line is compared after trimming so CRLF bodies and trailing
   spaces read the same as a bare fence, matching [Frontmatter]'s delimiter
   rule. Inside an open block the first close fence ends it; an instruction
   skill that wants to *show* a composition block as documentation escapes
   it the CommonMark way, with a longer outer fence. *)
let composition_blocks body =
  let rec scan closed current = function
    | [] ->
      (match current with
       | None -> Ok (List.rev closed)
       | Some _ -> Error `Unterminated)
    | line :: rest ->
      let trimmed = String.trim line in
      (match current with
       | None ->
         if String.equal trimmed composition_fence_open
         then scan closed (Some []) rest
         else scan closed None rest
       | Some block ->
         if String.equal trimmed fence_close
         then scan (String.concat "\n" (List.rev block) :: closed) None rest
         else scan closed (Some (line :: block)) rest)
  in
  scan [] None (String.split_on_char '\n' body)
;;

let composition_of_block ~skill block =
  match Catalog.parse block with
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

let parse_document (document : Agent_core.Skill_document.t) =
  let { Agent_core.Skill_document.name; description; body; extensions; _ } = document in
    let model_invocable =
      match List.assoc_opt "disable-model-invocation" extensions with
      | Some (Boolean true) -> false
      | Some _ | None -> true
    in
    (match composition_blocks body with
     | Error `Unterminated -> Error (Unterminated_composition_block { skill = name })
     | Ok [] ->
       Ok
         { name
         ; description
         ; body
         ; model_invocable
         ; reference = None
         ; provenance = None
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
            ; model_invocable
            ; reference = None
            ; provenance = None
            ; surface = Composition entry
            })
     | Ok blocks ->
       Error (Multiple_composition_blocks { skill = name; count = List.length blocks }))
;;

let parse_skill ~directory content =
  match Agent_core.Skill_document.decode ~directory_name:directory content with
  | Unloadable diagnostics -> Error (Definition_rejected { directory; diagnostics })
  | Loaded { document; _ } -> parse_document document
;;

let empty = []

let of_documents documents =
  let rec build parsed = function
    | [] ->
      Ok
        (List.sort
           (fun left right -> String.compare left.name right.name)
           (List.rev parsed))
    | (directory, content) :: rest ->
      (match parse_skill ~directory content with
       | Error _ as error -> error
       | Ok skill ->
         if List.exists (fun known -> String.equal known.name skill.name) parsed
         then Error (Duplicate_skill { name = skill.name })
         else build (skill :: parsed) rest)
  in
  build [] documents
;;

let skills catalog = catalog

let provenance_of_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  Skill_catalog_snapshot.sources snapshot
  |> fun sources -> List.nth_opt sources entry.source_index
  |> Option.map (fun scan ->
    { identity = entry.identity
    ; source = scan.Skill_catalog_snapshot.source.source
    ; directory = entry.directory
    })
;;

let project_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  parse_document entry.document
  |> Result.map (fun skill ->
    { skill with
      reference = Some (Skill_catalog_snapshot.entry_reference entry)
    ; provenance = provenance_of_entry snapshot entry
    })
;;

let of_snapshot snapshot =
  Skill_catalog_snapshot.effective_entries snapshot
  |> List.fold_left
       (fun (catalog, diagnostics) entry ->
          match project_entry snapshot entry with
          | Ok skill ->
            skill :: catalog, diagnostics
          | Error error ->
            catalog, { identity = entry.identity; error } :: diagnostics)
       ([], [])
  |> fun (catalog, diagnostics) -> List.rev catalog, List.rev diagnostics
;;

let find catalog name =
  List.find_opt (fun skill -> String.equal skill.name name) catalog
;;

let compositions catalog =
  List.filter_map
    (fun skill ->
       match skill.model_invocable, skill.surface with
       | false, _ -> None
       | true, Instruction -> None
       | true, Composition entry -> Some { entry; provenance = skill.provenance })
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
  | Duplicate_skill { name } -> "duplicate skill name: " ^ name
;;
