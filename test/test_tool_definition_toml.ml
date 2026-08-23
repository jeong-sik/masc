(** Tests for [Tool_definition_toml] — the config/tools/<name>.toml loader
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    The round-trip cases hold the expected [Masc_domain.tool_schema] as an
    OCaml literal in exactly the shape the hand-written schema modules use
    today, and compare serialized JSON byte-for-byte: this is the property
    the migration PRs rely on when they replace a literal with a TOML file.
    The rejection cases pin fail-closed decoding: unknown keys, unknown
    enumerated values, and missing required keys are errors, never
    defaults. *)

open Alcotest

let json_string (schema : Masc_domain.tool_schema) =
  Yojson.Safe.to_string
    (`Assoc
       [ "name", `String schema.name
       ; "description", `String schema.description
       ; "input_schema", schema.input_schema
       ])
;;

let check_loads ~name ~contents (expected : Masc_domain.tool_schema) =
  match Tool_definition_toml.load ~name ~contents with
  | Ok actual -> check string "schema JSON" (json_string expected) (json_string actual)
  | Error message -> failf "expected a schema, got error: %s" message
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec probe i = i + n <= h && (String.equal (String.sub haystack i n) needle || probe (i + 1)) in
  probe 0
;;

let check_rejects ~name ~contents needle =
  match Tool_definition_toml.load ~name ~contents with
  | Ok (schema : Masc_domain.tool_schema) ->
    failf "expected an error mentioning %S, got schema %s" needle schema.name
  | Error message ->
    check bool
      (Printf.sprintf "error %S mentions %S" message needle)
      true
      (contains ~needle message)
;;

(* ── Round trips ──────────────────────────────────────────────────────── *)

(* Every JSON Schema element the board tool literals use today: enum,
   default (int and bool), minimum/maximum, maxLength, pattern, inline items
   placed before the description, a section items table with nested object
   params, required ordering, and additionalProperties. *)
let full_feature_toml =
  {|name = "masc_example_full"
description = """
Vote on one existing board post by exact post_id to signal agreement or \
quality. Use after the post_id is visible."""
additional_properties = false

[[params]]
name = "post_id"
type = "string"
required = true
pattern = "^p-[0-9a-f]+$"
description = "Required exact board post ID (format: p-xxxx)."

[[params]]
name = "direction"
type = "string"
enum = ["up", "down"]
required = true
description = "Required vote direction: up or down"

[[params]]
name = "limit"
type = "integer"
description = "Max posts to return"
default = 20
minimum = 1
maximum = 100

[[params]]
name = "compact"
type = "boolean"
default = true
description = "Compact one-line per post. Set false for full body"

[[params]]
name = "query"
type = "string"
max_length = 200
description = "Search keyword"

[[params]]
name = "ordering"
type = "array"
items = { type = "string" }
description = "Recommended post id reading order"

[[params]]
name = "since"
type = "number"
description = "Unix timestamp"

[[params]]
name = "meta"
type = "object"
description = "Optional structured operational metadata"

[[params]]
name = "sources"
type = "array"
description = "Optional external evidence sources"

[params.items]
type = "object"

[[params.items.params]]
name = "url"
type = "string"
description = "Source URL"

[[params.items.params]]
name = "quote"
type = "string"
description = "Short relevant quote or snippet"
|}
;;

let full_feature_expected : Masc_domain.tool_schema =
  { name = "masc_example_full"
  ; description =
      "Vote on one existing board post by exact post_id to signal agreement or \
       quality. Use after the post_id is visible."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "post_id"
                , `Assoc
                    [ "type", `String "string"
                    ; "pattern", `String "^p-[0-9a-f]+$"
                    ; ( "description"
                      , `String "Required exact board post ID (format: p-xxxx)." )
                    ] )
              ; ( "direction"
                , `Assoc
                    [ "type", `String "string"
                    ; "enum", `List [ `String "up"; `String "down" ]
                    ; "description", `String "Required vote direction: up or down"
                    ] )
              ; ( "limit"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Max posts to return"
                    ; "default", `Int 20
                    ; "minimum", `Int 1
                    ; "maximum", `Int 100
                    ] )
              ; ( "compact"
                , `Assoc
                    [ "type", `String "boolean"
                    ; "default", `Bool true
                    ; ( "description"
                      , `String "Compact one-line per post. Set false for full body" )
                    ] )
              ; ( "query"
                , `Assoc
                    [ "type", `String "string"
                    ; "maxLength", `Int 200
                    ; "description", `String "Search keyword"
                    ] )
              ; ( "ordering"
                , `Assoc
                    [ "type", `String "array"
                    ; "items", `Assoc [ "type", `String "string" ]
                    ; "description", `String "Recommended post id reading order"
                    ] )
              ; ( "since"
                , `Assoc
                    [ "type", `String "number"
                    ; "description", `String "Unix timestamp"
                    ] )
              ; ( "meta"
                , `Assoc
                    [ "type", `String "object"
                    ; "description", `String "Optional structured operational metadata"
                    ] )
              ; ( "sources"
                , `Assoc
                    [ "type", `String "array"
                    ; "description", `String "Optional external evidence sources"
                    ; ( "items"
                      , `Assoc
                          [ "type", `String "object"
                          ; ( "properties"
                            , `Assoc
                                [ ( "url"
                                  , `Assoc
                                      [ "type", `String "string"
                                      ; "description", `String "Source URL"
                                      ] )
                                ; ( "quote"
                                  , `Assoc
                                      [ "type", `String "string"
                                      ; ( "description"
                                        , `String "Short relevant quote or snippet" )
                                      ] )
                                ] )
                          ] )
                    ] )
              ] )
        ; "required", `List [ `String "post_id"; `String "direction" ]
        ; "additionalProperties", `Bool false
        ]
  }
;;

let test_full_feature_round_trip () =
  check_loads ~name:"masc_example_full" ~contents:full_feature_toml
    full_feature_expected
;;

let test_no_params_yields_empty_properties () =
  check_loads ~name:"masc_example_stats"
    ~contents:
      {|name = "masc_example_stats"
description = "Get board activity statistics."
|}
    { name = "masc_example_stats"
    ; description = "Get board activity statistics."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
;;

(* The published JSON preserves the author's key order, so the same keys in
   a different order are a different byte sequence — the property the
   migration's byte-identity fixtures depend on. *)
let test_key_order_is_preserved () =
  let description_last =
    {|name = "masc_example_order"
description = "Order probe."

[[params]]
name = "limit"
type = "integer"
default = 20
description = "Max results"
|}
  in
  let description_first =
    {|name = "masc_example_order"
description = "Order probe."

[[params]]
name = "limit"
type = "integer"
description = "Max results"
default = 20
|}
  in
  let load contents =
    match Tool_definition_toml.load ~name:"masc_example_order" ~contents with
    | Ok schema -> Yojson.Safe.to_string schema.Masc_domain.input_schema
    | Error message -> failf "expected a schema, got error: %s" message
  in
  check string "description last"
    {|{"type":"object","properties":{"limit":{"type":"integer","default":20,"description":"Max results"}}}|}
    (load description_last);
  check string "description first"
    {|{"type":"object","properties":{"limit":{"type":"integer","description":"Max results","default":20}}}|}
    (load description_first)
;;

(* ── Rejections ───────────────────────────────────────────────────────── *)

let minimal name = Printf.sprintf "name = %S\ndescription = \"d.\"\n" name

let test_rejections () =
  check_rejects ~name:"t" ~contents:"name = \"t\"\n" "description";
  check_rejects ~name:"t" ~contents:"description = \"d.\"\n" "name";
  check_rejects ~name:"t" ~contents:(minimal "other") "file name";
  check_rejects ~name:"t" ~contents:"name = \"t\"\ndescription = \"\"\n" "empty";
  check_rejects ~name:"t" ~contents:(minimal "t" ^ "surprise = 1\n") "unknown key \"surprise\"";
  check_rejects ~name:"t" ~contents:"name = \"t\"\ndescription = \"d.\"\ntitle = \"T\"\n"
    "unknown key \"title\"";
  check_rejects ~name:"t" ~contents:(minimal "t" ^ "[[params]]\ntype = \"string\"\n")
    "missing the required key \"name\"";
  check_rejects ~name:"t" ~contents:(minimal "t" ^ "[[params]]\nname = \"p\"\n")
    "missing the required key \"type\"";
  check_rejects ~name:"t"
    ~contents:(minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"frobnicate\"\n")
    "unknown type \"frobnicate\"";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"string\"\nflavor = \"x\"\n")
    "unknown key \"flavor\"";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"integer\"\nenum = [\"a\"]\n")
    "only valid for type string";
  check_rejects ~name:"t"
    ~contents:(minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"string\"\nenum = []\n")
    "must not be empty";
  check_rejects ~name:"t"
    ~contents:(minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"string\"\nenum = [1]\n")
    "must be a string";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"integer\"\ndefault = \"x\"\n")
    "must be an integer";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"string\"\ndefault = \"hot\"\n")
    "not supported for type string";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"string\"\nminimum = 1\n")
    "only valid for type integer";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"integer\"\npattern = \"^x$\"\n")
    "only valid for type string";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t"
       ^ "[[params]]\nname = \"p\"\ntype = \"string\"\nitems = { type = \"string\" }\n")
    "only valid for type array";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t"
       ^ "[[params]]\nname = \"p\"\ntype = \"array\"\nitems = { type = \"object\" }\n")
    "must declare params";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t"
       ^ "[[params]]\nname = \"p\"\ntype = \"array\"\n[params.items]\ntype = \"integer\"\n")
    "not supported for items";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t"
       ^ "[[params]]\n\
          name = \"p\"\n\
          type = \"array\"\n\
          [params.items]\n\
          type = \"object\"\n\
          [[params.items.params]]\n\
          name = \"u\"\n\
          type = \"string\"\n\
          required = true\n")
    "unknown key \"required\"";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t"
       ^ "[[params]]\nname = \"p\"\ntype = \"string\"\n[[params]]\nname = \"p\"\ntype = \"string\"\n")
    "declares \"p\" twice";
  check_rejects ~name:"t" ~contents:(minimal "t" ^ "params = []\n")
    "omit the key instead";
  check_rejects ~name:"t" ~contents:(minimal "t" ^ "params = [1]\n")
    "array of tables";
  check_rejects ~name:"t" ~contents:"name = \"t\"\ndescription =\n" "parse error"
;;

(* ── Embedded tree validation ─────────────────────────────────────────── *)

let test_validate_embedded () =
  let good = minimal "masc_example_ok" in
  let embedded =
    [ "tools/masc_example_ok.toml", good
    ; "tools/managed-assets.json", "{}"
    ; "prompts/keeper.md", "not a tool"
    ; "runtime.toml", "[runtime]\n"
    ]
  in
  let read rel = List.assoc_opt rel embedded in
  (match
     Tool_definition_toml.validate_embedded ~read ~files:(List.map fst embedded)
   with
   | Ok () -> ()
   | Error message -> failf "expected a valid tree, got: %s" message);
  (match
     Tool_definition_toml.validate_embedded
       ~read:(fun (_ : string) -> None)
       ~files:[ "tools/masc_example_ok.toml" ]
   with
   | Ok () -> fail "expected unreadable definition to be an error"
   | Error message ->
     check bool "unreadable named" true (contains ~needle:"unreadable" message));
  (match
     Tool_definition_toml.validate_embedded ~read
       ~files:[ "tools/nested/masc_example_ok.toml" ]
   with
   | Ok () -> fail "expected nested path to be an error"
   | Error message ->
     check bool "nested named" true
       (contains ~needle:"directly under tools/" message));
  (match
     Tool_definition_toml.validate_embedded
       ~read:(fun rel ->
         if String.equal rel "tools/readme.txt" then Some "hello" else None)
       ~files:[ "tools/readme.txt" ]
   with
   | Ok () -> fail "expected a non-TOML file to be an error"
   | Error message ->
     check bool "unexpected file named" true
       (contains ~needle:"unexpected file" message));
  match
    Tool_definition_toml.validate_embedded
      ~read:(fun rel ->
        if String.equal rel "tools/masc_example_bad.toml"
        then Some "name = \"masc_example_bad\"\n"
        else None)
      ~files:[ "tools/masc_example_bad.toml" ]
  with
  | Ok () -> fail "expected an invalid definition to be an error"
  | Error message ->
    check bool "invalid definition named" true
      (contains ~needle:"masc_example_bad" message)
;;

let () =
  run "tool_definition_toml"
    [ ( "load"
      , [ test_case "full-feature TOML round-trips byte-identically" `Quick
            test_full_feature_round_trip
        ; test_case "no params yields empty properties" `Quick
            test_no_params_yields_empty_properties
        ; test_case "published JSON preserves the author's key order" `Quick
            test_key_order_is_preserved
        ; test_case "unknown keys, values, and missing keys reject" `Quick
            test_rejections
        ] )
    ; ( "validate_embedded"
      , [ test_case "walks tools/, skips the manifest, fails closed" `Quick
            test_validate_embedded
        ] )
    ]
;;
