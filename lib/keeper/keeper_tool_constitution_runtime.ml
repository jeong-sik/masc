open Keeper_meta_contract

(* The articles ride every turn of every keeper in the world. 4 KiB is roughly
   forty one-line norms, which is more than any world has written by hand, and
   it is a tenth of the smallest context this fleet runs. *)
let render_byte_ceiling = 4096

let string_arg args field =
  match args with
  | `Assoc fields -> (
    match List.find_opt (fun (key, _) -> String.equal key field) fields with
    | Some (_, `String value) -> Some value
    | Some _ | None -> None)
  | _ -> None

let load_articles ~base_path =
  match World_constitution_store.load ~base_path with
  | Ok ledger -> Ok ledger.World_constitution_store.articles
  | Error error ->
    Error (World_constitution_store.read_error_to_string error)

let write_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~args =
  let base_path = config.Workspace.base_path in
  match string_arg args "text" with
  | None ->
    Keeper_tool_execution.failure
      "text is required and must be a string: the sentence the world agreed on"
  | Some text -> (
    let evidence =
      match string_arg args "evidence_uri" with
      | None -> []
      | Some uri -> [ { World_constitution_types.uri; sha256 = None } ]
    in
    match
      World_constitution_types.make
        ~id:(World_constitution_types.Article_id.generate ())
        ~text ~author:meta.name ~at:(Unix.gettimeofday ()) ~evidence
    with
    | Error invalid ->
      Keeper_tool_execution.failure
        (World_constitution_types.invalid_to_string invalid)
    | Ok article -> (
      match load_articles ~base_path with
      | Error detail -> Keeper_tool_execution.failure detail
      | Ok held ->
        let projected =
          World_constitution_render.articles (held @ [ article ])
        in
        if String.length projected > render_byte_ceiling then
          Keeper_tool_execution.failure
            (Printf.sprintf
               "the world's articles would reach %d bytes, over the %d-byte \
                ceiling: remove one before adding another"
               (String.length projected) render_byte_ceiling)
        else (
          match
            World_constitution_store.append ~base_path
              (World_constitution_types.Added article)
          with
          | Error error ->
            Keeper_tool_execution.failure
              (World_constitution_store.append_error_to_string error)
          | Ok () ->
            Keeper_tool_execution.success_data
              (`Assoc
                [ ( "article_id"
                  , `String
                      (World_constitution_types.Article_id.to_string article.id)
                  )
                ; "articles_held", `Int (List.length held + 1)
                ; "rendered_bytes", `Int (String.length projected)
                ]))))

let remove_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~args =
  let base_path = config.Workspace.base_path in
  match string_arg args "article_id" with
  | None ->
    Keeper_tool_execution.failure
      "article_id is required and must be a string"
  | Some raw -> (
    match World_constitution_types.Article_id.of_string raw with
    | Error detail -> Keeper_tool_execution.failure detail
    | Ok id -> (
      match load_articles ~base_path with
      | Error detail -> Keeper_tool_execution.failure detail
      | Ok held ->
        let is_held =
          List.exists
            (fun (article : World_constitution_types.t) ->
              World_constitution_types.Article_id.equal article.id id)
            held
        in
        if not is_held then
          Keeper_tool_execution.failure
            (Printf.sprintf
               "no article %s is held by this world; nothing was removed" raw)
        else (
          match
            World_constitution_store.append ~base_path
              (World_constitution_types.Removed
                 { id; by = meta.name; at = Unix.gettimeofday () })
          with
          | Error error ->
            Keeper_tool_execution.failure
              (World_constitution_store.append_error_to_string error)
          | Ok () ->
            Keeper_tool_execution.success_data
              (`Assoc
                [ "article_id", `String raw
                ; "articles_held", `Int (List.length held - 1)
                ]))))
