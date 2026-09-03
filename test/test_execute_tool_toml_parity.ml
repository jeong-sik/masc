(** Structural pins for the execute tool declaration in
    [config/tools/tool_execute.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2, RFC-execute-command-string in PR #32618).

    This suite used to hold the whole decoded schema as one byte literal and
    compare it against [Tool_shard_types.typed_execute_tools]. That proved the
    TOML said the same thing as the OCaml builders it replaced. The builders
    are gone and the TOML is the only source, so a byte literal would only
    restate the file it is read from -- and CI runs [dune build @check] alone,
    so nobody could regenerate the literal without a local build.

    What is pinned instead is the shape a model reads: which fields exist and
    in what order, which pairs of fields a call may carry, which retired names
    are absent from the whole serialized schema, and the phrases in the
    description that other suites and scripts/check-execute-async-surface.sh
    key on. Read against the published list rather than the loader, so what a
    Keeper receives is what is checked. *)

open Alcotest

let published = Tool_shard_types.typed_execute_tools

let execute_schema : Masc_domain.tool_schema = Tool_shard_types.tool_execute_schema

let member (json : Yojson.Safe.t) key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> failf "%s missing under %s" key (Yojson.Safe.to_string json))
  | other -> failf "%s looked up on non-object %s" key (Yojson.Safe.to_string other)
;;

let string_list (json : Yojson.Safe.t) =
  match json with
  | `List items ->
    List.map
      (function
        | `String s -> s
        | other -> failf "expected string, got %s" (Yojson.Safe.to_string other))
      items
  | other -> failf "expected list, got %s" (Yojson.Safe.to_string other)
;;

(* The published list is what a Keeper's tool surface is built from. *)
let test_the_published_list_is_the_one_execute_tool () =
  check
    (list string)
    "Tool_shard_types.typed_execute_tools"
    [ "tool_execute" ]
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

(* Properties are serialized in [[params]] file order, and that order is the
   order a model reads them in. *)
let test_properties_are_the_five_fields_in_order () =
  let properties =
    match member execute_schema.input_schema "properties" with
    | `Assoc fields -> List.map fst fields
    | other -> failf "properties is not an object: %s" (Yojson.Safe.to_string other)
  in
  check
    (list string)
    "properties in order"
    [ "argv"; "script"; "shell"; "cwd"; "timeout_sec" ]
    properties;
  check
    bool
    "no top-level required; oneOf owns branch selection"
    false
    (match execute_schema.input_schema with
     | `Assoc fields -> List.mem_assoc "required" fields
     | _ -> true);
  check
    (option bool)
    "unknown top-level fields rejected"
    (Some false)
    (match member execute_schema.input_schema "additionalProperties" with
     | `Bool flag -> Some flag
     | _ -> None)
;;

(* Each [[one_of]] block becomes {required: [..]; not: {required: [x]};
   description}. With one forbidden name the loader writes [not: {required:
   [x]}] directly (Tool_definition_toml.alternative_json). Two branches, each
   requiring one field and forbidding the other, is what makes argv and
   script exactly-one-of. *)
let test_one_of_is_argv_xor_script () =
  let branches =
    match member execute_schema.input_schema "oneOf" with
    | `List branches -> branches
    | other -> failf "oneOf is not a list: %s" (Yojson.Safe.to_string other)
  in
  let required_and_forbidden branch =
    ( string_list (member branch "required")
    , string_list (member (member branch "not") "required") )
  in
  check
    (list (pair (list string) (list string)))
    "oneOf branches as (required, forbidden)"
    [ [ "argv" ], [ "script" ]; [ "script" ], [ "argv" ] ]
    (List.map required_and_forbidden branches);
  List.iter
    (fun branch ->
       match member branch "description" with
       | `String text -> check bool "branch description is non-empty" true (text <> "")
       | other -> failf "branch description is not a string: %s" (Yojson.Safe.to_string other))
    branches
;;

(* None of these names is a field, a nested shape or prose anywhere in the
   schema. Checked on the serialized bytes rather than the property list so
   that holds for all three at once. *)
let test_serialized_schema_carries_no_retired_name () =
  let serialized = Yojson.Safe.to_string execute_schema.input_schema in
  List.iter
    (fun retired ->
       check
         bool
         ("serialized schema omits " ^ retired)
         false
         (Astring.String.is_infix ~affix:retired serialized))
    [ "pipeline"; "then"; "stdin"; "stdout"; "stderr"; "env" ]
;;

(* Four sentences, under 700 bytes. The three phrases are what
   test_keeper_tool_descriptor_registry_integrity,
   test_keeper_tool_execute_descriptor_variant and
   scripts/check-execute-async-surface.sh read; a rewrite that keeps them
   keeps those in step. *)
let description_ceiling_bytes = 700

let test_description_is_short_and_keeps_its_stable_phrases () =
  let description = execute_schema.description in
  check
    bool
    (Printf.sprintf
       "description is at most %d bytes (got %d)"
       description_ceiling_bytes
       (String.length description))
    true
    (String.length description <= description_ceiling_bytes);
  List.iter
    (fun phrase ->
       check
         bool
         ("description says: " ^ phrase)
         true
         (Astring.String.is_infix ~affix:phrase description))
    [ "one non-empty argv process vector"
    ; "never interprets program or subcommand meaning"
    ; "there is no background task lifecycle"
    ]
;;

let () =
  run
    "execute_tool_toml_parity"
    [ ( "structure"
      , [ test_case
            "published list is the one execute tool"
            `Quick
            test_the_published_list_is_the_one_execute_tool
        ; test_case
            "properties are the five fields in order"
            `Quick
            test_properties_are_the_five_fields_in_order
        ; test_case "oneOf is argv xor script" `Quick test_one_of_is_argv_xor_script
        ; test_case
            "serialized schema carries no retired name"
            `Quick
            test_serialized_schema_carries_no_retired_name
        ; test_case
            "description is short and keeps its stable phrases"
            `Quick
            test_description_is_short_and_keeps_its_stable_phrases
        ] )
    ]
;;
