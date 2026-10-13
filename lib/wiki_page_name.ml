(** Wiki page names: the one judgment readers and writers share. Pure: it
    reads nothing and writes nothing, so the lint and the tool agree by
    construction (RFC-wiki-lint-and-page-contracts §4.4, step 1a). Moved out
    of [Tool_wiki] without changing a line of its behaviour. *)

open Printf

(* Page names. The writer chooses the name. Nothing is derived from the title
   or the date, and a name that breaks the rule is refused rather than
   repaired: dropping characters silently is how two different titles ended
   up in one file. *)
type page_name_error =
  | Empty_page_name
  | Bad_page_characters
  | Dash_at_edge
  | Reserved_page_name

(* [index] and [log] are the wiki's own files. This is the one place their
   names are spelled; [Wiki_journal] derives the file names from here. *)
let index_name = "index"
let log_name = "log"
let reserved_page_names = [ index_name; log_name ]

let validate_page_name raw =
  let allowed c =
    match c with
    | 'a' .. 'z' | '0' .. '9' | '-' -> true
    | _ -> false
  in
  if String.equal raw ""
  then Error Empty_page_name
  else if not (Stdlib.String.for_all allowed raw)
  then Error Bad_page_characters
  else if Char.equal raw.[0] '-' || Char.equal raw.[String.length raw - 1] '-'
  then Error Dash_at_edge
  else if List.exists (String.equal raw) reserved_page_names
  then Error Reserved_page_name
  else Ok raw

(* The name is quoted as written: [%S] would escape a non-ASCII name into
   decimal byte codes the writer cannot recognise. *)
let page_name_error_to_string raw = function
  | Empty_page_name -> "page is required"
  | Bad_page_characters ->
    sprintf
      "page name \"%s\" may only contain lowercase a-z, digits and '-'. Put other \
       scripts in the title."
      raw
  | Dash_at_edge -> sprintf "page name \"%s\" may not start or end with '-'" raw
  | Reserved_page_name -> sprintf "page name \"%s\" is reserved by the wiki" raw
