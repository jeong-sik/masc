(** Tool_wiki - Wiki operations

    Manages the pages at [<base>/docs/wiki/<page>.md]
    - The writer names the page; the name is the file name and never changes
    - Every page carries a [source] from [wiki_source]
    - YAML frontmatter records who wrote the page, when, why, a one-line
      summary and the page revision
    - A page is created once and then updated against the revision the
      writer read
*)

open Printf

(** The page [source] vocabulary. [source_to_string] is the one place the
    spelling is written: [valid_source_strings] and [source_of_string_opt] are
    derived from it over [all_of_wiki_source], so a new constructor is a
    non-exhaustive match there and nowhere else in this module.
    masc_wiki_create's schema writes the same strings as a literal enum in
    config/tools/masc_wiki_create.toml; the "wiki source enum" case in
    test_enum_mirror_sync compares that enum with [valid_source_strings]. *)
type wiki_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation
[@@deriving enumerate]

let source_to_string = function
  | Direct_experience -> "direct_experience"
  | Research -> "research"
  | Experiment -> "experiment"
  | Observation -> "observation"

let valid_source_strings = List.map source_to_string all_of_wiki_source

let source_of_string_opt raw =
  List.find_opt
    (fun source -> String.equal (source_to_string source) raw)
    all_of_wiki_source

let string_contains = String_util.string_contains_substring

(* Header values. Each is written on one line as [key: value] and read back
   trimmed, so the writer refuses any value that would come back as something
   else: a page that was accepted must read as what was sent. *)

(* Blank once trimmed: it would read back as a missing field. *)
let blank value = String.equal (String.trim value) ""

let one_line value = not (String.contains value '\n' || String.contains value '\r')

(* The tags line is [tags: \[a, b\]]. A comma splits one tag into two, a
   bracket or a line break ends the list or the header early, and outer
   spaces are trimmed on the way back. *)
let tag_reads_back tag =
  (not (blank tag))
  && String.equal (String.trim tag) tag
  && not
       (Stdlib.String.exists
          (fun c ->
             match c with
             | '\n' | '\r' | ',' | '[' | ']' -> true
             | _ -> false)
          tag)

let first_bad_tag tags = List.find_opt (fun tag -> not (tag_reads_back tag)) tags

type context = {
  base_path: string;
  agent_name: string;
}

(* Paths. [base_path] is the workspace the caller already resolved, the same
   one every other tool in the request reads. *)
let wiki_root ~base_path =
  Filename.concat base_path "docs/wiki"

(* YAML frontmatter parsing. Every field a writer sets and a reader projects
   is required: a page missing one does not read, rather than reading as an
   empty string. [updated] is written but nothing reads it. *)
type frontmatter = {
  title: string;
  summary: string;
  source: wiki_source;
  author: string;
  created: string;
  revision: int;
  tags: string list;
}

type frontmatter_field =
  | Title
  | Summary
  | Source
  | Author
  | Created
  | Revision
  | Tags

let frontmatter_field_key = function
  | Title -> "title"
  | Summary -> "summary"
  | Source -> "source"
  | Author -> "author"
  | Created -> "created"
  | Revision -> "revision"
  | Tags -> "tags"

(* Why a page's header does not read as a wiki page. The raw value
   of an unknown source is kept only to name it back to the reader. *)
type frontmatter_error =
  | No_frontmatter
  | Unclosed_frontmatter
  | Missing_field of frontmatter_field
  | Unknown_source of string
  | Bad_revision of string
  | Bad_tags of string

let parse_frontmatter content =
  match Frontmatter.read content with
  | Frontmatter.Absent -> Error No_frontmatter
  | Frontmatter.Unclosed -> Error Unclosed_frontmatter
  | Frontmatter.Closed parsed ->
    let ( let* ) = Result.bind in
    let lookup field =
      List.assoc_opt (frontmatter_field_key field) parsed.Frontmatter.fields
    in
    (* A scalar that is present but empty says nothing, so it reads as absent.
       [tags] is a list, and [tags: []] is a page with no tags. *)
    let scalar field =
      match lookup field with
      | Some value when not (String.equal value "") -> Ok value
      | Some _ | None -> Error (Missing_field field)
    in
    let* title = scalar Title in
    let* summary = scalar Summary in
    let* raw_source = scalar Source in
    let* source =
      Option.to_result ~none:(Unknown_source raw_source) (source_of_string_opt raw_source)
    in
    let* author = scalar Author in
    let* created = scalar Created in
    let* raw_revision = scalar Revision in
    let* revision =
      match int_of_string_opt raw_revision with
      | Some revision when revision >= 1 -> Ok revision
      | Some _ | None -> Error (Bad_revision raw_revision)
    in
    let* tags =
      match lookup Tags with
      | Some value ->
        (* A list the tags line cannot hold, such as one with no closing
           bracket, is not cut down to the pieces that happen to parse. *)
        let tags = Frontmatter.list_value value in
        if List.for_all tag_reads_back tags then Ok tags else Error (Bad_tags value)
      | None -> Error (Missing_field Tags)
    in
    Ok { title; summary; source; author; created; revision; tags }
;;

(* The raw source is quoted as written: [%S] would escape a non-ASCII value
   into decimal byte codes the reader cannot recognise. *)
let frontmatter_error_to_string = function
  | No_frontmatter -> "no frontmatter"
  | Unclosed_frontmatter -> "frontmatter has no closing ---"
  | Missing_field field -> sprintf "no %s in frontmatter" (frontmatter_field_key field)
  | Unknown_source raw ->
    sprintf "source \"%s\" is not one of: %s" raw (String.concat ", " valid_source_strings)
  | Bad_revision raw -> sprintf "revision \"%s\" is not a whole number from 1" raw
  | Bad_tags raw -> sprintf "tags \"%s\" is not a list of tags" raw

(* The one line list, read and search print for a page whose header does
   not read: its filename and the reason. *)
let describe_unreadable path error =
  sprintf "%s (%s)" (Filename.basename path) (frontmatter_error_to_string error)

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
         Some (Wiki_journal.Page { file; title = fm.title; summary = fm.summary })
       | Error error ->
         Some
           (Wiki_journal.Unreadable
              { file; reason = frontmatter_error_to_string error })))

(* RFC-0189 PR-1b.7 — handlers in this module return typed
   [Tool_result.result]. Boundary back to [Tool_result.result option] in
   [dispatch] below via [lift]. Three input-rejection helpers
   ([topic_required], [query_required], [missing_required]) replace 5
   duplicated empty-string [Tool_result.error] sites and share the
   [class_:Workflow_rejection] tag at one place. I/O failures during
   read/write/promote remain [Runtime_failure]; the "No page
   matching ..." / "No candidate matching ..." not-found cases are
   [Workflow_rejection] because the caller chose the topic. *)

let workflow_err = Tool_result.workflow_err
let runtime_err = Tool_result.runtime_err

let topic_required ~tool_name ~start_time =
  workflow_err ~tool_name ~start_time "topic is required"

let query_required ~tool_name ~start_time =
  workflow_err ~tool_name ~start_time "query is required"

let missing_required ~tool_name ~start_time field =
  workflow_err ~tool_name ~start_time (sprintf "%s is required" field)

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
      | Ok fm -> string_contains ~needle:topic_lc (String.lowercase_ascii fm.title)
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

(* Page names. The writer chooses the name. Nothing is derived from the title
   or the date, and a name that breaks the rule is refused rather than
   repaired: dropping characters silently is how two different titles ended
   up in one file. *)
type page_name_error =
  | Empty_page_name
  | Bad_page_characters
  | Dash_at_edge
  | Reserved_page_name

(* [index] and [log] are the wiki's own files. *)
let reserved_page_names = [ "index"; "log" ]

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

let page_path ~base_path page =
  Filename.concat (wiki_root ~base_path) (page ^ ".md")

let today () =
  (* Local, not UTC: the header dates are read by the people and Keepers on
     this machine. *)
  let date = Time_compat.now () |> Unix.localtime in
  sprintf "%04d-%02d-%02d" (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday

let render_page ~title ~summary ~source ~author ~created ~updated ~revision ~tags ~body =
  let body_end = if String.ends_with ~suffix:"\n" body then "" else "\n" in
  sprintf {|---
title: %s
summary: %s
source: %s
author: %s
created: %s
updated: %s
revision: %d
tags: [%s]
---

%s%s|}
    title summary (source_to_string source) author created updated revision
    (String.concat ", " tags) body body_end

(* The body as the writer sent it: everything after the header, without the
   blank line [render_page] puts between the two. *)
let page_body content =
  let body = (Frontmatter.parse content).Frontmatter.body in
  if String.starts_with ~prefix:"\n" body
  then String.sub body 1 (String.length body - 1)
  else body

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
let write_page ~tool_name ~start_time ctx ~path ~content ~action ~revision ~page ~note
    ~written
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
        ~action ~revision ~page ~author:ctx.agent_name ~note
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

(* The tag is quoted as written, line breaks included. *)
let bad_tag_message tag =
  sprintf
    "tag \"%s\" cannot be stored: a tag may not contain a comma, a bracket or a line \
     break, or start or end with a space"
    tag

(* A field the schema does not offer but a caller sent anyway. *)
let has_field args name =
  match args with
  | `Assoc fields -> List.mem_assoc name fields
  | _ -> false

(* Create page.
   TEL-OK: the change is written to log.md by [write_page] and handed back to
   the caller; a second line here would restate it. *)
let handle_create ~tool_name ~start_time ctx args : Tool_result.result =
  let text name = Json_util.get_string args name |> Option.value ~default:"" in
  let raw_page = text "page" in
  let title = text "title" in
  let summary = text "summary" in
  let body = text "body" in
  let tags = Json_util.get_string_list args "tags" in
  match validate_page_name raw_page, first_bad_tag tags with
  | Error error, _ ->
    workflow_err ~tool_name ~start_time (page_name_error_to_string raw_page error)
  | Ok _, Some tag -> workflow_err ~tool_name ~start_time (bad_tag_message tag)
  | Ok page, None ->
    if blank title then missing_required ~tool_name ~start_time "title"
    else if not (one_line title)
    then workflow_err ~tool_name ~start_time "title must be one line"
    else if blank summary then missing_required ~tool_name ~start_time "summary"
    else if not (one_line summary)
    then workflow_err ~tool_name ~start_time "summary must be one line"
    else if String.equal body "" then missing_required ~tool_name ~start_time "body"
    else if blank ctx.agent_name
    then
      (* The reader requires [author]; a page this handler writes must read
         back through it, so a caller with no name is refused here rather than
         leaving a header the wiki then reports as unreadable. *)
      workflow_err ~tool_name ~start_time "the caller has no agent name to write as author"
    else if not (one_line ctx.agent_name)
    then workflow_err ~tool_name ~start_time "the caller's agent name must be one line"
    else begin
      (* The schema requires [source]. A missing or unknown value is refused,
         never filled in: the frontmatter records what kind of work the writer
         said the page came from, and a default would record a claim
         nobody made. *)
      match Json_util.get_string args "source" with
      | None -> missing_required ~tool_name ~start_time "source"
      | Some raw ->
      match source_of_string_opt raw with
      | None ->
        workflow_err ~tool_name ~start_time
         (sprintf "Invalid source. Must be one of: %s"
           (String.concat ", " valid_source_strings))
      | Some source ->
        with_wiki_lock ~tool_name ~start_time ctx (fun () ->
          let path = page_path ~base_path:ctx.base_path page in
          if Sys.file_exists path
          then
            workflow_err ~tool_name ~start_time
              (sprintf
                 "page \"%s\" already exists. Read it and call masc_wiki_update to \
                  change it."
                 page)
          else begin
            let day = today () in
            let content =
              render_page ~title ~summary ~source ~author:ctx.agent_name ~created:day
                ~updated:day ~revision:1 ~tags ~body
            in
            write_page ~tool_name ~start_time ctx ~path ~content
              ~action:Wiki_journal.Created ~revision:1 ~page ~note:summary
              ~written:(sprintf "Created wiki page %s at revision 1: %s" page path)
          end)
    end

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
  match validate_page_name raw_page with
  | Error error ->
    workflow_err ~tool_name ~start_time (page_name_error_to_string raw_page error)
  | Ok page ->
    match Json_util.get_int args "base_revision" with
    | None -> missing_required ~tool_name ~start_time "base_revision"
    | Some base_revision ->
    let note = Json_util.get_string args "note" |> Option.value ~default:"" in
    if String.equal body "" then missing_required ~tool_name ~start_time "body"
    else if blank note then missing_required ~tool_name ~start_time "note"
    else if not (one_line note)
    then workflow_err ~tool_name ~start_time "note must be one line"
    else if blank ctx.agent_name
    then
      (* The log line names who made the change. *)
      workflow_err ~tool_name ~start_time "the caller has no agent name to write in the log"
    else if not (one_line ctx.agent_name)
    then workflow_err ~tool_name ~start_time "the caller's agent name must be one line"
    else if has_field args "source"
    then
      (* [source] says what kind of work the page first came from. *)
      workflow_err ~tool_name ~start_time "source cannot change on update"
    else begin
      let new_title = Json_util.get_string args "title" in
      let new_summary = Json_util.get_string args "summary" in
      let one_line_field name = function
        | None -> Ok ()
        | Some value when blank value ->
          Error (sprintf "%s may not be empty; omit it to keep the current one" name)
        | Some value when not (one_line value) -> Error (sprintf "%s must be one line" name)
        | Some _ -> Ok ()
      in
      let new_tags =
        if has_field args "tags" then Some (Json_util.get_string_list args "tags") else None
      in
      match
        ( one_line_field "title" new_title
        , one_line_field "summary" new_summary
        , Option.bind new_tags first_bad_tag )
      with
      | Error message, _, _ | Ok (), Error message, _ ->
        workflow_err ~tool_name ~start_time message
      | Ok (), Ok (), Some tag -> workflow_err ~tool_name ~start_time (bad_tag_message tag)
      | Ok (), Ok (), None ->
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
                 let tags = Option.value new_tags ~default:current.tags in
                 let content =
                   render_page
                     ~title:(Option.value new_title ~default:current.title)
                     ~summary:(Option.value new_summary ~default:current.summary)
                     ~source:current.source ~author:current.author
                     ~created:current.created ~updated:(today ()) ~revision ~tags ~body
                 in
                 write_page ~tool_name ~start_time ctx ~path ~content
                   ~action:Wiki_journal.Updated ~revision ~page ~note
                   ~written:(sprintf "Updated wiki page %s to revision %d" page revision)))
    end

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
          | Ok fm -> Some (sprintf "- **%s** %s" fm.title (Filename.basename path))
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
