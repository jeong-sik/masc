(** Tool_schemas_library — SSOT for library tool schemas. *)

open Masc_domain

let valid_source_strings = [ "direct_experience"; "research"; "experiment"; "observation" ]

type operation =
  | List_documents
  | Read_document
  | Add_document
  | Promote_document
  | Search_documents

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let operation_id = function
  | List_documents -> "list"
  | Read_document -> "read"
  | Add_document -> "add"
  | Promote_document -> "promote"
  | Search_documents -> "search"
;;

let definitions : definition list = [
  (* masc_library_list *)
  { operation = List_documents; read_only = true; schema = {
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
  } };

  (* masc_library_read *)
  { operation = Read_document; read_only = true; schema = {
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
  } };

  (* masc_library_add *)
  { operation = Add_document; read_only = false; schema = {
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
          ("description",
           `String
             ("Source type: direct_experience, research, experiment, observation"));
          ("enum",
           `List (List.map (fun s -> `String s) valid_source_strings));
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
  } };

  (* masc_library_promote *)
  { operation = Promote_document; read_only = false; schema = {
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
  } };

  (* masc_library_search *)
  { operation = Search_documents; read_only = true; schema = {
    name = "masc_library_search";
    description = "Search the agent knowledge library by content keywords or tags. \
Use when looking for documents on a specific topic without knowing the exact title. \
Pair with masc_library_read to fetch matching documents in full.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Search query; empty or missing returns a workflow error");
        ]);
      ]);
    ];
  } };
]

let schemas = List.map (fun definition -> definition.schema) definitions
