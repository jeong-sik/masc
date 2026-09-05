(** keeper_library_search / keeper_library_read moved from OCaml literals in
    [tool_shard_types_schemas_library.ml] to [config/tools/*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2, migration item 6).

    Not to be confused with [test_library_tool_toml_parity], which pins the
    operator-facing masc_library_* family. These two are the keeper-facing
    pair, and they were the last literals in the tool_surface shards.

    The declaration is what moved; the published schema is not supposed to
    have changed at all. The values below are the bytes the OCaml literals
    published before the move, compared as parsed JSON with keys sorted per
    RFC §4 -- object key order is not part of a JSON object's meaning, and
    TOML cannot place a sub-table before its parent's scalar keys. *)

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
  [ ( {|keeper_library_search|}
    , {|Search the knowledge library by keyword.

Returns matching document titles, relevance scores (0-1), and text snippets. Use to discover relevant docs before reading full content with keeper_library_read.|}
    , {|{"properties":{"query":{"description":"Search query string; empty or missing returns a workflow error","type":"string"}},"type":"object"}|}
    )
  ; ( {|keeper_library_read|}
    , {|Read a full document from the knowledge library by exact topic name.

Use after keeper_library_search identifies a relevant document, or with a known topic name. Returns full document text.|}
    , {|{"properties":{"topic":{"description":"Exact document topic name (from search results or known)","type":"string"}},"required":["topic"],"type":"object"}|}
    )
  ]
;;

let published = Tool_shard_types.library_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.library_tools")
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
         (name ^ " input schema")
         (Yojson.Safe.to_string (sorted (Yojson.Safe.from_string schema)))
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.library_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "keeper_library_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ]
;;
