(** Neutral transient observation snapshots and annotation vocabulary. Durable
    IDE projection is tested against the canonical journal in test_ide_bridge. *)

open Alcotest

let summary_count key json =
  Yojson.Safe.Util.member "summary" json
  |> Yojson.Safe.Util.member key
  |> Yojson.Safe.Util.to_int
;;

let test_snapshot_reset_clears_accumulated_observations () =
  Agent_observation.reset_for_testing ();
  Agent_observation.emit_tool_event
    { base_path = "/tmp/masc"
    ; attribution = Agent_observation.Pathless
    ; tool_name = "execute"
    ; keeper_id = "keeper-snapshot"
    ; turn_id = "turn-1"
    ; outcome = "ok"
    ; typed_outcome = "progress"
    ; duration_ms = 1.0
    ; output_text = "done"
    ; input = `Assoc []
    };
  let before =
    Agent_observation.peek_snapshot () |> Agent_observation.snapshot_to_json
  in
  check int "tool event accumulated" 1 (summary_count "tool_event_count" before);
  Agent_observation.reset_for_testing ();
  let after =
    Agent_observation.peek_snapshot () |> Agent_observation.snapshot_to_json
  in
  check int "tool events cleared" 0 (summary_count "tool_event_count" after)
;;

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
            "snapshot reset clears accumulated observations"
            `Quick
            test_snapshot_reset_clears_accumulated_observations
        ; test_case
            "annotation kind enum matches variants"
            `Quick
            test_annotation_kind_enum_matches_variants
        ] )
    ]
;;
