let article_line (article : World_constitution_types.t) =
  Printf.sprintf "- [%s] %s"
    (World_constitution_types.Article_id.to_string article.id)
    (String.trim article.text)

let articles = function
  | [] -> ""
  | list -> String.concat "\n" (List.map article_line list)
