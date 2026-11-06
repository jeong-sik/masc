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

(* [article_line] renders an article's id and text and nothing else, so two
   articles read the same in a prompt exactly when both are equal. *)
let renders_as (left : World_constitution_types.t) (right : World_constitution_types.t) =
  World_constitution_types.Article_id.equal left.id right.id && String.equal left.text right.text

let holds articles article = List.exists (renders_as article) articles

(* The store re-adds a held id as an edit in place
   ([World_constitution_store.apply]), so an id alone does not tell whether
   the norm changed. An edited article is the old line taken back and the new
   line added. *)
let amendments ~built_with current =
  let added = List.filter (fun article -> not (holds built_with article)) current in
  let removed =
    List.filter_map
      (fun (article : World_constitution_types.t) ->
         if holds current article then None else Some article.id)
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
