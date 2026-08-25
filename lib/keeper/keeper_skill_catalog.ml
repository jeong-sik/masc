module Catalog = Keeper_tool_composition_catalog

type surface =
  | Instruction
  | Composition of Catalog.entry

type skill =
  { name : string
  ; description : string
  ; body : string
  ; surface : surface
  }

type t = skill list

type error =
  | Definition_rejected of
      { directory : string
      ; error : Skill_definition.load_error
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

let parse_skill ~directory content =
  match Skill_definition.load ~directory_name:directory ~contents:content with
  | Error error -> Error (Definition_rejected { directory; error })
  | Ok { Skill_definition.name; description; body; model_invocable } ->
    (match composition_blocks body with
     | Error `Unterminated -> Error (Unterminated_composition_block { skill = name })
     | Ok [] -> Ok { name; description; body; surface = Instruction }
     | Ok [ block ] ->
       (match composition_of_block ~skill:name block with
        | Error _ as error -> error
        | Ok entry ->
          (* [disable-model-invocation: true] says the author does not want a
             model reaching for this by itself. The composition still parses
             and the skill still loads — it just does not become a tool the
             model can see. *)
          let surface = if model_invocable then Composition entry else Instruction in
          Ok { name; description; body; surface })
     | Ok blocks ->
       Error (Multiple_composition_blocks { skill = name; count = List.length blocks }))
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
  | Definition_rejected { directory; error } ->
    Printf.sprintf
      "skill directory %S: %s"
      directory
      (Skill_definition.load_error_to_string error)
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
