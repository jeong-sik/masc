(** [keeper_skill]'s declaration moved to [config/tools/keeper_skill.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    The tool was added in #30635 with its description as an OCaml literal, which
    took the model-prose ratchet over its baseline for
    [keeper_tool_composition_surface.ml] and left main red. The text is authored
    prose a person edits, so the file is where it belongs.

    What the file cannot hold is the list of skills this keeper carries: that is
    workspace state, and [Keeper_tool_composition_surface] appends it to the
    description read here. The file therefore declares the static half and the
    one parameter the tool validates against -- which is also what a reader
    opening it from a tool-call record needs to see. *)

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

let schema : Masc_domain.tool_schema = Masc.Keeper_runtime_schemas_toml.skill

let test_the_name_matches_the_tool () =
  check
    string
    "declared name"
    Masc.Keeper_tool_composition_catalog.skill_tool_name
    schema.name
;;

(* Pinned whole rather than checked for properties. #30635 shipped this
   sentence with six spaces inside it, where a line continuation had been
   dropped, and the model read every one of them. A pin says what the tool
   claims to be; a property check would have passed on the broken text. *)
let test_the_description_is_the_static_half () =
  check
    string
    "static description"
    "Read one instruction skill whole, by name. Read a skill before you act on \
     a task that names it."
    schema.description
;;

(* Byte identity against the schema the OCaml literal published before the
   move, keys sorted per RFC §4. This passing is what says the file did not
   quietly change the tool's input while relocating its text. *)
let test_the_input_schema_is_unchanged () =
  check
    string
    "input schema, keys sorted"
    {|{"additionalProperties":false,"properties":{"name":{"minLength":1,"type":"string"}},"required":["name"],"type":"object"}|}
    (Yojson.Safe.to_string (sorted schema.input_schema))
;;

let () =
  run
    "keeper_skill_tool_definition"
    [ ( "config/tools/keeper_skill.toml"
      , [ test_case "name" `Quick test_the_name_matches_the_tool
        ; test_case "description" `Quick test_the_description_is_the_static_half
        ; test_case "input schema" `Quick test_the_input_schema_is_unchanged
        ] )
    ]
;;
