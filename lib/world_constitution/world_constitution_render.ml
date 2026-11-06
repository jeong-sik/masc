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

type amendments =
  { added : World_constitution_types.t list
  ; removed : World_constitution_types.Article_id.t list
  }

let holds articles id =
  List.exists
    (fun (article : World_constitution_types.t) ->
       World_constitution_types.Article_id.equal article.id id)
    articles

(* Articles are never edited in place: a changed norm is a removal and a new
   id, so comparing ids finds every change. *)
let amendments ~built_with current =
  let added =
    List.filter
      (fun (article : World_constitution_types.t) -> not (holds built_with article.id))
      current
  in
  let removed =
    List.filter_map
      (fun (article : World_constitution_types.t) ->
         if holds current article.id then None else Some article.id)
      built_with
  in
  match added, removed with
  | [], [] -> None
  | _ :: _, _ | [], _ :: _ -> Some { added; removed }

let added_lines { added; removed = _ } = articles added

let removed_lines { added = _; removed } =
  String.concat "\n"
    (List.map
       (fun id -> Printf.sprintf "- [%s]" (World_constitution_types.Article_id.to_string id))
       removed)
