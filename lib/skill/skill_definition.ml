(* One SKILL.md, read the way the Agent Skills standard says to read it:
   name and description are required, everything else in the frontmatter
   belongs to whoever wrote it and is not masc's business.

   See skill_definition.mli for why this loader is permissive where
   Tool_definition_toml is fail-closed. *)

type t =
  { name : string
  ; description : string
  ; model_invocable : bool
  ; body : string
  }

type load_error =
  | Missing_name
  | Missing_description
  | Name_mismatch of
      { declared : string
      ; directory : string
      }

let load_error_to_string = function
  | Missing_name -> "SKILL.md has no name in its frontmatter"
  | Missing_description -> "SKILL.md has no description in its frontmatter"
  | Name_mismatch { declared; directory } ->
    Printf.sprintf
      "SKILL.md declares name %S but sits in directory %S; a task can only \
       reference the directory name"
      declared
      directory
;;

(* [name] is optional in the standard and defaults to the directory name, so a
   file that omits it is valid and must load. Requiring it rejected skills
   written for another runtime that relied on the default — the very
   cross-runtime case this loader exists to honour. A declared name still has
   to agree with the directory, because a task references the directory. *)
let load ~directory_name ~contents =
  let parsed = Frontmatter.parse contents in
  let declared_name = Frontmatter.field parsed "name" in
  let description = Frontmatter.field parsed "description" in
  let name = if String.equal declared_name "" then directory_name else declared_name in
  if String.equal name ""
  then Error Missing_name
  else if String.equal description ""
  then Error Missing_description
  else if not (String.equal name directory_name)
  then Error (Name_mismatch { declared = name; directory = directory_name })
  else
    Ok
      { name
      ; description
      ; model_invocable =
          not
            (String.equal
               (String.lowercase_ascii
                  (String.trim (Frontmatter.field parsed "disable-model-invocation")))
               "true")
      ; body = parsed.Frontmatter.body
      }
;;
