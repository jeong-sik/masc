(** Tests for Lodge_reaction module — Emergent Identity System *)

open Alcotest
open Masc_mcp

(* Test helpers *)
let tmp_dir = ref ""

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let setup () =
  tmp_dir := Filename.temp_dir "lodge_reaction_test" "";
  Unix.putenv "ME_ROOT" !tmp_dir;
  Fs_compat.mkdir_p (Filename.concat !tmp_dir ".masc")

let teardown () =
  if !tmp_dir <> "" then
    (try rm_rf !tmp_dir with _ -> ())

(* Type conversion tests *)
let test_reaction_type_roundtrip () =
  let types = [
    Lodge_reaction.Upvote;
    Lodge_reaction.Pass;
    Lodge_reaction.CommentIntent;
    Lodge_reaction.Skip;
  ] in
  List.iter (fun t ->
    let s = Lodge_reaction.reaction_type_to_string t in
    let t' = Lodge_reaction.reaction_type_of_string s in
    check bool (Printf.sprintf "roundtrip %s" s) true (t = t')
  ) types

let test_reaction_type_strings () =
  check string "upvote" "upvote" (Lodge_reaction.reaction_type_to_string Lodge_reaction.Upvote);
  check string "pass" "pass" (Lodge_reaction.reaction_type_to_string Lodge_reaction.Pass);
  check string "comment_intent" "comment_intent" (Lodge_reaction.reaction_type_to_string Lodge_reaction.CommentIntent);
  check string "skip" "skip" (Lodge_reaction.reaction_type_to_string Lodge_reaction.Skip)

(* Trait fade tests *)
let test_trait_weight_zero_reactions () =
  let w = Lodge_reaction.trait_weight ~reaction_count:0 in
  check (float 0.01) "0 reactions = 100% traits" 1.0 w

let test_trait_weight_25_reactions () =
  let w = Lodge_reaction.trait_weight ~reaction_count:25 in
  check (float 0.01) "25 reactions = 50% traits" 0.5 w

let test_trait_weight_50_reactions () =
  let w = Lodge_reaction.trait_weight ~reaction_count:50 in
  check (float 0.01) "50 reactions = 0% traits" 0.0 w

let test_trait_weight_100_reactions () =
  let w = Lodge_reaction.trait_weight ~reaction_count:100 in
  check (float 0.01) "100 reactions = 0% traits (clamped)" 0.0 w

(* Topic extraction tests *)
let test_extract_topics_ocaml () =
  let topics = Lodge_reaction.extract_topics "I love OCaml and Eio for async programming" in
  check bool "contains ocaml" true (List.mem "ocaml" topics);
  check bool "contains eio" true (List.mem "eio" topics)

let test_extract_topics_empty () =
  let topics = Lodge_reaction.extract_topics "Hello world" in
  check int "no topics" 0 (List.length topics)

let test_extract_topics_multiple () =
  let topics = Lodge_reaction.extract_topics "GraphQL API with Neo4j and React frontend" in
  check bool "contains graphql" true (List.mem "graphql" topics);
  check bool "contains neo4j" true (List.mem "neo4j" topics);
  check bool "contains react" true (List.mem "react" topics);
  check bool "contains api" true (List.mem "api" topics)

(* Reaction storage tests *)
let test_record_and_load_reaction () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    Lodge_reaction.record_reaction
      ~agent_name:"test-agent"
      ~post_id:"post-001"
      ~post_author:"author1"
      ~post_content:"OCaml and Eio are great"
      ~reaction:Lodge_reaction.Upvote
      ~confidence:0.85
      ~reason:"good content"
      ();

    let reactions = Lodge_reaction.load_reactions ~agent_name:"test-agent" in
    check int "one reaction" 1 (List.length reactions);

    let r = List.hd reactions in
    check string "agent_name" "test-agent" r.agent_name;
    check string "post_id" "post-001" r.post_id;
    check string "post_author" "author1" r.post_author;
    check bool "reaction is Upvote" true (r.reaction = Lodge_reaction.Upvote);
    check (float 0.01) "confidence" 0.85 r.confidence
  )

let test_load_recent_reactions () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    (* Record 5 reactions *)
    for i = 1 to 5 do
      Lodge_reaction.record_reaction
        ~agent_name:"test-agent"
        ~post_id:(Printf.sprintf "post-%03d" i)
        ~post_author:"author"
        ~post_content:"content"
        ~reaction:Lodge_reaction.Upvote
        ~confidence:0.8
        ();
      Unix.sleepf 0.01  (* Small delay for timestamp ordering *)
    done;

    let recent = Lodge_reaction.load_recent_reactions ~agent_name:"test-agent" ~limit:3 in
    check int "3 recent reactions" 3 (List.length recent);

    (* Most recent should be post-005 *)
    let first = List.hd recent in
    check string "most recent is post-005" "post-005" first.post_id
  )

(* Signature computation tests *)
let test_compute_signature_empty () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    let sig_ = Lodge_reaction.compute_signature ~agent_name:"new-agent" in
    check string "agent_name" "new-agent" sig_.agent_name;
    check int "total_reactions" 0 sig_.total_reactions;
    check (float 0.01) "upvote_ratio" 0.0 sig_.upvote_ratio;
    check (float 0.01) "comment_tendency" 0.0 sig_.comment_tendency
  )

let test_compute_signature_with_reactions () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    (* 3 upvotes, 1 comment_intent, 1 pass *)
    Lodge_reaction.record_reaction ~agent_name:"test" ~post_id:"p1" ~post_author:"a"
      ~post_content:"OCaml" ~reaction:Lodge_reaction.Upvote ~confidence:0.9 ();
    Lodge_reaction.record_reaction ~agent_name:"test" ~post_id:"p2" ~post_author:"b"
      ~post_content:"Eio" ~reaction:Lodge_reaction.Upvote ~confidence:0.8 ();
    Lodge_reaction.record_reaction ~agent_name:"test" ~post_id:"p3" ~post_author:"c"
      ~post_content:"GraphQL" ~reaction:Lodge_reaction.Upvote ~confidence:0.7 ();
    Lodge_reaction.record_reaction ~agent_name:"test" ~post_id:"p4" ~post_author:"d"
      ~post_content:"Testing" ~reaction:Lodge_reaction.CommentIntent ~confidence:0.85 ();
    Lodge_reaction.record_reaction ~agent_name:"test" ~post_id:"p5" ~post_author:"e"
      ~post_content:"Rust" ~reaction:Lodge_reaction.Pass ~confidence:0.5 ();

    let sig_ = Lodge_reaction.compute_signature ~agent_name:"test" in
    check int "total_reactions" 5 sig_.total_reactions;
    check (float 0.01) "upvote_ratio" 0.6 sig_.upvote_ratio;  (* 3/5 *)
    check (float 0.01) "comment_tendency" 0.2 sig_.comment_tendency  (* 1/5 *)
  )

(* Signature persistence tests *)
let test_save_and_load_signature () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    let sig_ : Lodge_reaction.agent_signature = {
      agent_name = "persist-test";
      reaction_patterns = [("ocaml", 0.9); ("eio", 0.8)];
      upvote_ratio = 0.6;
      comment_tendency = 0.2;
      recent_reactions = [];
      generated_self_summary = Some "I like systems programming";
      total_reactions = 10;
      last_updated = Unix.gettimeofday ();
    } in

    Lodge_reaction.save_signature sig_;

    let loaded = Lodge_reaction.get_or_compute_signature ~agent_name:"persist-test" in
    check string "agent_name" "persist-test" loaded.agent_name;
    check (float 0.01) "upvote_ratio" 0.6 loaded.upvote_ratio;
    check int "total_reactions" 10 loaded.total_reactions;
    check (option string) "self_summary" (Some "I like systems programming") loaded.generated_self_summary
  )

(* Batch reaction parsing tests *)
let test_parse_batch_reactions () =
  let response = {|abc123 | upvote | 0.85 | good
def456 | pass | 0.6 |
ghi789 | comment_intent | 0.9 | question|} in

  let reactions = Lodge_reaction.parse_batch_reactions response in
  check int "3 reactions" 3 (List.length reactions);

  let r1 = List.nth reactions 0 in
  check string "r1 post_id" "abc123" r1.post_id;
  check bool "r1 is upvote" true (r1.reaction = Lodge_reaction.Upvote);
  check (float 0.01) "r1 confidence" 0.85 r1.confidence;
  check (option string) "r1 reason" (Some "good") r1.reason;

  let r2 = List.nth reactions 1 in
  check string "r2 post_id" "def456" r2.post_id;
  check bool "r2 is pass" true (r2.reaction = Lodge_reaction.Pass);
  check (option string) "r2 reason" None r2.reason

let test_parse_batch_reactions_malformed () =
  let response = {|valid | upvote | 0.8
invalid line without pipes
another | bad | notanumber|} in

  let reactions = Lodge_reaction.parse_batch_reactions response in
  check int "only 1 valid reaction" 1 (List.length reactions)

(* Prompt generation tests *)
let test_generate_identity_prompt_new_agent () =
  let sig_ : Lodge_reaction.agent_signature = {
    agent_name = "newbie";
    reaction_patterns = [];
    upvote_ratio = 0.0;
    comment_tendency = 0.0;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 0;
    last_updated = Unix.gettimeofday ();
  } in

  let prompt = Lodge_reaction.generate_identity_prompt sig_ ~static_traits:["curious"; "technical"] in
  check bool "contains static traits" true (String.length prompt > 0);
  check bool "mentions first activity" true
    (try ignore (Str.search_forward (Str.regexp_string "첫 활동") prompt 0); true
     with Not_found -> false)

let test_generate_identity_prompt_established_agent () =
  let sig_ : Lodge_reaction.agent_signature = {
    agent_name = "veteran";
    reaction_patterns = [("ocaml", 0.85); ("eio", 0.75)];
    upvote_ratio = 0.4;
    comment_tendency = 0.3;
    recent_reactions = [];
    generated_self_summary = Some "I focus on practical OCaml";
    total_reactions = 60;
    last_updated = Unix.gettimeofday ();
  } in

  let prompt = Lodge_reaction.generate_identity_prompt sig_ ~static_traits:["creative"] in
  (* Static traits should be faded (60 > 50 threshold) *)
  check bool "no static traits mentioned" true
    (try ignore (Str.search_forward (Str.regexp_string "기존 특성") prompt 0); false
     with Not_found -> true);
  check bool "contains self summary" true
    (try ignore (Str.search_forward (Str.regexp_string "practical OCaml") prompt 0); true
     with Not_found -> false)

(* Similarity tests *)
let test_signature_similarity_identical () =
  let sig_ : Lodge_reaction.agent_signature = {
    agent_name = "agent1";
    reaction_patterns = [("ocaml", 0.9); ("eio", 0.8)];
    upvote_ratio = 0.5;
    comment_tendency = 0.3;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 10;
    last_updated = Unix.gettimeofday ();
  } in
  let sim = Lodge_reaction.signature_similarity sig_ sig_ in
  check (float 0.01) "identical = 1.0" 1.0 sim

let test_signature_similarity_different () =
  let sig1 : Lodge_reaction.agent_signature = {
    agent_name = "agent1";
    reaction_patterns = [("ocaml", 0.9)];
    upvote_ratio = 0.8;
    comment_tendency = 0.1;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 10;
    last_updated = Unix.gettimeofday ();
  } in
  let sig2 : Lodge_reaction.agent_signature = {
    agent_name = "agent2";
    reaction_patterns = [("rust", 0.9)];
    upvote_ratio = 0.2;
    comment_tendency = 0.7;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 10;
    last_updated = Unix.gettimeofday ();
  } in
  let sim = Lodge_reaction.signature_similarity sig1 sig2 in
  check bool "different agents have low similarity" true (sim < 0.5)

let test_signature_similarity_insufficient_data () =
  let sig1 : Lodge_reaction.agent_signature = {
    agent_name = "agent1";
    reaction_patterns = [];
    upvote_ratio = 0.0;
    comment_tendency = 0.0;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 2;  (* < 5 threshold *)
    last_updated = Unix.gettimeofday ();
  } in
  let sig2 : Lodge_reaction.agent_signature = {
    agent_name = "agent2";
    reaction_patterns = [];
    upvote_ratio = 0.0;
    comment_tendency = 0.0;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 10;
    last_updated = Unix.gettimeofday ();
  } in
  let sim = Lodge_reaction.signature_similarity sig1 sig2 in
  check (float 0.01) "insufficient data = 0.0" 0.0 sim

(* Needs reflection test *)
let test_needs_reflection () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    (* Record exactly 20 reactions *)
    for i = 1 to 20 do
      Lodge_reaction.record_reaction
        ~agent_name:"reflect-test"
        ~post_id:(Printf.sprintf "p%d" i)
        ~post_author:"author"
        ~post_content:"content"
        ~reaction:Lodge_reaction.Upvote
        ~confidence:0.8
        ()
    done;

    let needs = Lodge_reaction.needs_reflection ~agent_name:"reflect-test" ~interval:20 in
    check bool "needs reflection at 20" true needs
  )

(* ============================================
   v2.0 Tests: Confidence Calibration, Temporal Decay, Dynamic Thresholds
   ============================================ *)

(* Temporal decay tests *)
let test_reaction_weight_now () =
  let now = Unix.gettimeofday () in
  let w = Lodge_reaction.reaction_weight ~timestamp:now in
  check (float 0.01) "current reaction = 1.0" 1.0 w

let test_reaction_weight_1_day () =
  let one_day_ago = Unix.gettimeofday () -. 86400.0 in
  let w = Lodge_reaction.reaction_weight ~timestamp:one_day_ago in
  (* 1 / (1 + 0.1 * 1) = 0.909 *)
  check bool "1 day old ≈ 0.91" true (w > 0.90 && w < 0.92)

let test_reaction_weight_10_days () =
  let ten_days_ago = Unix.gettimeofday () -. (10.0 *. 86400.0) in
  let w = Lodge_reaction.reaction_weight ~timestamp:ten_days_ago in
  (* 1 / (1 + 0.1 * 10) = 0.5 (half-life) *)
  check (float 0.01) "10 days old = 0.5 (half-life)" 0.5 w

let test_reaction_weight_30_days () =
  let thirty_days_ago = Unix.gettimeofday () -. (30.0 *. 86400.0) in
  let w = Lodge_reaction.reaction_weight ~timestamp:thirty_days_ago in
  (* 1 / (1 + 0.1 * 30) = 0.25 *)
  check (float 0.01) "30 days old = 0.25" 0.25 w

(* Confidence calibration tests *)
let test_calibration_record_and_load () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    Lodge_reaction.record_calibration
      ~agent_name:"cal-test"
      ~post_id:"post-001"
      ~predicted:0.8
      ~actual:0.6;

    let records = Lodge_reaction.load_calibration ~agent_name:"cal-test" in
    check int "one record" 1 (List.length records);

    let r = List.hd records in
    check (float 0.01) "predicted" 0.8 r.predicted_confidence;
    check (float 0.01) "actual" 0.6 r.actual_outcome;
    check (float 0.01) "error" 0.2 r.error
  )

let test_avg_calibration_error_no_data () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    let err = Lodge_reaction.avg_calibration_error ~agent_name:"nonexistent" in
    check (float 0.01) "no data = 0.5 (neutral)" 0.5 err
  )

let test_avg_calibration_error_with_data () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    (* Record calibrations with errors: 0.1, 0.2, 0.3 → avg = 0.2 *)
    Lodge_reaction.record_calibration ~agent_name:"avg-test" ~post_id:"p1" ~predicted:0.8 ~actual:0.7;
    Lodge_reaction.record_calibration ~agent_name:"avg-test" ~post_id:"p2" ~predicted:0.8 ~actual:0.6;
    Lodge_reaction.record_calibration ~agent_name:"avg-test" ~post_id:"p3" ~predicted:0.8 ~actual:0.5;

    let err = Lodge_reaction.avg_calibration_error ~agent_name:"avg-test" in
    check (float 0.01) "avg error = 0.2" 0.2 err
  )

(* Dynamic threshold tests *)
let test_calibrated_threshold_no_history () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    let t = Lodge_reaction.calibrated_threshold ~agent_name:"new-agent" ~base_threshold:0.7 in
    (* No data → avg_error = 0.5 → adjustment = 0.25 (capped) *)
    check (float 0.01) "no history = base + 0.25" 0.95 t
  )

let test_calibrated_threshold_well_calibrated () =
  setup ();
  Fun.protect ~finally:teardown (fun () ->
    (* Well calibrated: errors near 0 *)
    Lodge_reaction.record_calibration ~agent_name:"good-agent" ~post_id:"p1" ~predicted:0.8 ~actual:0.8;
    Lodge_reaction.record_calibration ~agent_name:"good-agent" ~post_id:"p2" ~predicted:0.7 ~actual:0.7;

    let t = Lodge_reaction.calibrated_threshold ~agent_name:"good-agent" ~base_threshold:0.7 in
    (* avg_error ≈ 0 → threshold ≈ base *)
    check bool "well calibrated ≈ base" true (t >= 0.7 && t < 0.75)
  )

(* Cosine similarity tests (v2.0 upgrade from Jaccard) *)
let test_cosine_similarity_same_affinities () =
  let sig1 : Lodge_reaction.agent_signature = {
    agent_name = "agent1";
    reaction_patterns = [("ocaml", 0.9); ("eio", 0.8); ("graphql", 0.5)];
    upvote_ratio = 0.3;
    comment_tendency = 0.2;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 50;
    last_updated = Unix.gettimeofday ();
  } in
  let sig2 : Lodge_reaction.agent_signature = {
    agent_name = "agent2";
    reaction_patterns = [("ocaml", 0.9); ("eio", 0.8); ("graphql", 0.5)];
    upvote_ratio = 0.3;
    comment_tendency = 0.2;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 50;
    last_updated = Unix.gettimeofday ();
  } in
  let sim = Lodge_reaction.signature_similarity sig1 sig2 in
  check bool "identical affinities → high similarity" true (sim > 0.95)

let test_cosine_similarity_different_strengths () =
  (* Same topics but different affinity strengths *)
  let sig1 : Lodge_reaction.agent_signature = {
    agent_name = "agent1";
    reaction_patterns = [("ocaml", 0.9); ("rust", 0.2)];
    upvote_ratio = 0.3;
    comment_tendency = 0.2;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 50;
    last_updated = Unix.gettimeofday ();
  } in
  let sig2 : Lodge_reaction.agent_signature = {
    agent_name = "agent2";
    reaction_patterns = [("ocaml", 0.3); ("rust", 0.9)];
    upvote_ratio = 0.3;
    comment_tendency = 0.2;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 50;
    last_updated = Unix.gettimeofday ();
  } in
  let sim = Lodge_reaction.signature_similarity sig1 sig2 in
  (* Cosine catches different strengths, should be moderate *)
  check bool "different strengths → moderate similarity" true (sim > 0.3 && sim < 0.8)

(* Test suite *)
let () =
  run "Lodge_reaction" [
    "type_conversion", [
      test_case "roundtrip" `Quick test_reaction_type_roundtrip;
      test_case "strings" `Quick test_reaction_type_strings;
    ];
    "trait_fade", [
      test_case "0 reactions" `Quick test_trait_weight_zero_reactions;
      test_case "25 reactions" `Quick test_trait_weight_25_reactions;
      test_case "50 reactions" `Quick test_trait_weight_50_reactions;
      test_case "100 reactions" `Quick test_trait_weight_100_reactions;
    ];
    "topic_extraction", [
      test_case "ocaml topics" `Quick test_extract_topics_ocaml;
      test_case "empty" `Quick test_extract_topics_empty;
      test_case "multiple" `Quick test_extract_topics_multiple;
    ];
    "storage", [
      test_case "record and load" `Quick test_record_and_load_reaction;
      test_case "recent reactions" `Quick test_load_recent_reactions;
    ];
    "signature", [
      test_case "empty" `Quick test_compute_signature_empty;
      test_case "with reactions" `Quick test_compute_signature_with_reactions;
      test_case "persistence" `Quick test_save_and_load_signature;
    ];
    "batch_parsing", [
      test_case "valid" `Quick test_parse_batch_reactions;
      test_case "malformed" `Quick test_parse_batch_reactions_malformed;
    ];
    "prompt_generation", [
      test_case "new agent" `Quick test_generate_identity_prompt_new_agent;
      test_case "established agent" `Quick test_generate_identity_prompt_established_agent;
    ];
    "similarity", [
      test_case "identical" `Quick test_signature_similarity_identical;
      test_case "different" `Quick test_signature_similarity_different;
      test_case "insufficient data" `Quick test_signature_similarity_insufficient_data;
    ];
    "reflection", [
      test_case "needs reflection" `Quick test_needs_reflection;
    ];
    (* v2.0 tests *)
    "temporal_decay", [
      test_case "now" `Quick test_reaction_weight_now;
      test_case "1 day" `Quick test_reaction_weight_1_day;
      test_case "10 days (half-life)" `Quick test_reaction_weight_10_days;
      test_case "30 days" `Quick test_reaction_weight_30_days;
    ];
    "calibration", [
      test_case "record and load" `Quick test_calibration_record_and_load;
      test_case "no data" `Quick test_avg_calibration_error_no_data;
      test_case "with data" `Quick test_avg_calibration_error_with_data;
    ];
    "dynamic_threshold", [
      test_case "no history" `Quick test_calibrated_threshold_no_history;
      test_case "well calibrated" `Quick test_calibrated_threshold_well_calibrated;
    ];
    "cosine_similarity_v2", [
      test_case "same affinities" `Quick test_cosine_similarity_same_affinities;
      test_case "different strengths" `Quick test_cosine_similarity_different_strengths;
    ];
  ]
