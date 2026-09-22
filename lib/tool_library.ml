(** Tool_library - Agent Knowledge Library operations

    Manages the knowledge base at [<base>/docs/library/]
    - Every document carries a [source] from [library_source]
    - YAML frontmatter recording who wrote the document, when, and why
*)

open Printf

(** The document [source] vocabulary. [source_to_string] is the one place the
    spelling is written: [valid_source_strings] and [source_of_string_opt] are
    derived from it over [all_of_library_source], so a new constructor is a
    non-exhaustive match there and nowhere else in this module.
    masc_library_add's schema writes the same strings as a literal enum in
    config/tools/masc_library_add.toml; the "library source enum" case in
    test_enum_mirror_sync compares that enum with [valid_source_strings]. *)
type library_source =
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

let valid_source_strings = List.map source_to_string all_of_library_source

let source_of_string_opt raw =
  List.find_opt
    (fun source -> String.equal (source_to_string source) raw)
    all_of_library_source

let string_contains = String_util.string_contains_substring

type context = {
  base_path: string;
  agent_name: string;
}

(* Paths. [base_path] is the workspace the caller already resolved, the same
   one every other tool in the request reads. *)
let library_root ~base_path =
  Filename.concat base_path "docs/library"

(* YAML frontmatter parsing. Every field [handle_add] writes and a reader
   projects is required: a document missing one does not read, rather than
   reading as an empty string. [updated] is written but nothing reads it. *)
type frontmatter = {
  title: string;
  source: library_source;
  author: string;
  created: string;
  tags: string list;
}

type frontmatter_field =
  | Title
  | Source
  | Author
  | Created
  | Tags

let frontmatter_field_key = function
  | Title -> "title"
  | Source -> "source"
  | Author -> "author"
  | Created -> "created"
  | Tags -> "tags"

(* Why a document's header does not read as a library document. The raw value
   of an unknown source is kept only to name it back to the reader. *)
type frontmatter_error =
  | No_frontmatter
  | Unclosed_frontmatter
  | Missing_field of frontmatter_field
  | Unknown_source of string

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
       [tags] is a list, and [tags: []] is a document with no tags. *)
    let scalar field =
      match lookup field with
      | Some value when not (String.equal value "") -> Ok value
      | Some _ | None -> Error (Missing_field field)
    in
    let* title = scalar Title in
    let* raw_source = scalar Source in
    let* source =
      Option.to_result ~none:(Unknown_source raw_source) (source_of_string_opt raw_source)
    in
    let* author = scalar Author in
    let* created = scalar Created in
    let* tags =
      match lookup Tags with
      | Some value -> Ok (Frontmatter.list_value value)
      | None -> Error (Missing_field Tags)
    in
    Ok { title; source; author; created; tags }
;;

(* The raw source is quoted as written: [%S] would escape a non-ASCII value
   into decimal byte codes the reader cannot recognise. *)
let frontmatter_error_to_string = function
  | No_frontmatter -> "no frontmatter"
  | Unclosed_frontmatter -> "frontmatter has no closing ---"
  | Missing_field field -> sprintf "no %s in frontmatter" (frontmatter_field_key field)
  | Unknown_source raw ->
    sprintf "source \"%s\" is not one of: %s" raw (String.concat ", " valid_source_strings)

(* The one line list, read and search print for a document whose header does
   not read: its filename and the reason. *)
let describe_unreadable path error =
  sprintf "%s (%s)" (Filename.basename path) (frontmatter_error_to_string error)

(* Every Markdown file in the library, in name order. Nothing is skipped by
   name: a file that is not a library document shows up as one whose header
   does not read. *)
let list_documents ~base_path =
  let dir = library_root ~base_path in
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".md")
    |> List.sort String.compare
    |> List.map (fun f -> Filename.concat dir f)
  else []

(* RFC-0189 PR-1b.7 — handlers in this module return typed
   [Tool_result.result]. Boundary back to [Tool_result.result option] in
   [dispatch] below via [lift]. Three input-rejection helpers
   ([topic_required], [query_required], [missing_required]) replace 5
   duplicated empty-string [Tool_result.error] sites and share the
   [class_:Workflow_rejection] tag at one place. I/O failures during
   read/write/promote remain [Runtime_failure]; the "No document
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

(* Free-form library content remains opaque text. *)
let text_ok ~tool_name ~start_time body : Tool_result.result =
  Tool_result.ok ~tool_name ~start_time body

(* Not a new handler. The signature moved from [args] to [_args] because
   [masc_library_list] stopped reading an argument, not because a new action
   appeared. It reads a directory and hands the listing back to its caller; a
   log line here would restate an outcome the caller already holds.
   TEL-OK *)
let handle_list ~tool_name ~start_time ctx _args : Tool_result.result =
  let docs = list_documents ~base_path:ctx.base_path in
  let entries = List.filter_map (fun path ->
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      match parse_frontmatter content with
      | Ok fm ->
          Some (sprintf "- **%s** (%s, %s, %s)\n  tags: %s"
            fm.title (source_to_string fm.source) fm.author fm.created
            (String.concat ", " fm.tags))
      | Error error -> Some (sprintf "- %s" (describe_unreadable path error))
    with Sys_error _ -> None
  ) docs in
  let output = if Stdlib.List.length entries = 0 then "No documents in library"
    else sprintf "## Library Documents (%d)\n\n%s" (List.length entries) (String.concat "\n" entries)
  in
  text_ok ~tool_name ~start_time output

(* Read document *)
let handle_read ~tool_name ~start_time ctx args : Tool_result.result =
  let topic = Json_util.get_string args "topic"
    |> Option.value ~default:"" in
  if String.equal topic "" then topic_required ~tool_name ~start_time
  else begin
    (* Match the query against the filename slug *or* the frontmatter [title].
       [handle_list] surfaces [fm.title] (a human title with spaces/colons/dashes),
       so a keeper that reads back a listed title must resolve here too — matching
       the slug only broke that contract, since none of the title's punctuation
       survives slugification. A document whose header does not read is listed
       by filename, so it resolves by filename and has no title to match. The
       query is lowercased once. Content read for title-matching is cached so
       the chosen file is not read twice. *)
    let topic_lc = String.lowercase_ascii topic in
    let files = list_documents ~base_path:ctx.base_path in
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
          (sprintf "No document matching '%s'" topic)
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

(* Add document *)
let handle_add ~tool_name ~start_time ctx args : Tool_result.result =
  let title = Json_util.get_string args "title" |> Option.value ~default:"" in
  let tags = Json_util.get_string_list args "tags" in
  let content = Json_util.get_string args "content" |> Option.value ~default:"" in

  if String.equal title "" then missing_required ~tool_name ~start_time "title"
  else if String.equal content "" then missing_required ~tool_name ~start_time "content"
  else if String.equal (String.trim ctx.agent_name) ""
  then
    (* The reader requires [author]; a document this handler writes must read
       back through it, so a caller with no name is refused here rather than
       leaving a header the library then reports as unreadable. *)
    workflow_err ~tool_name ~start_time "the caller has no agent name to write as author"
  else begin
    (* The schema requires [source]. A missing or unknown value is refused,
       never filled in: the frontmatter records what kind of work the writer
       said the document came from, and a default would record a claim
       nobody made. *)
    match Json_util.get_string args "source" with
    | None -> missing_required ~tool_name ~start_time "source"
    | Some raw ->
    match source_of_string_opt raw with
    | None ->
      workflow_err ~tool_name ~start_time
       (sprintf "Invalid source. Must be one of: %s"
         (String.concat ", " valid_source_strings))
    | Some source -> begin
      (* Local, not UTC, and deliberately left that way: [date_str] lands in the
         document's filename, so switching it would rename where documents are
         written. Everything derived from this one [tm] is spelled here rather
         than at each use — [created] and [updated] used to carry the same
         sprintf twice on adjacent lines. *)
      let date = Time_compat.now () |> Unix.localtime in
      let date_str = sprintf "%04d%02d%02d" (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday in
      let day = sprintf "%04d-%02d-%02d" (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday in
      let topic_slug = String.lowercase_ascii title
        |> String.map (fun c -> if Char.equal c ' ' then '-' else c)
        |> Stdlib.String.to_seq |> Stdlib.Seq.filter (fun c ->
            (match c with 'a'..'z' | '0'..'9' | '-' -> true | _ -> false))
        |> String.of_seq in
      let filename = sprintf "%s-%s.md" topic_slug date_str in
      let filepath = Filename.concat (library_root ~base_path:ctx.base_path) filename in

      (* Create frontmatter *)
      let tags_str = sprintf "[%s]" (String.concat ", " tags) in
      let full_content = sprintf {|---
title: %s
source: %s
author: %s
created: %s
updated: %s
tags: %s
---

%s
|} title (source_to_string source) ctx.agent_name
        day
        day
        tags_str content in

      (* Write file *)
      try
        Fs_compat.mkdir_p (Filename.dirname filepath);
        Out_channel.with_open_text filepath (fun oc -> Out_channel.output_string oc full_content);
        text_ok ~tool_name ~start_time
          (sprintf "Document added to library: %s" filepath)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          runtime_err ~tool_name ~start_time
            (sprintf "Write error: %s"
               (Tool_error.to_string (Tool_error.of_exn exn)))
    end
  end

(* Search documents *)
let handle_search ~tool_name ~start_time ctx args : Tool_result.result =
  let query = Json_util.get_string args "query"
    |> Option.value ~default:"" in
  if String.equal query "" then query_required ~tool_name ~start_time
  else begin
    let query_lower = String.lowercase_ascii query in
    let docs = list_documents ~base_path:ctx.base_path in
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
        (sprintf "No documents matching '%s'" query)
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
   [Tool_schemas_library] is a compile error here rather than an advertised
   name with no route. *)
let find_operation name =
  List.find_opt
    (fun (definition : Tool_schemas_library.definition) ->
      String.equal definition.schema.name name)
    Tool_schemas_library.definitions
  |> Option.map (fun (definition : Tool_schemas_library.definition) ->
       definition.operation)

let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  let lift r = Some r in
  match find_operation name with
  | None -> None
  | Some Tool_schemas_library.List_documents ->
    lift (handle_list ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_library.Read_document ->
    lift (handle_read ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_library.Add_document ->
    lift (handle_add ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_library.Search_documents ->
    lift (handle_search ~tool_name:name ~start_time:start ctx args)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (definition : Tool_schemas_library.definition) ->
      let s = definition.schema in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_library
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:definition.read_only
           ()))
    Tool_schemas_library.definitions

let schemas = Tool_schemas_library.schemas
