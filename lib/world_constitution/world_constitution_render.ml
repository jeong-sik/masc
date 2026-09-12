(* The text is written by a model, not by an operator, and it lands between
   [</system>] and [<identity>] in the assembled prompt. The sibling
   interpolated blocks (identity, workspace) escape for the same reason; this
   one carries the less trusted bytes of the three. *)
let article_line (article : World_constitution_types.t) =
  Printf.sprintf "- [%s] %s"
    (World_constitution_types.Article_id.to_string article.id)
    (String_util.escape_xml (String.trim article.text))

let articles = function
  | [] -> ""
  | list -> String.concat "\n" (List.map article_line list)
