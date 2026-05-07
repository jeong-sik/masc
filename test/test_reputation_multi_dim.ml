(** Tests for multi-dimensional reputation scoring and dynamic autonomy. *)

open Alcotest
open Masc_mcp

let persistence_counter reason =
  Prometheus.metric_value_or_zero Prometheus.metric_persistence_read_drops
    ~labels:[("surface", "agent_reputation"); ("reason", reason)]
    ()

let with_temp_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "test_agent_reputation_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let rec cleanup path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter
          (fun name -> cleanup (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  Fun.protect
    ~finally:(fun () -> try cleanup dir with _ -> ())
    (fun () ->
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:(Some "tester"));
      f config)

(* ── Reputation_autonomy tests ────────────────────────────────────── *)

let test_autonomy_string_round_trip () =
  List.iter (fun level ->
    let s = Reputation_autonomy.autonomy_level_to_string level in
    match Reputation_autonomy.autonomy_level_of_string s with
    | Some parsed ->
      check string "round-trip"
        (Reputation_autonomy.autonomy_level_to_string parsed) s
    | None ->
      Alcotest.failf "round-trip failed for %s" s)
  [ Reputation_autonomy.Restricted
  ; Reputation_autonomy.Standard
  ; Reputation_autonomy.Elevated
  ; Reputation_autonomy.Full ]

let test_autonomy_unknown_string () =
  check bool "unknown returns None" true
    (Option.is_none
       (Reputation_autonomy.autonomy_level_of_string "ultra"))

let test_autonomy_perfect_agent_gets_full () =
  let level =
    Reputation_autonomy.compute_autonomy_level
      ~execution_reliability:1.0
      ~goal_adherence:1.0
      ~safety_compliance:1.0
      ~accountability_score:1.0
  in
  check string "perfect → Full"
    "full"
    (Reputation_autonomy.autonomy_level_to_string level)

let test_autonomy_zero_safety_gets_restricted () =
  let level =
    Reputation_autonomy.compute_autonomy_level
      ~execution_reliability:1.0
      ~goal_adherence:1.0
      ~safety_compliance:0.0
      ~accountability_score:1.0
  in
  check string "zero safety → Restricted"
    "restricted"
    (Reputation_autonomy.autonomy_level_to_string level)

let test_autonomy_moderate_scores_standard () =
  (* Moderate scores across all dimensions → Standard *)
  let level =
    Reputation_autonomy.compute_autonomy_level
      ~execution_reliability:0.65
      ~goal_adherence:0.55
      ~safety_compliance:0.85
      ~accountability_score:0.5
  in
  check string "moderate → Standard"
    "standard"
    (Reputation_autonomy.autonomy_level_to_string level)

let test_autonomy_high_scores_elevated () =
  let level =
    Reputation_autonomy.compute_autonomy_level
      ~execution_reliability:0.85
      ~goal_adherence:0.75
      ~safety_compliance:0.92
      ~accountability_score:0.75
  in
  check string "high scores → Elevated"
    "elevated"
    (Reputation_autonomy.autonomy_level_to_string level)

let test_autonomy_poor_reliability_restricts () =
  (* Good safety, poor reliability → Restricted or Standard depending on thresholds *)
  let level =
    Reputation_autonomy.compute_autonomy_level
      ~execution_reliability:0.3
      ~goal_adherence:0.9
      ~safety_compliance:0.95
      ~accountability_score:0.9
  in
  let s = Reputation_autonomy.autonomy_level_to_string level in
  check bool "poor reliability does not get Elevated or Full" true
    (s = "restricted" || s = "standard")

let test_autonomy_to_json () =
  let json =
    Reputation_autonomy.autonomy_level_to_json Reputation_autonomy.Standard
  in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "level" fields with
      | Some (`String s) -> check string "level field" "standard" s
      | _ -> fail "expected level field")
   | _ -> fail "expected assoc")

let test_describe_constraints_non_empty () =
  List.iter (fun level ->
    let desc = Reputation_autonomy.describe_autonomy_constraints level in
    check bool "non-empty description" true (String.length desc > 0))
  [ Reputation_autonomy.Restricted
  ; Reputation_autonomy.Standard
  ; Reputation_autonomy.Elevated
  ; Reputation_autonomy.Full ]

(* ── Agent_reputation v2 field defaults ─────────────────────────── *)

let test_default_reputation_v2_fields () =
  let rep = Agent_reputation.default_reputation ~agent_name:"test-agent" in
  check (float 0.0001) "execution_reliability default" 1.0
    rep.execution_reliability;
  check (float 0.0001) "goal_adherence default" 1.0
    rep.goal_adherence;
  check (float 0.0001) "safety_compliance default" 1.0
    rep.safety_compliance;
  check string "autonomy_level default" "standard"
    rep.autonomy_level

let test_reputation_json_roundtrip_v2_fields () =
  let rep = Agent_reputation.default_reputation ~agent_name:"json-test" in
  let json = Agent_reputation.reputation_to_json rep in
  match Agent_reputation.reputation_of_json json with
  | Some r ->
    check (float 0.0001) "execution_reliability preserved" 1.0
      r.execution_reliability;
    check string "autonomy_level preserved" "standard"
      r.autonomy_level
  | None ->
    fail "reputation_of_json returned None"

let test_compute_overall_score_pure () =
  let score =
    Agent_reputation.compute_overall_score
      ~completion_rate:1.0
      ~response_rate:1.0
      ~board_posts:10
      ~board_comments:10
      ~thompson_confidence:0.5
  in
  check bool "score in [0,1]" true (score >= 0.0 && score <= 1.0)

let test_compute_accountability_score_penalty () =
  let penalized =
    Agent_reputation.compute_accountability_score
      ~evidence_coverage:0.5
      ~unsupported_completion_rate:0.5
      ~open_overdue_commitments:0
  in
  check (float 0.0001) "fully penalized → 0.0" 0.0 penalized

let test_reputation_jsonl_drop_metric () =
  with_temp_config @@ fun config ->
  let posts_path =
    Filename.concat (Coord.masc_dir config) "board_posts.jsonl"
  in
  Fs_compat.save_file posts_path
    (String.concat "\n"
       [
         "{not-json";
         Yojson.Safe.to_string
           (`Assoc
             [
               ("id", `String "post-1");
               ("author", `String "rep-agent");
               ("title", `String "valid");
             ]);
       ]
     ^ "\n");
  let before =
    persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
  in
  let rep = Agent_reputation.compute_reputation config ~agent_name:"rep-agent" in
  check int "valid post still counted" 1 rep.board_posts;
  check
    (float 0.1)
    "malformed board JSONL increments persistence drop metric"
    1.0
    (persistence_counter Safe_ops.persistence_read_drop_reason_entry_load_error
     -. before)

let () =
  run "Reputation_multi_dim"
    [ ( "autonomy",
        [ test_case "string round-trip" `Quick
            test_autonomy_string_round_trip
        ; test_case "unknown string → None" `Quick
            test_autonomy_unknown_string
        ; test_case "perfect agent → Full" `Quick
            test_autonomy_perfect_agent_gets_full
        ; test_case "zero safety → Restricted" `Quick
            test_autonomy_zero_safety_gets_restricted
        ; test_case "moderate scores → Standard" `Quick
            test_autonomy_moderate_scores_standard
        ; test_case "high scores → Elevated" `Quick
            test_autonomy_high_scores_elevated
        ; test_case "poor reliability does not elevate" `Quick
            test_autonomy_poor_reliability_restricts
        ; test_case "to_json includes level" `Quick
            test_autonomy_to_json
        ; test_case "describe_constraints non-empty" `Quick
            test_describe_constraints_non_empty
        ] )
    ; ( "agent_reputation_v2",
        [ test_case "default v2 fields are neutral" `Quick
            test_default_reputation_v2_fields
        ; test_case "json round-trip preserves v2 fields" `Quick
            test_reputation_json_roundtrip_v2_fields
        ; test_case "compute_overall_score in range" `Quick
            test_compute_overall_score_pure
        ; test_case "full accountability penalty → 0.0" `Quick
            test_compute_accountability_score_penalty
        ; test_case "jsonl drops increment metric" `Quick
            test_reputation_jsonl_drop_metric
        ] )
    ]
