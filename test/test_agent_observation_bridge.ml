(** Annotation vocabulary. Durable IDE projection is tested against the
    canonical journal in test_ide_bridge. *)

open Alcotest

(* keeper_ide_annotate declares kind as a JSON-schema enum in its TOML and
   the runtime parses it back with [Ide_memo.kind_of_word]. A hand-written
   enum and the constructor-derived word list drift silently: before this
   test the runtime folded every unrecognised value onto Comment, so a schema
   that grew a fifth kind would have filed it as a comment rather than
   failing. Compare the two directly. *)
let schema_kind_enum () =
  let annotate =
    List.find
      (fun (t : Masc_domain.tool_schema) -> t.name = "keeper_ide_annotate")
      Tool_shard_types.filesystem_tools
  in
  let open Yojson.Safe.Util in
  annotate.input_schema
  |> member "properties"
  |> member "kind"
  |> member "enum"
  |> to_list
  |> List.map to_string
;;

let test_annotation_kind_enum_matches_variants () =
  check (list string)
    "schema enum == annotation_kind constructors"
    (schema_kind_enum ())
    Ide_memo.kind_words
;;

let () =
  run
    "agent_observation_bridge"
    [ ( "adapter"
      , [ test_case
            "annotation kind enum matches variants"
            `Quick
            test_annotation_kind_enum_matches_variants
        ] )
    ]
;;
