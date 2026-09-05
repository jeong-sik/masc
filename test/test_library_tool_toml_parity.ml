(** Byte-identity pins for the library tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_schemas_library.schemas] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    The source vocabulary is a literal in this file rather than a variant, so
    nothing derives it from an owner and the whole list moves in one step.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|masc_library_list|}, {|List every document in the agent knowledge library.

Each row carries title, source, author, created date, and tags. Use when browsing available knowledge or checking if a topic is already documented. Pair with masc_library_read to fetch a specific document or masc_library_search to query by content.|}, {|{"properties":{},"type":"object"}|}
    ; {|masc_library_read|}, {|Read a specific library document by topic name or partial match. Use when you need the full content of a known knowledge document. After masc_library_list or masc_library_search to find the topic name.|}, {|{"properties":{"topic":{"description":"Topic name or partial match (e.g., 'eio-mutex')","type":"string"}},"required":["topic"],"type":"object"}|}
    ; {|masc_library_add|}, {|Add a new document to the agent knowledge library.

Use when recording a new finding, experiment result, or pattern that other agents should know about.|}, {|{"properties":{"content":{"description":"Document body content (markdown)","type":"string"},"source":{"description":"Source type: direct_experience, research, experiment, observation","enum":["direct_experience","research","experiment","observation"],"type":"string"},"tags":{"description":"List of tags","items":{"type":"string"},"type":"array"},"title":{"description":"Document title","type":"string"}},"required":["title","source","content"],"type":"object"}|}
    ; {|masc_library_search|}, {|Search the agent knowledge library by content keywords or tags. Use when looking for documents on a specific topic without knowing the exact title. Pair with masc_library_read to fetch matching documents in full.|}, {|{"properties":{"query":{"description":"Search query; empty or missing returns a workflow error","type":"string"}},"type":"object"}|}
    ]
;;

let published = Tool_schemas_library.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_schemas_library.schemas")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* What a Keeper reads when the file declares a [keeper_projection] table:
   masc_library_list names its siblings by the keeper_* names a Keeper can
   call (keeper_tool_descriptor projects masc_library_read/search under
   them), the other three carry no table and reach the Keeper as their row.
   Read off the descriptor's literal before the sentence moved into the
   file, so this passing is what proves the file says the same thing. *)
let expected_keeper_projections =
  [ ( {|masc_library_list|}
    , Some
        {|List all documents in the agent knowledge library with title, source, author, created date, and tags. Use keeper_library_read to fetch a document or keeper_library_search to query by content.|}
    )
  ; {|masc_library_read|}, None
  ; {|masc_library_add|}, None
  ; {|masc_library_search|}, None
  ]
;;

let test_keeper_projections_are_byte_identical () =
  List.iter
    (fun (name, expected) ->
       let definition =
         match
           List.find_opt
             (fun (definition : Tool_schemas_library.definition) ->
                String.equal definition.schema.name name)
             Tool_schemas_library.definitions
         with
         | Some definition -> definition
         | None -> failwith (name ^ " is absent from Tool_schemas_library.definitions")
       in
       check
         (option string)
         (name ^ " keeper_projection description")
         expected
         (Option.map
            (fun (projection : Masc_domain.tool_schema) -> projection.description)
            definition.keeper_projection))
    expected_keeper_projections
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_library.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "library_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ; test_case
            "keeper projections"
            `Quick
            test_keeper_projections_are_byte_identical
        ] )
    ]
;;
