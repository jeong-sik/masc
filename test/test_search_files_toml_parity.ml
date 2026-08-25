(** Byte-identity pins for the search files toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_shard_types.search_files_tools] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    Nothing here derives a value from an owner module.

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
    [ {|tool_search_files|}, {|Search file contents with ripgrep. Provide a regex `pattern` (and optionally path/glob/type). Paths resolve against your workspace root — pass a path relative to it, never a host path like '.masc/playground/your-name/...'. To list a directory, read a file, run find, or view git status/log/diff, use the Execute tool.|}, {|{"properties":{"glob":{"description":"Glob filter, e.g. '*.ml' or 'lib/**/*.ml'.","type":"string"},"limit":{"description":"Maximum number of matches to return.","type":"integer"},"path":{"description":"Directory or file to search in. Defaults to the keeper sandbox.","type":"string"},"pattern":{"description":"Regular expression in Rust regex syntax (ripgrep). No lookaround (?!...) (?<=...) and no backreferences; alternation is a plain | (never \\|); a literal double quote needs no backslash. PCRE/BRE-dialect patterns are rejected with a regex parse error.","type":"string"},"type":{"description":"Ripgrep file-type filter, e.g. 'ml', 'py'. May contain only letters, digits, hyphens, and underscores.","type":"string"}},"required":["pattern"],"type":"object"}|}
    ]
;;

let published = Tool_shard_types.search_files_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.search_files_tools")
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

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.search_files_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "search_files_toml_parity"
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
