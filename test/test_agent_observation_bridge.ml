(** Tests for Agent_observation -> IDE Bridge adapter wiring. *)

open Alcotest

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

let with_temp_dir f =
  let dir = Filename.temp_file "agent_observation_bridge_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  (try f dir with exn ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" dir));
     raise exn);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" dir))
;;

let json_string key json =
  Yojson.Safe.Util.member key json |> Yojson.Safe.Util.to_string
;;

let summary_count key json =
  Yojson.Safe.Util.member "summary" json
  |> Yojson.Safe.Util.member key
  |> Yojson.Safe.Util.to_int
;;

let install_fresh_ide_sink () =
  Agent_observation.reset_for_testing ();
  Ide_bridge.install_agent_observation_sinks ()
;;

(* RFC-0378 A2: test-side attribution builder; wrap in [File] for tool
   facts. *)
let addressed_file ~codebase ~path =
  match Agent_observation.Code_address.v ~codebase ~path with
  | Ok address -> Agent_observation.Addressed { address; checkout = None }
  | Error e -> failwith (Agent_observation.Code_address.invalid_to_string e)
;;

let test_tool_observation_reaches_ide_storage () =
  with_temp_dir (fun base_dir ->
    install_fresh_ide_sink ();
    Agent_observation.emit_tool_event
      { base_path = base_dir
      ; attribution =
          Agent_observation.File
            (addressed_file ~codebase:"github.com_owner_repo" ~path:"lib/test.ml")
        (* The producer mints this from the resolver; the raw [input]
           below still carries the argument the keeper typed. *)
      ; tool_name = "keeper_ide_annotate"
      ; keeper_id = "keeper-alpha"
      ; turn_id = "turn-9"
      ; outcome = "ok"
      ; typed_outcome = "progress"
      ; duration_ms = 12.0
      ; output_text = "annotated"
      ; input =
          `Assoc
            [ "file_path", `String "lib/test.ml"
            ; "line_start", `Int 42
            ]
      };
    match
      Ide_bridge.list_events
        ~base_path:base_dir
        ~codebase:("github.com_owner_repo")
        ~kind:Ide_bridge.Tool
        ~limit:1
        ()
    with
    | [ event ] ->
      check string "tool_name" "keeper_ide_annotate" (json_string "tool_name" event);
      check string "keeper_id" "keeper-alpha" (json_string "keeper_id" event)
    | _ -> fail "expected one tool event")
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

(* keeper_ide_annotate declares kind as a JSON-schema enum and the runtime
   parses it back with annotation_kind_of_string. Two hand-written lists of the
   same four names drift silently: before this test the runtime folded every
   unrecognised value onto Comment, so a schema that grew a fifth kind would
   have filed it as a comment rather than failing. Compare the two directly. *)
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
    Agent_observation.valid_annotation_kind_strings
;;

let test_annotation_kind_parser_round_trips_every_kind () =
  List.iter
    (fun k ->
      let s = Agent_observation.annotation_kind_to_string k in
      match Agent_observation.annotation_kind_of_string s with
      | Some back -> check bool ("round trip " ^ s) true (back = k)
      | None -> failf "annotation_kind_of_string rejected %S" s)
    Agent_observation.all_annotation_kinds
;;

let test_annotation_kind_parser_rejects_wrong_case () =
  (* The casing an LLM reaches for. The runtime now rejects it instead of
     filing the annotation as a Comment. *)
  check bool "lowercase decision is not a kind" true
    (Agent_observation.annotation_kind_of_string "decision" = None)
;;

let () =
  run
    "agent_observation_bridge"
    [ ( "adapter"
      , [ test_case
            "tool observation reaches IDE storage"
            `Quick
            test_tool_observation_reaches_ide_storage
        ; test_case
            "snapshot reset clears accumulated observations"
            `Quick
            test_snapshot_reset_clears_accumulated_observations
        ; test_case
            "annotation kind enum matches variants"
            `Quick
            test_annotation_kind_enum_matches_variants
        ; test_case
            "annotation kind parser round trips every kind"
            `Quick
            test_annotation_kind_parser_round_trips_every_kind
        ; test_case
            "annotation kind parser rejects wrong case"
            `Quick
            test_annotation_kind_parser_rejects_wrong_case
        ] )
    ]
;;
