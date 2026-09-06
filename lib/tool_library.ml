(** Tool_library - Agent Knowledge Library operations

    Manages the personal knowledge base at [<base>/docs/library/]
    - Direct experience documents only (source: see [library_source])
    - YAML frontmatter recording who wrote the document, when, and why
*)

open Printf

(** Issue #8601: SSOT for library document [source] field. Schema enum,
    handler validation, and module docstring previously listed the values
    independently — the docstring drifted (claimed 3, runtime had 4).
    The witness pattern below is the standard Variant SSOT shape used by
    #8486 (tail_order), #8467 (sandbox_profile), #8592 (dashboard scope).
    Adding a 5th source forces compile errors in [source_to_string].
    There is no [library_source_ssot] test; the compile errors are the
    whole guard. *)
type library_source =
  | Direct_experience
  | Research
  | Experiment
  | Observation

let source_to_string = function
  | Direct_experience -> "direct_experience"
  | Research -> "research"
  | Experiment -> "experiment"
  | Observation -> "observation"

let all_sources = [ Direct_experience; Research; Experiment; Observation ]

let valid_source_strings = List.map source_to_string all_sources

let source_of_string_opt = function
  | "direct_experience" -> Some Direct_experience
  | "research" -> Some Research
  | "experiment" -> Some Experiment
  | "observation" -> Some Observation
  | _ -> None

let string_contains = String_util.string_contains_substring

type context = {
  agent_name: string;
}

(* Paths *)
let workspace_root () =
  match Sys.getenv_opt "MASC_BASE_PATH" |> Option.map String.trim with
  | Some root when root <> "" -> Env_config_core.normalize_masc_base_path_input root
  | _ -> (Host_config.host ()).sandbox_workspace_root

let library_root () =
  Filename.concat (workspace_root ()) "docs/library"

(* YAML frontmatter parsing *)
type frontmatter = {
  title: string;
  source: string;
  author: string;
  created: string;
  tags: string list;
}

let parse_frontmatter content =
  if not (Frontmatter.has_frontmatter content)
  then None
  else (
    let parsed = Frontmatter.parse content in
    Some
      { title = Frontmatter.field parsed "title"
      ; source = Frontmatter.field parsed "source"
      ; author = Frontmatter.field parsed "author"
      ; created = Frontmatter.field parsed "created"
      ; tags = Frontmatter.list_field parsed "tags"
      })
;;

(* List documents *)
let list_documents () =
  let dir = library_root () in
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".md" && not (String.equal f "SCHEMA.md"))
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
let handle_list ~tool_name ~start_time _ctx _args : Tool_result.result =
  let docs = list_documents () in
  let entries = List.filter_map (fun path ->
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      match parse_frontmatter content with
      | Some fm ->
          Some (sprintf "- **%s** (%s, %s, %s)\n  tags: %s"
            fm.title fm.source fm.author fm.created
            (String.concat ", " fm.tags))
      | None ->
          Some (sprintf "- %s (no frontmatter)" (Filename.basename path))
    with Sys_error _ -> None
  ) docs in
  let output = if Stdlib.List.length entries = 0 then "No documents in library"
    else sprintf "## Library Documents (%d)\n\n%s" (List.length entries) (String.concat "\n" entries)
  in
  text_ok ~tool_name ~start_time output

(* Read document *)
let handle_read ~tool_name ~start_time _ctx args : Tool_result.result =
  let topic = Json_util.get_string args "topic"
    |> Option.value ~default:"" in
  if String.equal topic "" then topic_required ~tool_name ~start_time
  else begin
    (* Match the query against the filename slug *or* the frontmatter [title].
       [handle_list] surfaces [fm.title] (a human title with spaces/colons/dashes),
       so a keeper that reads back a listed title must resolve here too — matching
       the slug only broke that contract, since none of the title's punctuation
       survives slugification. The query is lowercased once (it was compared
       case-sensitively before, so a capitalised title never matched the
       lowercased basename either). Content read for title-matching is cached so
       the chosen file is not read twice. *)
    let topic_lc = String.lowercase_ascii topic in
    let files = list_documents () in
    let title_lc content =
      match parse_frontmatter content with
      | Some fm -> String.lowercase_ascii fm.title
      | None -> ""
    in
    let matched =
      List.find_map
        (fun path ->
          let base_lc = String.lowercase_ascii (Filename.basename path) in
          if string_contains ~needle:topic_lc base_lc
          then Some (path, None)
          else (
            match In_channel.with_open_text path In_channel.input_all with
            | content when string_contains ~needle:topic_lc (title_lc content) ->
              Some (path, Some content)
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
          text_ok ~tool_name ~start_time
            (sprintf "## %s\n\n%s" (Filename.basename path) content)
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
  let source = Json_util.get_string args "source" |> Option.value ~default:"direct_experience" in
  let tags = Json_util.get_string_list args "tags" in
  let content = Json_util.get_string args "content" |> Option.value ~default:"" in

  if String.equal title "" then missing_required ~tool_name ~start_time "title"
  else if String.equal content "" then missing_required ~tool_name ~start_time "content"
  else begin
    (* Issue #8601: validate via Variant SSOT instead of List.mem on a
       hand-rolled string list. source_of_string_opt returns None for
       any unknown value; the error message derives from
       valid_source_strings so adding a new constructor updates it
       automatically. *)
    match source_of_string_opt source with
    | None ->
      workflow_err ~tool_name ~start_time
       (sprintf "Invalid source. Must be one of: %s"
         (String.concat ", " valid_source_strings))
    | Some _ -> begin
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
      let filepath = Filename.concat (library_root ()) filename in

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
|} title source ctx.agent_name
        day
        day
        tags_str content in

      (* Write file *)
      try
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
let handle_search ~tool_name ~start_time _ctx args : Tool_result.result =
  let query = Json_util.get_string args "query"
    |> Option.value ~default:"" in
  if String.equal query "" then query_required ~tool_name ~start_time
  else begin
    let query_lower = String.lowercase_ascii query in
    let docs = list_documents () in
    let matches = List.filter_map (fun path ->
      try
        let content = In_channel.with_open_text path In_channel.input_all in
        let content_lower = String.lowercase_ascii content in
        if string_contains ~needle:query_lower content_lower then
          match parse_frontmatter content with
          | Some fm -> Some (sprintf "- **%s** %s" fm.title (Filename.basename path))
          | None -> Some (sprintf "- %s" (Filename.basename path))
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
