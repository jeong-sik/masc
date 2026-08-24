(* One SKILL.md, read the way the Agent Skills standard says to read it:
   name and description are required, everything else in the frontmatter
   belongs to whoever wrote it and is not masc's business.

   See skill_definition.mli for why this loader is permissive where
   Tool_definition_toml is fail-closed. *)

type t =
  { name : string
  ; description : string
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

let load ~directory_name ~contents =
  let parsed = Frontmatter.parse contents in
  let name = Frontmatter.field parsed "name" in
  let description = Frontmatter.field parsed "description" in
  if String.equal name ""
  then Error Missing_name
  else if String.equal description ""
  then Error Missing_description
  else if not (String.equal name directory_name)
  then Error (Name_mismatch { declared = name; directory = directory_name })
  else Ok { name; description; body = parsed.Frontmatter.body }
;;
