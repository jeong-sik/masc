module Catalog = Keeper_tool_composition_catalog

type surface =
  | Instruction
  | Composition of Catalog.entry

type skill =
  { name : string
  ; description : string
  ; body : string
  ; conformance : Agent_core.Skill_document.conformance
  ; surface : surface
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
  | Removed_allowed_tools of { skill : string }
  | Removed_disable_model_invocation of { skill : string }
  | Invalid_masc_composition_tool of
      { skill : string
      ; actual : string
      }
  | Duplicate_skill of { name : string }

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
   matched that example, promoted a documentation skill to a composition (or
   failed it on the name), and — because [of_documents] fails the whole catalog
   on the first bad file — took every keeper turn down with it. *)
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

let extension_value_kind : Agent_core.Skill_document.extension_value -> string = function
  | Null -> "null"
  | Boolean _ -> "boolean"
  | Number _ -> "number"
  | Text _ -> "string"
  | Sequence _ -> "sequence"
  | Mapping _ -> "mapping"
;;

let materialize_composition_tool ~skill extensions =
  match List.assoc_opt "disable-model-invocation" extensions with
  | Some _ -> Error (Removed_disable_model_invocation { skill })
  | None ->
    (match List.assoc_opt "masc-composition-tool" extensions with
     | None | Some (Boolean true) -> Ok true
     | Some (Boolean false) -> Ok false
     | Some value ->
       Error
         (Invalid_masc_composition_tool
            { skill; actual = extension_value_kind value }))
;;

let parse_skill ~directory content =
  match Agent_core.Skill_document.decode ~directory_name:directory content with
  | Unloadable diagnostics -> Error (Definition_rejected { directory; diagnostics })
  | Loaded { document; conformance } ->
    let { Agent_core.Skill_document.name
        ; description
        ; body
        ; allowed_tools
        ; extensions
        ; _
        }
      = document
    in
    (match allowed_tools with
     | Some _ -> Error (Removed_allowed_tools { skill = name })
     | None ->
       (match materialize_composition_tool ~skill:name extensions with
     | Error _ as error -> error
     | Ok materialize_tool ->
       (match composition_blocks body with
     | Error `Unterminated -> Error (Unterminated_composition_block { skill = name })
     | Ok [] -> Ok { name; description; body; conformance; surface = Instruction }
     | Ok [ block ] ->
       (match composition_of_block ~skill:name block with
        | Error _ as error -> error
        | Ok entry ->
          (* [masc-composition-tool: false] suppresses only the dedicated
             composition tool. The body remains task-readable through
             [keeper_skill]; the key names that exact MASC behavior instead
             of borrowing another client's broader invocation policy. *)
          let surface =
            if materialize_tool then Composition entry else Instruction
          in
          Ok { name; description; body; conformance; surface })
     | Ok blocks ->
       Error (Multiple_composition_blocks { skill = name; count = List.length blocks }))))
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

let composition_entries catalog =
  List.filter_map
    (fun skill ->
       match skill.surface with
       | Instruction -> None
       | Composition entry -> Some entry)
    catalog
;;

let surface_to_string = function
  | Instruction -> "instruction"
  | Composition _ -> "composition"
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
  | Removed_allowed_tools { skill } ->
    Printf.sprintf
      "skill %S: allowed-tools is unsupported; MASC approval policy is authoritative"
      skill
  | Removed_disable_model_invocation { skill } ->
    Printf.sprintf
      "skill %S: disable-model-invocation is not a MASC composition policy; use masc-composition-tool: false"
      skill
  | Invalid_masc_composition_tool { skill; actual } ->
    Printf.sprintf
      "skill %S: masc-composition-tool must be boolean, got %s"
      skill
      actual
  | Duplicate_skill { name } -> "duplicate skill name: " ^ name
;;
