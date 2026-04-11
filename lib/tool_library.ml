(** Tool_library - Agent Knowledge Library operations

    Manages the personal knowledge base at ~/me/docs/library/
    - Direct experience documents only (source: direct_experience | research | experiment)
    - YAML frontmatter with confidence scores
    - Candidates promotion flow
*)

open Printf

(** Confidence threshold for routing documents to library vs candidates. *)
let library_confidence_threshold = 0.5

(* String helper - check if sub is contained in s *)
let string_contains ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len > s_len then false
  else
    let rec check i =
      if i > s_len - sub_len then false
      else if String.sub s i sub_len = sub then true
      else check (i + 1)
    in
    check 0

type tool_result = bool * string

type context = {
  agent_name: string;
}

(* Paths *)
let library_root () =
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
  Filename.concat home "me/docs/library"

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
    | "---" :: rest when List.length acc > 0 -> (List.rev acc, rest)
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
             String.sub line 0 (String.length pattern) = pattern then
            Some (String.trim (String.sub line (String.length pattern)
                    (String.length line - String.length pattern)))
          else None
        ) yaml_lines |> Option.value ~default:""
      in
      let get_float name default =
        try float_of_string (get_field name) with Failure _ -> default
      in
      let get_tags () =
        let raw = get_field "tags" in
        (* Parse [tag1, tag2] format *)
        let stripped = String.trim raw in
        if String.length stripped > 2 &&
           stripped.[0] = '[' &&
           stripped.[String.length stripped - 1] = ']' then
          let inner = String.sub stripped 1 (String.length stripped - 2) in
          String.split_on_char ',' inner
          |> List.map String.trim
          |> List.filter (fun s -> s <> "")
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
      |> List.filter (fun f -> Filename.check_suffix f ".md" && f <> "SCHEMA.md")
      |> List.map (fun f -> Filename.concat dir f)
    else []
  in
  let main_docs = read_dir lib_root in
  let candidate_docs =
    if include_candidates then read_dir (candidates_dir ())
    else []
  in
  main_docs @ candidate_docs

let handle_list _ctx args =
  let include_candidates =
    match Yojson.Safe.Util.member "include_candidates" args with
    | `Bool b -> b
    | _ -> false
  in
  let docs = list_documents ~include_candidates () in
  let entries = List.filter_map (fun path ->
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      match parse_frontmatter content with
      | Some fm ->
          let is_candidate = string_contains ~sub:"/candidates/" path in
          Some (sprintf "- **%s** [%.2f] %s%s\n  tags: %s"
            fm.title fm.confidence
            fm.source
            (if is_candidate then " (candidate)" else "")
            (String.concat ", " fm.tags))
      | None ->
          Some (sprintf "- %s (no frontmatter)" (Filename.basename path))
    with Sys_error _ -> None
  ) docs in
  let output = if entries = [] then "No documents in library"
    else sprintf "## Library Documents (%d)\n\n%s" (List.length entries) (String.concat "\n" entries)
  in
  (true, output)

(* Read document *)
let handle_read _ctx args =
  let topic = Yojson.Safe.Util.(member "topic" args |> to_string_option)
    |> Option.value ~default:"" in
  if topic = "" then (false, "topic is required")
  else begin
    (* Find matching file *)
    let files = list_documents ~include_candidates:true () in
    let matching = List.filter (fun f ->
      let base = Filename.basename f in
      string_contains ~sub:topic (String.lowercase_ascii base)
    ) files in
    match matching with
    | [] -> (false, sprintf "No document matching '%s'" topic)
    | path :: _ ->
        try
          let content = In_channel.with_open_text path In_channel.input_all in
          (true, sprintf "## %s\n\n%s" (Filename.basename path) content)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> (false, sprintf "Read error: %s" (Printexc.to_string exn))
  end

(* Add document *)
let handle_add ctx args =
  let module U = Yojson.Safe.Util in
  let title = U.member "title" args |> U.to_string_option |> Option.value ~default:"" in
  let source = U.member "source" args |> U.to_string_option |> Option.value ~default:"direct_experience" in
  let confidence = U.member "confidence" args |> U.to_float_option |> Option.value ~default:0.7 in
  let tags = try U.member "tags" args |> U.to_list |> List.filter_map U.to_string_option
    with Yojson.Safe.Util.Type_error (_, _) -> [] in
  let content = U.member "content" args |> U.to_string_option |> Option.value ~default:"" in

  if title = "" then (false, "title is required")
  else if content = "" then (false, "content is required")
  else begin
    (* Validate source *)
    let valid_sources = ["direct_experience"; "research"; "experiment"; "observation"] in
    if not (List.mem source valid_sources) then
      (false, sprintf "Invalid source. Must be one of: %s" (String.concat ", " valid_sources))
    else begin
      (* Determine destination based on confidence *)
      let dest_dir = if confidence < library_confidence_threshold then candidates_dir () else library_root () in
      let date = Time_compat.now () |> Unix.localtime in
      let date_str = sprintf "%04d%02d%02d" (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday in
      let topic_slug = String.lowercase_ascii title
        |> String.map (fun c -> if c = ' ' then '-' else c)
        |> String.to_seq |> Seq.filter (fun c ->
            (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-')
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
        let status = if confidence < 0.5 then "candidate (needs verification)" else "library" in
        (true, sprintf "Document added to %s: %s" status filepath)
      with Eio.Cancel.Cancelled _ as e -> raise e | exn -> (false, sprintf "Write error: %s" (Printexc.to_string exn))
    end
  end

(* Promote candidate to library *)
let handle_promote ctx args =
  let topic = Yojson.Safe.Util.(member "topic" args |> to_string_option)
    |> Option.value ~default:"" in
  let new_confidence = Yojson.Safe.Util.(member "confidence" args |> to_float_option)
    |> Option.value ~default:0.7 in

  if topic = "" then (false, "topic is required")
  else if new_confidence < 0.5 then (false, "confidence must be >= 0.5 to promote")
  else begin
    let candidates = list_documents () |> List.filter (fun f ->
      string_contains ~sub:"/candidates/" f &&
      string_contains ~sub:topic (String.lowercase_ascii (Filename.basename f))
    ) in
    match candidates with
    | [] -> (false, sprintf "No candidate matching '%s'" topic)
    | src_path :: _ ->
        try
          let content = In_channel.with_open_text src_path In_channel.input_all in
          (* Update confidence in frontmatter *)
          let updated = Re.replace_string
            (Re.Pcre.re {|confidence: [0-9.]+|} |> Re.compile)
            ~by:(sprintf "confidence: %.2f" new_confidence)
            content in
          (* Add verifier *)
          let with_verifier = Re.replace_string
            (Re.Pcre.re {|verified_by: \[\]|} |> Re.compile)
            ~by:(sprintf "verified_by: [%s]" ctx.agent_name)
            updated in
          (* Move to library *)
          let dest_path = Filename.concat (library_root ()) (Filename.basename src_path) in
          Out_channel.with_open_text dest_path (fun oc -> Out_channel.output_string oc with_verifier);
          Sys.remove src_path;
          (true, sprintf "Promoted to library: %s (confidence: %.2f)" dest_path new_confidence)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> (false, sprintf "Promote error: %s" (Printexc.to_string exn))
  end

(* Search documents *)
let handle_search _ctx args =
  let query = Yojson.Safe.Util.(member "query" args |> to_string_option)
    |> Option.value ~default:"" in
  if query = "" then (false, "query is required")
  else begin
    let query_lower = String.lowercase_ascii query in
    let docs = list_documents ~include_candidates:true () in
    let matches = List.filter_map (fun path ->
      try
        let content = In_channel.with_open_text path In_channel.input_all in
        let content_lower = String.lowercase_ascii content in
        if string_contains ~sub:query_lower content_lower then
          match parse_frontmatter content with
          | Some fm -> Some (sprintf "- **%s** [%.2f] %s" fm.title fm.confidence (Filename.basename path))
          | None -> Some (sprintf "- %s" (Filename.basename path))
        else None
      with Sys_error _ -> None
    ) docs in
    if matches = [] then (true, sprintf "No documents matching '%s'" query)
    else (true, sprintf "## Search Results (%d)\n\n%s" (List.length matches) (String.concat "\n" matches))
  end

(* Dispatch *)
let dispatch ctx ~name ~args : tool_result option =
  match name with
  | "masc_library_list" -> Some (handle_list ctx args)
  | "masc_library_read" -> Some (handle_read ctx args)
  | "masc_library_add" -> Some (handle_add ctx args)
  | "masc_library_promote" -> Some (handle_promote ctx args)
  | "masc_library_search" -> Some (handle_search ctx args)
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
    ("source", "string", true, "Source type: direct_experience, research, experiment, observation");
    ("confidence", "number", true, "Confidence score 0.0-1.0");
    ("tags", "array", false, "List of tags");
    ("content", "string", true, "Document body content (markdown)");
  ]);
  ("masc_library_promote", {|Promote a candidate document to the main library after verification.|}, [
    ("topic", "string", true, "Topic name to promote");
    ("confidence", "number", true, "New confidence score (must be >= 0.5)");
  ]);
  ("masc_library_search", {|Search library documents by content or tags.|}, [
    ("query", "string", true, "Search query");
  ]);
]

let schemas : Types.tool_schema list = [
  (* masc_library_list *)
  {
    name = "masc_library_list";
    description = "List all documents in the agent knowledge library with title, confidence, source, and tags. \
Use when browsing available knowledge or checking if a topic is already documented. \
Pair with masc_library_read to fetch a specific document or masc_library_search to query by content.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("include_candidates", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include candidate documents awaiting verification");
        ]);
      ]);
    ];
  };

  (* masc_library_read *)
  {
    name = "masc_library_read";
    description = "Read a specific library document by topic name or partial match. \
Use when you need the full content of a known knowledge document. \
After masc_library_list or masc_library_search to find the topic name.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "Topic name or partial match (e.g., 'eio-mutex')");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };

  (* masc_library_add *)
  {
    name = "masc_library_add";
    description = "Add a new document to the agent knowledge library (confidence < 0.5 goes to candidates/ for review). \
Use when recording a new finding, experiment result, or pattern that other agents should know about. \
Follow up with masc_library_promote to move candidates to the main library after verification.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Document title");
        ]);
        ("source", `Assoc [
          ("type", `String "string");
          ("description", `String "Source type: direct_experience, research, experiment, observation");
          ("enum", `List [`String "direct_experience"; `String "research"; `String "experiment"; `String "observation"]);
        ]);
        ("confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "Confidence score 0.0-1.0");
        ]);
        ("tags", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of tags");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Document body content (markdown)");
        ]);
      ]);
      ("required", `List [`String "title"; `String "source"; `String "confidence"; `String "content"]);
    ];
  };

  (* masc_library_promote *)
  {
    name = "masc_library_promote";
    description = "Promote a candidate document to the main library after verification (new confidence must be >= 0.5). \
Use when a candidate document has been reviewed and confirmed as accurate. \
After masc_library_add placed the document in candidates/.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "Topic name to promote");
        ]);
        ("confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "New confidence score (must be >= 0.5)");
        ]);
      ]);
      ("required", `List [`String "topic"; `String "confidence"]);
    ];
  };

  (* masc_library_search *)
  {
    name = "masc_library_search";
    description = "Search the agent knowledge library by content keywords or tags. \
Use when looking for documents on a specific topic without knowing the exact title. \
Pair with masc_library_read to fetch matching documents in full.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Search query");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };

]

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_library
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
