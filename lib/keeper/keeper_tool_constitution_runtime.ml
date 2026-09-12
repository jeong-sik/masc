open Keeper_meta_contract

(* The articles ride every turn of every keeper in the world. 4 KiB is roughly
   forty one-line norms, which is more than any world has written by hand, and
   it is a tenth of the smallest context this fleet runs. *)
let render_byte_ceiling = 4096

(* One norm is one sentence. Without a per-article cap a single write can be
   larger than the whole ceiling, and the ceiling message would then tell a
   keeper to remove something from an empty world. *)
let article_byte_cap = 512

let string_arg args field =
  match args with
  | `Assoc fields -> (
    match List.find_opt (fun (key, _) -> String.equal key field) fields with
    | Some (_, `String value) -> Some value
    | Some _ | None -> None)
  | _ -> None

let load_ledger ~base_path =
  match World_constitution_store.load ~base_path with
  | Ok ledger -> Ok ledger
  | Error error ->
    Error (World_constitution_store.read_error_to_string error)

(* Lines the ledger could not decode are the store's to report and this tool's
   to pass on. A keeper calling these tools is the one reader in a position to
   act, and saying nothing here is what would make the store's own contract a
   lie. Omitted when there are none, so the ordinary answer stays quiet. *)
(* Every other keeper tool answers inside an [ok] envelope, and the dispatch
   suite checks for it: a result without it reads as a failure to the same
   caller that reads the rest. *)
let ok_envelope fields = `Assoc (("ok", `Bool true) :: fields)

let with_unreadable (ledger : World_constitution_store.ledger) fields =
  match ledger.World_constitution_store.rejected with
  | [] -> fields
  | rejected ->
    fields
    @ [ ( "unreadable_ledger_lines"
        , `List
            (List.map
               (fun (line : World_constitution_store.rejected_line) ->
                 `Assoc
                   [ "line", `Int line.World_constitution_store.line_number
                   ; "detail", `String line.World_constitution_store.detail
                   ])
               rejected) )
      ]

let write_with_outcome ~(config : Workspace.config) ~(meta : keeper_meta) ~args =
  let base_path = config.Workspace.base_path in
  match string_arg args "text" with
  | None ->
    Keeper_tool_execution.failure
      "text is required and must be a string: the sentence the world agreed on"
  | Some text when String.length text > article_byte_cap ->
    Keeper_tool_execution.failure
      (Printf.sprintf
         "this norm is %d bytes, over the %d-byte limit for one article: say it \
          in one sentence"
         (String.length text) article_byte_cap)
  | Some text -> (
    let evidence =
      match string_arg args "evidence_uri" with
      | None -> []
      | Some uri -> [ { World_constitution_types.uri; sha256 = None } ]
    in
    match
      World_constitution_types.make
        ~id:(World_constitution_types.Article_id.generate ())
        ~text ~author:meta.name ~at:(Time_compat.now ()) ~evidence
    with
    | Error invalid ->
      Keeper_tool_execution.failure
        (World_constitution_types.invalid_to_string invalid)
    | Ok article -> (
      match load_ledger ~base_path with
      | Error detail -> Keeper_tool_execution.failure detail
      | Ok ledger ->
        let held = ledger.World_constitution_store.articles in
        let projected =
          World_constitution_render.articles (held @ [ article ])
        in
        if String.length projected > render_byte_ceiling then
          Keeper_tool_execution.failure
            (Printf.sprintf
               "the world's articles would reach %d bytes, over the %d-byte \
                ceiling; it holds %d: remove one with \
                keeper_constitution_remove before adding another"
               (String.length projected) render_byte_ceiling
               (List.length held))
        else (
          match
            World_constitution_store.append_at ~base_path
              ~expected_end_offset:ledger.World_constitution_store.end_offset
              (World_constitution_types.Added article)
          with
          | Error error ->
            Keeper_tool_execution.failure
              (World_constitution_store.append_error_to_string error)
          | Ok () ->
            Keeper_tool_execution.success_data
              (ok_envelope
                 (with_unreadable ledger
                    [ ( "article_id"
                      , `String
                          (World_constitution_types.Article_id.to_string
                             article.id) )
                    ; "articles_held", `Int (List.length held + 1)
                    ; "rendered_bytes", `Int (String.length projected)
                    ])))))

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
      match load_ledger ~base_path with
      | Error detail -> Keeper_tool_execution.failure detail
      | Ok ledger ->
        let held = ledger.World_constitution_store.articles in
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
            World_constitution_store.append_at ~base_path
              ~expected_end_offset:ledger.World_constitution_store.end_offset
              (World_constitution_types.Removed
                 { id; by = meta.name; at = Time_compat.now () })
          with
          | Error error ->
            Keeper_tool_execution.failure
              (World_constitution_store.append_error_to_string error)
          | Ok () ->
            Keeper_tool_execution.success_data
              (ok_envelope
                 (with_unreadable ledger
                    [ "article_id", `String raw
                    ; "articles_held", `Int (List.length held - 1)
                    ])))))
