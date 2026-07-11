module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_library - Agent Knowledge Library operations

    Manages the personal knowledge base at ~/me/docs/library/
    - Direct experience documents only (source: see [library_source])
    - YAML frontmatter with confidence scores
    - Candidates promotion flow
*)

open Printf

(* Static frontmatter patterns used during candidate promotion.
   Hoisted to module load — promotion is rare relative to keeper
   message paths but the patterns are pure literals, so there is no
   reason to rebuild them per call. *)
let promote_confidence_re =
  Re.Pcre.re {|confidence: [0-9.]+|} |> Re.compile

let promote_verified_by_re =
  Re.Pcre.re {|verified_by: \[\]|} |> Re.compile

(** Confidence threshold for routing documents to library vs candidates. *)
let library_confidence_threshold = 0.5

(** Issue #8601: SSOT for library document [source] field. Schema enum,
    handler validation, and module docstring previously listed the values
    independently — the docstring drifted (claimed 3, runtime had 4).
    The witness pattern below is the standard Variant SSOT shape used by
    #8486 (tail_order), #8467 (sandbox_profile), #8592 (dashboard scope).
    Adding a 5th source forces compile errors in [source_to_string] and
    fails the [library_source_ssot] test in test_types.ml. *)
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

let candidates_dir () =
  Filename.concat (library_root ()) "candidates"

(* YAML frontmatter parsing *)
type frontmatter = {
  title: string;
  source: string;
  confidence: float;
  author: string;
  created: string;
  tags: string list;
}

let parse_frontmatter content =
  (* Simple YAML parser for frontmatter between --- delimiters *)
  let lines = String.split_on_char '\n' content in
  let rec find_end acc = function
    | [] -> (List.rev acc, [])
    | "---" :: rest when Stdlib.List.length acc > 0 -> (List.rev acc, rest)
    | line :: rest -> find_end (line :: acc) rest
  in
  match lines with
  | "---" :: rest ->
      let yaml_lines, _body = find_end [] rest in
      let _yaml = String.concat "\n" yaml_lines in
      (* Extract fields with simple pattern matching *)
      let get_field name =
        let pattern = name ^ ":" in
        List.find_map (fun line ->
          if String.length line > String.length pattern &&
             String.equal (Stdlib.String.sub line 0 (String.length pattern)) pattern then
            Some (String.trim (String.sub line (String.length pattern)
                    (String.length line - String.length pattern)))
          else None
        ) yaml_lines |> Option.value ~default:""
      in
      let get_float name default =
        Option.value ~default (Stdlib.float_of_string_opt (get_field name))
      in
      let get_tags () =
        let raw = get_field "tags" in
        (* Parse [tag1, tag2] format *)
        let stripped = String.trim raw in
        if String.length stripped > 2 &&
           Char.equal stripped.[0] '[' &&
           Char.equal stripped.[String.length stripped - 1] ']' then
          let inner = String.sub stripped 1 (String.length stripped - 2) in
          String.split_on_char ',' inner
          |> List.map String.trim
          |> List.filter (fun s -> not (String.equal s ""))
        else []
      in
      Some {
        title = get_field "title";
        source = get_field "source";
        confidence = get_float "confidence" 0.0;
        author = get_field "author";
        created = get_field "created";
        tags = get_tags ();
      }
  | _ -> None

(* List documents *)
let list_documents ?(include_candidates=false) () =
  let lib_root = library_root () in
  let read_dir dir =
    if Sys.file_exists dir && Sys.is_directory dir then
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".md" && not (String.equal f "SCHEMA.md"))
      |> List.map (fun f -> Filename.concat dir f)
    else []
  in
  let main_docs = read_dir lib_root in
  let candidate_docs =
    if include_candidates then read_dir (candidates_dir ())
    else []
  in
  main_docs @ candidate_docs

(* RFC-0189 PR-1b.7 — handlers in this module return typed
   [Tool_result.result]. Boundary back to [Tool_result.result option] in
   [dispatch] below via [lift]. Three input-rejection helpers
   ([topic_required], [query_required], [missing_required]) replace 5
   duplicated empty-string [Tool_result.error] sites and share the
   [class_:Workflow_rejection] tag at one place. I/O failures during
   read/write/promote remain [Runtime_failure]; the "No document
   matching ..." / "No candidate matching ..." not-found cases are
   [Workflow_rejection] because the caller chose the topic. *)

let workflow_err ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg

let runtime_err ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    msg

let topic_required ~tool_name ~start_time =
  workflow_err ~tool_name ~start_time "topic is required"

let query_required ~tool_name ~start_time =
  workflow_err ~tool_name ~start_time "query is required"

let missing_required ~tool_name ~start_time field =
  workflow_err ~tool_name ~start_time (sprintf "%s is required" field)

(* RFC-0189 follow-up — preserve [Tool_result.message] round-trips.

   The original PR-1b.7 [text_ok] wrapped [body] as
   [`Assoc [ "text", `String body ]].  That works only when callers
   read [result.data]; clients (and tests) that read
   [result.message] receive [Yojson.Safe.to_string] of the wrapped
   object — i.e. [{"text":"...escaped body..."}] — instead of the
   raw Markdown / JSON envelope they expect.

   [structured_payload_of_message] keeps JSON bodies structured and
   plain text as [`String body], so both [data] and [message] stay
   round-trip safe. *)
let text_ok ~tool_name ~start_time body : Tool_result.result =
  let data =
    match Tool_result.structured_payload_of_message body with
    | Some json -> json
    | None -> `String body
  in
  Tool_result.make_ok ~tool_name ~start_time ~data ()

let handle_list ~tool_name ~start_time _ctx args : Tool_result.result =
  let include_candidates =
    match Json_util.assoc_member_opt "include_candidates" args with
    | Some (`Bool b) -> b
    | _ -> false
  in
  let docs = list_documents ~include_candidates () in
  let entries = List.filter_map (fun path ->
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      match parse_frontmatter content with
      | Some fm ->
          let is_candidate = string_contains ~needle:"/candidates/" path in
          Some (sprintf "- **%s** [%.2f] %s%s\n  tags: %s"
            fm.title fm.confidence
            fm.source
            (if is_candidate then " (candidate)" else "")
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
    let files = list_documents ~include_candidates:true () in
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
  let confidence = Json_util.get_float args "confidence" |> Option.value ~default:0.7 in
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
      (* Determine destination based on confidence *)
      let dest_dir = if Stdlib.Float.compare confidence library_confidence_threshold < 0 then candidates_dir () else library_root () in
      let date = Time_compat.now () |> Unix.localtime in
      let date_str = sprintf "%04d%02d%02d" (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday in
      let topic_slug = String.lowercase_ascii title
        |> String.map (fun c -> if Char.equal c ' ' then '-' else c)
        |> Stdlib.String.to_seq |> Stdlib.Seq.filter (fun c ->
            (match c with 'a'..'z' | '0'..'9' | '-' -> true | _ -> false))
        |> String.of_seq in
      let filename = sprintf "%s-%s.md" topic_slug date_str in
      let filepath = Filename.concat dest_dir filename in

      (* Create frontmatter *)
      let tags_str = sprintf "[%s]" (String.concat ", " tags) in
      let full_content = sprintf {|---
title: %s
source: %s
confidence: %.2f
author: %s
created: %s
updated: %s
tags: %s
verified_by: []
---

%s
|} title source confidence ctx.agent_name
        (sprintf "%04d-%02d-%02d" (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday)
        (sprintf "%04d-%02d-%02d" (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday)
        tags_str content in

      (* Write file *)
      try
        Out_channel.with_open_text filepath (fun oc -> Out_channel.output_string oc full_content);
        let status = if Stdlib.Float.compare confidence 0.5 < 0 then "candidate (needs verification)" else "library" in
        text_ok ~tool_name ~start_time
          (sprintf "Document added to %s: %s" status filepath)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          runtime_err ~tool_name ~start_time
            (sprintf "Write error: %s"
               (Tool_error.to_string (Tool_error.of_exn exn)))
    end
  end

(* Promote candidate to library *)
let handle_promote ~tool_name ~start_time ctx args : Tool_result.result =
  let topic = Json_util.get_string args "topic"
    |> Option.value ~default:"" in
  let new_confidence = Json_util.get_float args "confidence"
    |> Option.value ~default:0.7 in

  if String.equal topic "" then topic_required ~tool_name ~start_time
  else if Stdlib.Float.compare new_confidence 0.5 < 0 then
    workflow_err ~tool_name ~start_time
      "confidence must be >= 0.5 to promote"
  else begin
    let topic_lower = String.lowercase_ascii topic in
    let candidates = list_documents ~include_candidates:true () |> List.filter (fun f ->
      string_contains ~needle:"/candidates/" f &&
      string_contains ~needle:topic_lower (String.lowercase_ascii (Filename.basename f))
    ) in
    match candidates with
    | [] ->
        workflow_err ~tool_name ~start_time
          (sprintf "No candidate matching '%s'" topic)
    | src_path :: _ ->
        try
          let content = In_channel.with_open_text src_path In_channel.input_all in
          let updated =
            Re.replace_string promote_confidence_re
              ~by:(sprintf "confidence: %.2f" new_confidence)
              content
          in
          let with_verifier =
            Re.replace_string promote_verified_by_re
              ~by:(sprintf "verified_by: [%s]" ctx.agent_name)
              updated
          in
          (* Move to library *)
          let dest_path = Filename.concat (library_root ()) (Filename.basename src_path) in
          Out_channel.with_open_text dest_path (fun oc -> Out_channel.output_string oc with_verifier);
          Sys.remove src_path;
          text_ok ~tool_name ~start_time
            (sprintf "Promoted to library: %s (confidence: %.2f)" dest_path new_confidence)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            runtime_err ~tool_name ~start_time
              (sprintf "Promote error: %s"
                 (Tool_error.to_string (Tool_error.of_exn exn)))
  end

(* Search documents *)
let handle_search ~tool_name ~start_time _ctx args : Tool_result.result =
  let query = Json_util.get_string args "query"
    |> Option.value ~default:"" in
  if String.equal query "" then query_required ~tool_name ~start_time
  else begin
    let query_lower = String.lowercase_ascii query in
    let docs = list_documents ~include_candidates:true () in
    let matches = List.filter_map (fun path ->
      try
        let content = In_channel.with_open_text path In_channel.input_all in
        let content_lower = String.lowercase_ascii content in
        if string_contains ~needle:query_lower content_lower then
          match parse_frontmatter content with
          | Some fm -> Some (sprintf "- **%s** [%.2f] %s" fm.title fm.confidence (Filename.basename path))
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
let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  let lift r = Some r in
  match name with
  | "masc_library_list" -> lift (handle_list ~tool_name:name ~start_time:start ctx args)
  | "masc_library_read" -> lift (handle_read ~tool_name:name ~start_time:start ctx args)
  | "masc_library_add" -> lift (handle_add ~tool_name:name ~start_time:start ctx args)
  | "masc_library_promote" -> lift (handle_promote ~tool_name:name ~start_time:start ctx args)
  | "masc_library_search" -> lift (handle_search ~tool_name:name ~start_time:start ctx args)
  | _ -> None

(* Tool definitions for MCP protocol *)
let tool_definitions = [
  ("masc_library_list", {|List all documents in the agent knowledge library. Returns title, confidence, source, and tags for each document.|}, [
    ("include_candidates", "boolean", false, "Include candidate documents awaiting verification");
  ]);
  ("masc_library_read", {|Read a specific library document by topic name.|}, [
    ("topic", "string", true, "Topic name or partial match (e.g., 'eio-mutex')");
  ]);
  ("masc_library_add", {|Add a new document to the library. Documents with confidence < 0.5 go to candidates/.|}, [
    ("title", "string", true, "Document title");
    ("source", "string", true,
     sprintf "Source type: %s" (String.concat ", " valid_source_strings));
    ("confidence", "number", true, "Confidence score 0.0-1.0");
    ("tags", "array", false, "List of tags");
    ("content", "string", true, "Document body content (markdown)");
  ]);
  ("masc_library_promote", {|Promote a candidate document to the main library after verification.|}, [
    ("topic", "string", true, "Topic name to promote");
    ("confidence", "number", true, "New confidence score (must be >= 0.5)");
  ]);
  ("masc_library_search", {|Search library documents by content or tags.|}, [
    ("query", "string", false, "Search query; empty or missing returns a workflow error");
  ]);
]

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
           ~is_idempotent:definition.read_only
           ()))
    Tool_schemas_library.definitions

let schemas = Tool_schemas_library.schemas
