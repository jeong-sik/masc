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
  | Ok { Tool_definition_toml.schema; keeper_projection } ->
    check string "schema JSON" (json_string expected) (json_string schema);
    check bool "no keeper projection" true (Option.is_none keeper_projection)
  | Error message -> failf "expected a schema, got error: %s" message
;;

let check_loads_keeper_projection ~name ~contents (expected : Masc_domain.tool_schema) =
  match Tool_definition_toml.load ~name ~contents with
  | Ok { Tool_definition_toml.keeper_projection = Some projection; _ } ->
    check string "keeper projection JSON" (json_string expected)
      (json_string projection)
  | Ok { Tool_definition_toml.keeper_projection = None; _ } ->
    fail "expected a keeper projection, got none"
  | Error message -> failf "expected a keeper projection, got error: %s" message
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec probe i = i + n <= h && (String.equal (String.sub haystack i n) needle || probe (i + 1)) in
  probe 0
;;

let check_rejects ~name ~contents needle =
  match Tool_definition_toml.load ~name ~contents with
  | Ok { Tool_definition_toml.schema; _ } ->
    failf "expected an error mentioning %S, got schema %s" needle
      schema.Masc_domain.name
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
    | Ok { Tool_definition_toml.schema; _ } ->
      Yojson.Safe.to_string schema.Masc_domain.input_schema
    | Error message -> failf "expected a schema, got error: %s" message
  in
  check string "description last"
    {|{"type":"object","properties":{"limit":{"type":"integer","default":20,"description":"Max results"}}}|}
    (load description_last);
  check string "description first"
    {|{"type":"object","properties":{"limit":{"type":"integer","description":"Max results","default":20}}}|}
    (load description_first)
;;

let minimal name = Printf.sprintf "name = %S\ndescription = \"d.\"\n" name

(* A [keeper_projection] table yields a second schema under the same tool
   name: own description, own params, own additionalProperties. *)
let keeper_projection_toml =
  {|name = "masc_example_vote"
description = "Vote a board post up or down."

[[params]]
name = "post_id"
type = "string"
required = true
description = "Exact board post ID."

[keeper_projection]
description = "Vote on one existing board post by exact post_id."
additional_properties = false

[[keeper_projection.params]]
name = "post_id"
type = "string"
required = true
description = "Required exact board post ID (format: p-xxxx)."

[[keeper_projection.params]]
name = "direction"
type = "string"
enum = ["up", "down"]
required = true
description = "Required vote direction: up or down"
|}
;;

let test_keeper_projection_round_trip () =
  check_loads_keeper_projection ~name:"masc_example_vote"
    ~contents:keeper_projection_toml
    { name = "masc_example_vote"
    ; description = "Vote on one existing board post by exact post_id."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "post_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Required exact board post ID (format: p-xxxx)." )
                      ] )
                ; ( "direction"
                  , `Assoc
                      [ "type", `String "string"
                      ; "enum", `List [ `String "up"; `String "down" ]
                      ; ( "description"
                        , `String "Required vote direction: up or down" )
                      ] )
                ] )
          ; "required", `List [ `String "post_id"; `String "direction" ]
          ; "additionalProperties", `Bool false
          ]
    };
  (* The canonical schema of the same file is unaffected by the table. *)
  match
    Tool_definition_toml.load ~name:"masc_example_vote"
      ~contents:keeper_projection_toml
  with
  | Ok { Tool_definition_toml.schema; _ } ->
    check string "canonical description" "Vote a board post up or down."
      schema.Masc_domain.description
  | Error message -> failf "expected a schema, got error: %s" message
;;

let test_keeper_projection_rejections () =
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[keeper_projection]\nadditional_properties = false\n")
    "keeper_projection is missing the required key \"description\"";
  check_rejects ~name:"t"
    ~contents:
      (minimal "t" ^ "[keeper_projection]\ndescription = \"d.\"\nvisibility = \"model\"\n")
    "keeper_projection: unknown key \"visibility\"";
  check_rejects ~name:"t"
    ~contents:(minimal "t" ^ "keeper_projection = \"board\"\n")
    "must be a table"
;;

(* ── Rejections ───────────────────────────────────────────────────────── *)

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
      (minimal "t" ^ "[[params]]\nname = \"p\"\ntype = \"number\"\ndefault = 1.5\n")
    "not supported for type number";
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

(* ── The recursive parameter grammar ──────────────────────────────────────
   masc_add_task.contract, masc_transition.handoff_context and
   masc_batch_add_tasks.tasks could not move to TOML: an object parameter with
   its own params, and an array whose object items declare required children,
   were parsed by two separate key sets that did not admit each other. The
   grammar is one function now, so these pin the shapes that were rejected. *)

let load_ok ~name ~contents =
  match Tool_definition_toml.load ~name ~contents with
  | Ok { Tool_definition_toml.schema; _ } -> schema
  | Error message -> failf "expected a schema, got error: %s" message
;;

let member (json : Yojson.Safe.t) key =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let property schema path =
  List.fold_left
    (fun acc key ->
       match member acc "properties" with
       | Some (`Assoc props) ->
         (match List.assoc_opt key props with
          | Some found -> found
          | None -> failf "no property %S" key)
       | _ -> failf "no properties while looking for %S" key)
    schema.Masc_domain.input_schema
    path
;;

let test_an_object_parameter_declares_its_own_params () =
  let schema =
    load_ok ~name:"t"
      ~contents:
        (minimal "t"
         ^ "[[params]]\nname = \"contract\"\ntype = \"object\"\n\
            additional_properties = false\n\
            [[params.params]]\nname = \"strict\"\ntype = \"boolean\"\n\
            [[params.params]]\nname = \"items_list\"\ntype = \"array\"\n\
            [params.params.items]\ntype = \"string\"\n")
  in
  check bool "the nested object is closed" true
    (member (property schema [ "contract" ]) "additionalProperties" = Some (`Bool false));
  check bool "the nested boolean is reachable" true
    (member (property schema [ "contract"; "strict" ]) "type" = Some (`String "boolean"));
  check bool "an array nested inside the object keeps its items" true
    (member
       (match member (property schema [ "contract"; "items_list" ]) "items" with
        | Some items -> items
        | None -> failf "items_list lost its items")
       "type"
     = Some (`String "string"))
;;

(* [required] belongs to the enclosing object, not to the property. A child
   marked required has to appear in the parent's list, or a caller reading the
   schema cannot tell the field is mandatory. *)
let test_a_nested_required_child_lands_in_its_parents_list () =
  let schema =
    load_ok ~name:"t"
      ~contents:
        (minimal "t"
         ^ "[[params]]\nname = \"handoff\"\ntype = \"object\"\n\
            [[params.params]]\nname = \"summary\"\ntype = \"string\"\n\
            required = true\nmin_length = 1\n\
            [[params.params]]\nname = \"note\"\ntype = \"string\"\n")
  in
  check bool "the parent lists the required child" true
    (member (property schema [ "handoff" ]) "required" = Some (`List [ `String "summary" ]));
  check bool "min_length reaches the child" true
    (member (property schema [ "handoff"; "summary" ]) "minLength" = Some (`Int 1));
  check bool "required is not emitted onto the child" true
    (member (property schema [ "handoff"; "summary" ]) "required" = None)
;;

(* An array can bound both ends. keeper_task_done requires at least one
   evidence ref, and the loader read no lower bound at all before this, so that
   declaration could not move out of OCaml. *)
let test_an_array_carries_min_items () =
  let schema =
    load_ok ~name:"t"
      ~contents:
        (minimal "t"
         ^ "[[params]]\nname = \"evidence_refs\"\ntype = \"array\"\n\
            min_items = 1\nmax_items = 8\n\
            items = { type = \"string\" }\n")
  in
  let refs = property schema [ "evidence_refs" ] in
  check bool "min_items reaches the array" true (member refs "minItems" = Some (`Int 1));
  check bool "max_items still reaches it" true (member refs "maxItems" = Some (`Int 8))
;;

(* min_items on anything but an array is a declaration error, not a key the
   loader quietly drops. *)
let test_min_items_is_rejected_off_an_array () =
  check_rejects
    ~name:"t"
    ~contents:
      (minimal "t" ^ "[[params]]\nname = \"n\"\ntype = \"string\"\nmin_items = 1\n")
    "min_items"
;;

let test_array_items_carry_max_items_and_required () =
  let schema =
    load_ok ~name:"t"
      ~contents:
        (minimal "t"
         ^ "[[params]]\nname = \"tasks\"\ntype = \"array\"\nmax_items = 20\n\
            [params.items]\ntype = \"object\"\n\
            [[params.items.params]]\nname = \"title\"\ntype = \"string\"\n\
            required = true\n\
            [[params.items.params]]\nname = \"priority\"\ntype = \"integer\"\n\
            default = 3\n")
  in
  let tasks = property schema [ "tasks" ] in
  check bool "max_items reaches the array" true (member tasks "maxItems" = Some (`Int 20));
  let items =
    match member tasks "items" with
    | Some items -> items
    | None -> failf "tasks lost its items"
  in
  check bool "the item lists its required child" true
    (member items "required" = Some (`List [ `String "title" ]));
  check bool "a default inside items survives" true
    (match member items "properties" with
     | Some (`Assoc props) ->
       (match List.assoc_opt "priority" props with
        | Some p -> member p "default" = Some (`Int 3)
        | None -> false)
     | _ -> false)
;;

(* A string default names which value a caller gets by omitting the key, the
   same way an integer one does. It was refused, so masc_dashboard — whose
   [scope] defaults to a string — could not be declared in TOML at all. *)
let test_a_string_default_is_accepted () =
  let schema =
    load_ok ~name:"t"
      ~contents:
        (minimal "t" ^ "[[params]]\nname = \"scope\"\ntype = \"string\"\ndefault = \"hot\"\n")
  in
  check bool "the default reaches the property" true
    (member (property schema [ "scope" ]) "default" = Some (`String "hot"))
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
        ; test_case "keeper_projection table yields the keeper schema" `Quick
            test_keeper_projection_round_trip
        ; test_case "keeper_projection decode is fail-closed" `Quick
            test_keeper_projection_rejections
        ; test_case
            "an object parameter declares its own params"
            `Quick
            test_an_object_parameter_declares_its_own_params
        ; test_case
            "a nested required child lands in its parent's list"
            `Quick
            test_a_nested_required_child_lands_in_its_parents_list
        ; test_case "an array carries min_items" `Quick test_an_array_carries_min_items
        ; test_case
            "min_items is rejected off an array"
            `Quick
            test_min_items_is_rejected_off_an_array
        ; test_case
            "array items carry max_items and required"
            `Quick
            test_array_items_carry_max_items_and_required
        ; test_case "a string default is accepted" `Quick test_a_string_default_is_accepted
        ; test_case "unknown keys, values, and missing keys reject" `Quick
            test_rejections
        ] )
    ; ( "validate_embedded"
      , [ test_case "walks tools/, skips the manifest, fails closed" `Quick
            test_validate_embedded
        ] )
    ]
;;
