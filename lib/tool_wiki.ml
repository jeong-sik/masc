(** Tool_wiki - Wiki operations

    Manages the pages at [<base>/.masc/wiki/<page>.md]
    - The writer names the page; the name is the file name and never changes
    - Every page carries a [source] from [wiki_source]
    - YAML frontmatter records who wrote the page, when, why, a one-line
      summary and the page revision
    - A page is created once and then updated against the revision the
      writer read
*)

open Printf

(* The page contract and the page names live in [Wiki_page] and
   [Wiki_page_name]; this module re-exports them so every caller, and the
   interface below, keeps the names it had. *)
type wiki_source = Wiki_page.wiki_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation

let source_to_string = Wiki_page.source_to_string
let valid_source_strings = Wiki_page.valid_source_strings
let source_of_string_opt = Wiki_page.source_of_string_opt
let string_contains = String_util.string_contains_substring

module Line = Wiki_page.Line
module Tag = Wiki_page.Tag

type frontmatter = Wiki_page.frontmatter = {
  title: Line.t;
  summary: Line.t;
  source: wiki_source;
  author: Line.t;
  created: Line.t;
  revision: int;
  tags: Tag.t list;
}

type frontmatter_error = Wiki_page.frontmatter_error

let parse_frontmatter = Wiki_page.parse_frontmatter
let frontmatter_error_to_string = Wiki_page.frontmatter_error_to_string
let describe_unreadable = Wiki_page.describe_unreadable
let render_page = Wiki_page.render_page
let page_body = Wiki_page.page_body

type page_name_error = Wiki_page_name.page_name_error =
  | Empty_page_name
  | Bad_page_characters
  | Dash_at_edge
  | Reserved_page_name

let validate_page_name = Wiki_page_name.validate_page_name
let page_name_error_to_string = Wiki_page_name.page_name_error_to_string

type context = {
  base_path: string;
  agent_name: string;
}

(* Paths. [base_path] is the workspace the caller already resolved, the same
   one every other tool in the request reads. *)
let wiki_root ~base_path = Config_dir_resolver.wiki_dir ~base_path

(* Every page file in the wiki, in name order. Only the wiki's own two files
   ([index.md], [log.md]) are left out: any other Markdown file that is not a
   wiki page shows up as one whose header does not read. *)
let list_pages ~base_path =
  let dir = wiki_root ~base_path in
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f ->
      Filename.check_suffix f ".md" && not (Wiki_journal.is_own_file f))
    |> List.sort String.compare
    |> List.map (fun f -> Filename.concat dir f)
  else []

(* What the index says about each file: a page gives its title and summary,
   a file whose header does not read gives the reason. A file that vanishes
   between the listing and the read is left out. *)
let index_entries ~base_path =
  list_pages ~base_path
  |> List.filter_map (fun path ->
    let file = Filename.basename path in
    match In_channel.with_open_text path In_channel.input_all with
    | exception Sys_error _ -> None
    | content ->
      (match parse_frontmatter content with
       | Ok fm ->
         Some
           (Wiki_journal.Page
              { file; title = (fm.title :> string); summary = (fm.summary :> string) })
       | Error error ->
         Some
           (Wiki_journal.Unreadable
              { file; reason = frontmatter_error_to_string error })))

(* RFC-0189 PR-1b.7 — handlers in this module return typed
   [Tool_result.result]. Boundary back to [Tool_result.result option] in
   [dispatch] below via [lift]. Two input-rejection helpers
   ([topic_required], [query_required]) share the
   [class_:Workflow_rejection] tag at one place; create and update collect
   what they refuse as one message and hand it to [workflow_err]. I/O failures during
   read/write/promote remain [Runtime_failure]; the "No page
   matching ..." / "No candidate matching ..." not-found cases are
   [Workflow_rejection] because the caller chose the topic. *)

let workflow_err = Tool_result.workflow_err
let runtime_err = Tool_result.runtime_err

let topic_required ~tool_name ~start_time =
  workflow_err ~tool_name ~start_time "topic is required"

let query_required ~tool_name ~start_time =
  workflow_err ~tool_name ~start_time "query is required"

(* Free-form wiki content remains opaque text. *)
let text_ok ~tool_name ~start_time body : Tool_result.result =
  Tool_result.ok ~tool_name ~start_time body

(* Not a new handler. The signature moved from [args] to [_args] because
   [masc_wiki_list] stopped reading an argument, not because a new action
   appeared. It reads a directory and hands the listing back to its caller; a
   log line here would restate an outcome the caller already holds.
   TEL-OK *)
let handle_list ~tool_name ~start_time ctx _args : Tool_result.result =
  text_ok ~tool_name ~start_time
    (Wiki_journal.render_index (index_entries ~base_path:ctx.base_path))

(* Read page *)
let handle_read ~tool_name ~start_time ctx args : Tool_result.result =
  let topic = Json_util.get_string args "topic"
    |> Option.value ~default:"" in
  if String.equal topic "" then topic_required ~tool_name ~start_time
  else begin
    (* Match the query against the filename slug *or* the frontmatter [title].
       [handle_list] surfaces [fm.title] (a human title with spaces/colons/dashes),
       so a keeper that reads back a listed title must resolve here too — matching
       the slug only broke that contract, since none of the title's punctuation
       survives slugification. A page whose header does not read is listed
       by filename, so it resolves by filename and has no title to match. The
       query is lowercased once. Content read for title-matching is cached so
       the chosen file is not read twice. *)
    let topic_lc = String.lowercase_ascii topic in
    let files = list_pages ~base_path:ctx.base_path in
    let title_matches content =
      match parse_frontmatter content with
      | Ok fm ->
        string_contains ~needle:topic_lc (String.lowercase_ascii (fm.title :> string))
      | Error _ -> false
    in
    let matched =
      List.find_map
        (fun path ->
          let base_lc = String.lowercase_ascii (Filename.basename path) in
          if string_contains ~needle:topic_lc base_lc
          then Some (path, None)
          else (
            match In_channel.with_open_text path In_channel.input_all with
            | content when title_matches content -> Some (path, Some content)
            | _ -> None
            | exception Sys_error _ -> None))
        files
    in
    match matched with
    | None ->
        workflow_err ~tool_name ~start_time
          (sprintf "No page matching '%s'" topic)
    | Some (path, cached) ->
        try
          let content =
            match cached with
            | Some c -> c
            | None -> In_channel.with_open_text path In_channel.input_all
          in
          let heading =
            match parse_frontmatter content with
            | Ok _ -> Filename.basename path
            | Error error -> describe_unreadable path error
          in
          text_ok ~tool_name ~start_time (sprintf "## %s\n\n%s" heading content)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            runtime_err ~tool_name ~start_time
              (sprintf "Read error: %s"
                 (Tool_error.to_string (Tool_error.of_exn exn)))
  end

let page_path ~base_path page =
  Filename.concat (wiki_root ~base_path) (page ^ ".md")

let today () =
  (* Local, not UTC: the header dates are read by the people and Keepers on
     this machine. *)
  let date = Time_compat.now () |> Unix.localtime in
  Line.of_calendar_date
    ~year:(date.tm_year + 1900)
    ~month:(date.tm_mon + 1)
    ~day:date.tm_mday

(* One lock for the whole wiki directory. Create and update check the file and
   then write it; without the lock two writers both pass the check. The lock
   also holds between processes, for a second server on the same base path. *)
let with_wiki_lock ~tool_name ~start_time ctx f : Tool_result.result =
  let root = wiki_root ~base_path:ctx.base_path in
  match Fs_compat.mkdir_p root with
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn ->
    runtime_err ~tool_name ~start_time
      (sprintf "Wiki directory error: %s" (Tool_error.to_string (Tool_error.of_exn exn)))
  | () ->
    (match
       File_lock_eio.with_durable_lock ~lock_path:(Filename.concat root ".wiki.lock") f
     with
     | Ok result -> result
     | Error error ->
       runtime_err ~tool_name ~start_time
         (sprintf "Wiki lock error: %s" (File_lock_eio.durable_lock_error_to_string error)))

(* Page, then one log line, then the index, all under the wiki lock. The page
   is already on disk when the other two are written, so a failure there is
   reported as one: the caller learns that the page changed and which file did
   not follow. *)
let write_page ~tool_name ~start_time ctx ~path ~content ~action ~revision ~page
    ~(author : Line.t) ~(note : Line.t) ~written
  : Tool_result.result
  =
  match Fs_compat.save_file_atomic_strict_staged path content with
  | Error failure ->
    runtime_err ~tool_name ~start_time
      (sprintf "Write error: %s" (Fs_compat.atomic_replace_failure_to_string failure))
  | Ok () ->
    let wiki_root = wiki_root ~base_path:ctx.base_path in
    let line =
      Wiki_journal.log_line
        ~time:(Time_compat.now () |> Unix.localtime)
        ~action ~revision ~page
        ~author:(author :> string)
        ~note:(note :> string)
    in
    (match Wiki_journal.append_log ~wiki_root line with
     | Error message ->
       runtime_err ~tool_name ~start_time
         (sprintf "%s, but its line could not be appended to log.md: %s" written message)
     | Ok () ->
       (match
          Wiki_journal.write_index ~wiki_root (index_entries ~base_path:ctx.base_path)
        with
        | Error message ->
          runtime_err ~tool_name ~start_time
            (sprintf "%s, but index.md could not be rebuilt: %s" written message)
        | Ok () -> text_ok ~tool_name ~start_time written))

(* A field the schema does not offer but a caller sent anyway. *)
let has_field args name =
  match args with
  | `Assoc fields -> List.mem_assoc name fields
  | _ -> false

(* What the caller is told when a value it sent is not a header value. *)
let line_arg name value =
  Line.of_string value
  |> Result.map_error (function
    | Line.Blank -> sprintf "%s is required" name
    | Line.Spans_lines -> sprintf "%s must be one line" name
    | Line.Outer_whitespace -> sprintf "%s may not start or end with whitespace" name)

(* The caller's name goes into the header as [author] and into the log line.
   [missing] says which of the two a caller with no name cannot be written
   to. *)
let caller_name ctx ~missing =
  Line.of_string ctx.agent_name
  |> Result.map_error (function
    | Line.Blank -> missing
    | Line.Spans_lines -> "the caller's agent name must be one line"
    | Line.Outer_whitespace ->
      "the caller's agent name may not start or end with whitespace")

(* The tag is quoted as written, line breaks included. *)
let bad_tag_message tag problem =
  sprintf "tag \"%s\" cannot be stored: a tag %s" tag
    (match problem with
     | Tag.Not_a_line Line.Blank -> "may not be blank"
     | Tag.Not_a_line Line.Spans_lines -> "may not contain a line break"
     | Tag.Not_a_line Line.Outer_whitespace -> "may not start or end with whitespace"
     | Tag.Has_comma -> "may not contain a comma")

(* [tags] as the caller sent it: [None] when the field is absent. Every item
   has to be a tag. A blank item or one that is not a string is refused, not
   dropped, so a page holds the tags that were sent or the call fails. *)
let tags_arg args : (Tag.t list option, string) result =
  let sent =
    match args with
    | `Assoc fields -> List.assoc_opt "tags" fields
    | _ -> None
  in
  match sent with
  | None -> Ok None
  | Some (`List items) ->
    List.fold_left
      (fun read item ->
         match read, item with
         | (Error _ as refused), _ -> refused
         | Ok tags, `String raw ->
           (match Tag.of_string raw with
            | Ok tag -> Ok (tag :: tags)
            | Error problem -> Error (bad_tag_message raw problem))
         | Ok _, _ -> Error "tags must be a list of strings")
      (Ok []) items
    |> Result.map (fun tags -> Some (List.rev tags))
  | Some _ -> Error "tags must be a list of strings"

(* Create page.
   TEL-OK: the change is written to log.md by [write_page] and handed back to
   the caller; a second line here would restate it. *)
let handle_create ~tool_name ~start_time ctx args : Tool_result.result =
  let text name = Json_util.get_string args name |> Option.value ~default:"" in
  let raw_page = text "page" in
  let body = text "body" in
  let ( let* ) = Result.bind in
  let sent =
    let* page =
      validate_page_name raw_page
      |> Result.map_error (page_name_error_to_string raw_page)
    in
    let* tags = tags_arg args in
    let* title = line_arg "title" (text "title") in
    let* summary = line_arg "summary" (text "summary") in
    let* () = if String.equal body "" then Error "body is required" else Ok () in
    (* The reader requires [author]; a page this handler writes must read
       back through it, so a caller with no name is refused here rather than
       leaving a header the wiki then reports as unreadable. *)
    let* author =
      caller_name ctx ~missing:"the caller has no agent name to write as author"
    in
    (* The schema requires [source]. A missing or unknown value is refused,
       never filled in: the frontmatter records what kind of work the writer
       said the page came from, and a default would record a claim nobody
       made. *)
    let* source =
      match Json_util.get_string args "source" with
      | None -> Error "source is required"
      | Some raw ->
        Option.to_result
          ~none:
            (sprintf "Invalid source. Must be one of: %s"
               (String.concat ", " valid_source_strings))
          (source_of_string_opt raw)
    in
    Ok (page, title, summary, author, source, Option.value tags ~default:[])
  in
  match sent with
  | Error message -> workflow_err ~tool_name ~start_time message
  | Ok (page, title, summary, author, source, tags) ->
    with_wiki_lock ~tool_name ~start_time ctx (fun () ->
      let path = page_path ~base_path:ctx.base_path page in
      if Sys.file_exists path
      then
        workflow_err ~tool_name ~start_time
          (sprintf
             "page \"%s\" already exists. Read it and call masc_wiki_update to change \
              it."
             page)
      else begin
        let day = today () in
        let content =
          render_page
            { title; summary; source; author; created = day; revision = 1; tags }
            ~updated:day ~body
        in
        write_page ~tool_name ~start_time ctx ~path ~content
          ~action:Wiki_journal.Created ~revision:1 ~page ~author ~note:summary
          ~written:(sprintf "Created wiki page %s at revision 1: %s" page path)
      end)

(* A refused update tells the writer where the page is now, so the writer can
   merge into that body and send again without another read. *)
let stale_revision ~tool_name ~start_time ~page ~base_revision ~current_revision ~body =
  Tool_result.make_err ~tool_name ~class_:Tool_result.Workflow_rejection ~start_time
    ~data:
      (`Assoc
         [ "page", `String page
         ; "base_revision", `Int base_revision
         ; "current_revision", `Int current_revision
         ; "body", `String body
         ])
    (sprintf
       "page \"%s\" is at revision %d, not %d. Merge your change into the current \
        body below and call again with base_revision %d.\n\n%s"
       page current_revision base_revision current_revision body)

(* Update page.
   TEL-OK: as [handle_create]; a refused update is returned to the caller with
   the current revision. *)
let handle_update ~tool_name ~start_time ctx args : Tool_result.result =
  let raw_page = Json_util.get_string args "page" |> Option.value ~default:"" in
  let body = Json_util.get_string args "body" |> Option.value ~default:"" in
  let ( let* ) = Result.bind in
  (* A title or summary the caller left out keeps the current one. One that
     was sent has to be a header value. *)
  let kept_or_new name =
    match Json_util.get_string args name with
    | None -> Ok None
    | Some value ->
      (match Line.of_string value with
       | Ok line -> Ok (Some line)
       | Error Line.Blank ->
         Error (sprintf "%s may not be empty; omit it to keep the current one" name)
       | Error (Line.Spans_lines | Line.Outer_whitespace) ->
         Result.map Option.some (line_arg name value))
  in
  let sent =
    let* page =
      validate_page_name raw_page
      |> Result.map_error (page_name_error_to_string raw_page)
    in
    let* base_revision =
      Option.to_result ~none:"base_revision is required"
        (Json_util.get_int args "base_revision")
    in
    let* () = if String.equal body "" then Error "body is required" else Ok () in
    let* note =
      line_arg "note" (Json_util.get_string args "note" |> Option.value ~default:"")
    in
    (* The log line names who made the change. *)
    let* editor =
      caller_name ctx ~missing:"the caller has no agent name to write in the log"
    in
    (* [source] says what kind of work the page first came from. *)
    let* () =
      if has_field args "source" then Error "source cannot change on update" else Ok ()
    in
    let* new_title = kept_or_new "title" in
    let* new_summary = kept_or_new "summary" in
    let* new_tags = tags_arg args in
    Ok (page, base_revision, note, editor, new_title, new_summary, new_tags)
  in
  match sent with
  | Error message -> workflow_err ~tool_name ~start_time message
  | Ok (page, base_revision, note, editor, new_title, new_summary, new_tags) ->
    with_wiki_lock ~tool_name ~start_time ctx (fun () ->
      let path = page_path ~base_path:ctx.base_path page in
      if not (Sys.file_exists path)
      then
        workflow_err ~tool_name ~start_time
          (sprintf "No page named \"%s\". Create it with masc_wiki_create." page)
      else
        match In_channel.with_open_text path In_channel.input_all with
        | exception (Eio.Cancel.Cancelled _ as e) -> raise e
        | exception exn ->
          runtime_err ~tool_name ~start_time
            (sprintf "Read error: %s" (Tool_error.to_string (Tool_error.of_exn exn)))
        | content ->
          (match parse_frontmatter content with
           | Error error ->
             workflow_err ~tool_name ~start_time
               (sprintf
                  "page \"%s\" cannot be updated: its header does not read (%s)"
                  page
                  (frontmatter_error_to_string error))
           | Ok current when current.revision <> base_revision ->
             stale_revision ~tool_name ~start_time ~page ~base_revision
               ~current_revision:current.revision ~body:(page_body content)
           | Ok current ->
             let revision = current.revision + 1 in
             let content =
               render_page
                 { current with
                   title = Option.value new_title ~default:current.title
                 ; summary = Option.value new_summary ~default:current.summary
                 ; revision
                 ; tags = Option.value new_tags ~default:current.tags
                 }
                 ~updated:(today ()) ~body
             in
             write_page ~tool_name ~start_time ctx ~path ~content
               ~action:Wiki_journal.Updated ~revision ~page ~author:editor ~note
               ~written:(sprintf "Updated wiki page %s to revision %d" page revision)))

(* Search pages *)
let handle_search ~tool_name ~start_time ctx args : Tool_result.result =
  let query = Json_util.get_string args "query"
    |> Option.value ~default:"" in
  if String.equal query "" then query_required ~tool_name ~start_time
  else begin
    let query_lower = String.lowercase_ascii query in
    let docs = list_pages ~base_path:ctx.base_path in
    let matches = List.filter_map (fun path ->
      try
        let content = In_channel.with_open_text path In_channel.input_all in
        let content_lower = String.lowercase_ascii content in
        if string_contains ~needle:query_lower content_lower then
          match parse_frontmatter content with
          | Ok fm ->
            Some (sprintf "- **%s** %s" (fm.title :> string) (Filename.basename path))
          | Error error -> Some (sprintf "- %s" (describe_unreadable path error))
        else None
      with Sys_error _ -> None
    ) docs in
    if Stdlib.List.length matches = 0 then
      text_ok ~tool_name ~start_time
        (sprintf "No pages matching '%s'" query)
    else
      text_ok ~tool_name ~start_time
        (sprintf "## Search Results (%d)\n\n%s"
           (List.length matches) (String.concat "\n" matches))
  end

(* RFC-0189 PR-1b.7 — boundary projection. Handlers are typed; the
   dispatch ABI stays [Tool_result.result option] so external callers
   (mcp_server_eio_execute, keeper_tag_dispatch) remain unchanged.
   PR-1c will move the Tool_dispatch.handler ABI to result, removing
   this bridge. *)
(* The name is resolved against the same [definitions] list registration walks,
   and the operation is matched, so an operation added to
   [Tool_schemas_wiki] is a compile error here rather than an advertised
   name with no route. *)
let find_operation name =
  List.find_opt
    (fun (definition : Tool_schemas_wiki.definition) ->
      String.equal definition.schema.name name)
    Tool_schemas_wiki.definitions
  |> Option.map (fun (definition : Tool_schemas_wiki.definition) ->
       definition.operation)

let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Tool_timing.start () in
  let lift r = Some r in
  match find_operation name with
  | None -> None
  | Some Tool_schemas_wiki.List_pages ->
    lift (handle_list ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_wiki.Read_page ->
    lift (handle_read ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_wiki.Create_page ->
    lift (handle_create ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_wiki.Update_page ->
    lift (handle_update ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_wiki.Search_pages ->
    lift (handle_search ~tool_name:name ~start_time:start ctx args)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (definition : Tool_schemas_wiki.definition) ->
      let s = definition.schema in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_wiki
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:definition.read_only
           ()))
    Tool_schemas_wiki.definitions

let schemas = Tool_schemas_wiki.schemas
