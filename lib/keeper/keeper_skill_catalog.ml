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
  ; conformance : Agent_core.Skill_document.conformance
  ; provenance : provenance option
  ; surface : surface
  }

type composition =
  { entry : Catalog.entry
  ; provenance : provenance option
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
let fence_close = "```"

(* The run of fence characters a line opens or closes with, if any: three or
   more backticks or tildes, counted the CommonMark way — the two characters
   do not close each other, and a longer run encloses a shorter one. *)
let fence_run line =
  let length = String.length line in
  if length = 0
  then None
  else (
    let fence_char = line.[0] in
    if not (Char.equal fence_char '`' || Char.equal fence_char '~')
    then None
    else (
      let index = ref 0 in
      while !index < length && Char.equal line.[!index] fence_char do
        incr index
      done;
      if !index < 3
      then None
      else Some (fence_char, !index, String.sub line !index (length - !index))))
;;

let closes_fence ~fence_char ~length trimmed =
  match fence_run trimmed with
  | Some (other_char, other_length, info) ->
    Char.equal other_char fence_char
    && other_length >= length
    && String.equal (String.trim info) ""
  | None -> false
;;

(* Where the scan is when it reads the next line. [Enclosing_fence] is the state
   that makes the difference: a skill that *documents* the composition grammar
   wraps the example in a longer outer fence, the CommonMark way, and the inner
   ```toml composition must then be read as text. Without this state the scanner
   matched that example and promoted a documentation skill to a composition
   (or rejected it on the name). *)
type fence_scan =
  | Outside
  | Reading_composition of string list
  | Enclosing_fence of
      { fence_char : char
      ; length : int
      }

(* A fence line is compared after trimming so CRLF bodies and trailing
   spaces read the same as a bare fence, matching [Frontmatter]'s delimiter
   rule. Inside an open composition block the first close fence ends it. *)
let composition_blocks body =
  let rec scan closed state = function
    | [] ->
      (match state with
       | Reading_composition _ -> Error `Unterminated
       (* An unclosed ordinary fence runs to the end of the document, as
          CommonMark says — whatever it swallowed was never a declaration. *)
       | Outside | Enclosing_fence _ -> Ok (List.rev closed))
    | line :: rest ->
      let trimmed = String.trim line in
      (match state with
       | Outside ->
         if String.equal trimmed composition_fence_open
         then scan closed (Reading_composition []) rest
         else (
           match fence_run trimmed with
           | Some (fence_char, length, _info) ->
             scan closed (Enclosing_fence { fence_char; length }) rest
           | None -> scan closed Outside rest)
       | Enclosing_fence { fence_char; length } ->
         if closes_fence ~fence_char ~length trimmed
         then scan closed Outside rest
         else scan closed state rest
       | Reading_composition block ->
         if String.equal trimmed fence_close
         then scan (String.concat "\n" (List.rev block) :: closed) Outside rest
         else scan closed (Reading_composition (line :: block)) rest)
  in
  scan [] Outside (String.split_on_char '\n' body)
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
            ; conformance
            ; provenance = None
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
  Skill_catalog_snapshot.sources snapshot
  |> fun sources -> List.nth_opt sources entry.source_index
  |> Option.map (fun scan ->
    { identity = entry.identity
    ; source = scan.Skill_catalog_snapshot.source.source
    ; directory = entry.directory
    })
;;

let fallback_instruction_of_entry snapshot (entry : Skill_catalog_snapshot.entry) =
  let document = entry.document in
  { name = document.name
  ; description = document.description
  ; body = document.body
  ; conformance = entry.conformance
  ; provenance = provenance_of_entry snapshot entry
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

let of_snapshot snapshot =
  Skill_catalog_snapshot.effective_entries snapshot
  |> List.fold_left
       (fun (catalog, diagnostics) (entry : Skill_catalog_snapshot.entry) ->
          match parse_document ~conformance:entry.conformance entry.document with
          | Ok skill ->
            ( { skill with provenance = provenance_of_entry snapshot entry } :: catalog
            , diagnostics )
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
       | Composition entry -> Some { entry; provenance = skill.provenance })
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
