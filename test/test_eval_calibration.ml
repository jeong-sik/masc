(** Tests for Eval_calibration — verdict logging, divergence analysis,
    and few-shot calibration example generation.

    All tests use temporary directories and Eio_main.run for
    Dated_jsonl mutex safety. *)

open Alcotest
module Cal = Masc.Eval_calibration
module AR = Masc.Task.Anti_rationalization

(* [select_examples] renders the rejected-label prose and
   [format_few_shot_block] the few-shot templates from
   config/prompts/eval.calibration.few_shot.md through the prompt registry.
   Pin resolution to the repo's own prompt files — the same idiom
   test_fusion_wake uses — so these paths render the real templates inside
   the dune sandbox instead of raising on a missing prompt. *)
let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/eval.calibration.few_shot.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let () =
  Prompt_registry.set_markdown_dir (Filename.concat (repo_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let test_counter = ref 0

let contains ~sub s =
  let ls = String.length sub and l = String.length s in
  if ls > l then false
  else
    let rec scan i =
      if i > l - ls then false
      else if String.sub s i ls = sub then true
      else scan (i + 1)
    in scan 0

let tmpdir () =
  incr test_counter;
  let dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "eval_cal_test_%d_%d_%d"
       (Unix.getpid ()) !test_counter
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let make_req ?(title = "Fix auth bug") ?(desc = "Fix the login issue")
    ?(notes = "Implemented JWT refresh token rotation") ?(agent = "alice") ()
  : AR.review_request =
  { task_title = title; task_description = desc;
    completion_notes = notes; agent_name = agent; task_id = "test-task-eval";
    evidence_refs = [] }

let make_result ?(verdict = AR.Approve "") ?(runtime = "verifier")
    ?gen_runtime ?(gate = AR.Structured_tool) ?fallback_reason () : AR.review_result =
  { verdict = Some verdict; evaluator_runtime = runtime;
    generator_runtime = gen_runtime; gate; fallback_reason;
      evaluator_error_retryable = None }

(* ================================================================ *)
(* Hashing tests                                                     *)
(* ================================================================ *)

let test_notes_hash_deterministic () =
  let h1 = Cal.notes_hash ~task_title:"t" ~notes:"n" in
  let h2 = Cal.notes_hash ~task_title:"t" ~notes:"n" in
  check string "same input -> same hash" h1 h2

let test_notes_hash_sensitive () =
  let h1 = Cal.notes_hash ~task_title:"t1" ~notes:"n" in
  let h2 = Cal.notes_hash ~task_title:"t2" ~notes:"n" in
  check bool "different input -> different hash" true (h1 <> h2)

let test_notes_hash_length () =
  let h = Cal.notes_hash ~task_title:"t" ~notes:"n" in
  check int "SHA256 hex = 64 chars" 64 (String.length h)

let expected_default_notes_hash =
  "1c82730a31bb70ffd25a1f14e8e6791aac785d8b7c56523313e3b994493b8666"

let test_notes_hash_known_vector () =
  check string "SHA256(title + newline + notes)" expected_default_notes_hash
    (Cal.notes_hash
       ~task_title:"Fix auth bug"
       ~notes:"Implemented JWT refresh token rotation")

(* ================================================================ *)
(* Record verdict tests                                              *)
(* ================================================================ *)

(* Both windowed readers capped their unfiltered branch and left the filtered
   one on [Dated_jsonl.read_range], which carries no row bound — so supplying a
   date, which narrows the request, removed the cap. [Dashboard_harness_health]
   passes user-supplied dates straight into [calibration_stats].

   The assertion is the invariant, not the constant: a date filter must not
   widen the read. Pinning 5000 would break on any future tuning of the bound
   and the test would stop being read. *)
let test_a_date_filter_does_not_remove_the_row_cap () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  Fun.protect ~finally:Cal.For_testing.reset_store (fun () ->
    Cal.record_verdict ~task_id:"cap-seed" ~req:(make_req ()) ~result:(make_result ()) ();
    (* Replicate the row the public API just wrote rather than hand-writing the
       record schema, so this test survives changes to that shape. *)
    let template =
      match Dated_jsonl.read_recent (Cal.get_store ()) 1 with
      | [ row ] -> Yojson.Safe.to_string row
      | _ -> fail "expected exactly one seeded record"
    in
    let seeded = 6000 in
    let store = Cal.get_store () in
    for _ = 1 to seeded do
      Dated_jsonl.append store (Yojson.Safe.from_string template)
    done;
    let total stats = Yojson.Safe.Util.(stats |> member "total_verdicts" |> to_int) in
    let unfiltered = total (Cal.calibration_stats ()) in
    let filtered = total (Cal.calibration_stats ~since:"2020-01-01" ()) in
    check bool "the unfiltered read is capped below what was seeded" true
      (unfiltered <= seeded);
    check int "a date filter reads no more than an unfiltered read" unfiltered
      filtered)

let test_record_verdict_writes () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"task-1" ~req ~result ();
  let store = Cal.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  check bool "at least 1 record written" true (List.length records >= 1);
  let first = List.hd records in
  let rt = Yojson.Safe.Util.(first |> member "record_type" |> to_string) in
  check string "record_type = verdict" "verdict" rt;
  Cal.For_testing.reset_store ()

let test_record_verdict_reject () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let req = make_req () in
  let result =
    make_result ~verdict:(AR.Reject "vague notes") ~gate:AR.Structured_tool ()
  in
  Cal.record_verdict ~task_id:"task-2" ~req ~result ();
  let store = Cal.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  let first = List.hd records in
  let v = Yojson.Safe.Util.(first |> member "verdict" |> to_string) in
  check string "verdict = reject:vague notes" "reject:vague notes" v;
  Cal.For_testing.reset_store ()

let test_record_verdict_hash_matches () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"task-3" ~req ~result ();
  let store = Cal.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  let first = List.hd records in
  let stored_hash = Yojson.Safe.Util.(first |> member "notes_hash" |> to_string) in
  check string "record stores the independently pinned hash"
    expected_default_notes_hash stored_hash;
  Cal.For_testing.reset_store ()

(* ================================================================ *)
(* Human label tests                                                 *)
(* ================================================================ *)

let test_record_human_label () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  Cal.record_human_label
    ~notes_hash:"abc123" ~human_verdict:Cal.Reject_label
    ~labeler:"vincent" ~reason:"work was incomplete";
  let store = Cal.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  let first = List.hd records in
  let rt = Yojson.Safe.Util.(first |> member "record_type" |> to_string) in
  let hv = Yojson.Safe.Util.(first |> member "human_verdict" |> to_string) in
  check string "record_type = label" "label" rt;
  check string "human_verdict = reject" "reject" hv;
  Cal.For_testing.reset_store ()

(* ================================================================ *)
(* Divergence analysis tests                                         *)
(* ================================================================ *)

let test_find_divergences_false_positive () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let req = make_req ~title:"FP task" ~notes:"looks ok but not" () in
  let result = make_result ~verdict:(AR.Approve "") ~gate:AR.Structured_tool () in
  Cal.record_verdict ~task_id:"t1" ~req ~result ();
  let hash = Cal.notes_hash ~task_title:"FP task" ~notes:"looks ok but not" in
  Cal.record_human_label
    ~notes_hash:hash ~human_verdict:Cal.Reject_label
    ~labeler:"vincent" ~reason:"did not address the task";
  let divs = Cal.find_divergences () in
  check int "1 divergence found" 1 (List.length divs);
  let d = List.hd divs in
  check string "evaluator approved" "approve"
    (Cal.verdict_to_string d.evaluator_verdict);
  check string "human rejected" "reject"
    (Cal.label_verdict_to_string d.human_verdict);
  Cal.For_testing.reset_store ()

let test_find_divergences_false_negative () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let req = make_req ~title:"FN task" ~notes:"actually good work" () in
  let result =
    make_result ~verdict:(AR.Reject "unclear") ~gate:AR.Structured_tool ()
  in
  Cal.record_verdict ~task_id:"t2" ~req ~result ();
  let hash = Cal.notes_hash ~task_title:"FN task" ~notes:"actually good work" in
  Cal.record_human_label
    ~notes_hash:hash ~human_verdict:Cal.Approve_label
    ~labeler:"vincent" ~reason:"";
  let divs = Cal.find_divergences () in
  check int "1 divergence found" 1 (List.length divs);
  let d = List.hd divs in
  check string "human approved" "approve"
    (Cal.label_verdict_to_string d.human_verdict);
  Cal.For_testing.reset_store ()

let test_find_divergences_agreement () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let req = make_req ~title:"OK task" ~notes:"done correctly" () in
  let result = make_result ~verdict:(AR.Approve "") () in
  Cal.record_verdict ~task_id:"t3" ~req ~result ();
  let hash = Cal.notes_hash ~task_title:"OK task" ~notes:"done correctly" in
  Cal.record_human_label
    ~notes_hash:hash ~human_verdict:Cal.Approve_label
    ~labeler:"vincent" ~reason:"";
  let divs = Cal.find_divergences () in
  check int "no divergences when agreement" 0 (List.length divs);
  Cal.For_testing.reset_store ()

let test_find_divergences_no_labels () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"t4" ~req ~result ();
  let divs = Cal.find_divergences () in
  check int "no divergences without labels" 0 (List.length divs);
  Cal.For_testing.reset_store ()

(* ================================================================ *)
(* Few-shot example tests                                            *)
(* ================================================================ *)

let test_select_examples_max () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  (* Create 3 false positives *)
  for i = 1 to 3 do
    let title = Printf.sprintf "task-%d" i in
    let notes = Printf.sprintf "notes-%d" i in
    let req = make_req ~title ~notes () in
    let result = make_result ~verdict:(AR.Approve "") () in
    Cal.record_verdict ~task_id:(Printf.sprintf "t%d" i) ~req ~result ();
    let hash = Cal.notes_hash ~task_title:title ~notes in
    Cal.record_human_label
      ~notes_hash:hash ~human_verdict:Cal.Reject_label
      ~labeler:"vincent" ~reason:"bad";
  done;
  let examples = Cal.select_examples ~max_examples:2 in
  check int "capped at max_examples" 2 (List.length examples);
  Cal.For_testing.reset_store ()

let test_select_examples_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  let examples = Cal.select_examples ~max_examples:5 in
  check int "empty when no data" 0 (List.length examples);
  Cal.For_testing.reset_store ()

let test_format_few_shot_block_empty () =
  let block = Cal.format_few_shot_block [] in
  check string "empty list -> empty string" "" block

let test_format_few_shot_block_nonempty () =
  let examples = [
    { Cal.task_title = "Fix auth";
      notes_excerpt = "done";
      correct_verdict = "REJECT: evaluator incorrectly approved" };
  ] in
  let block = Cal.format_few_shot_block examples in
  check bool "contains calibration header" true
    (contains ~sub:"calibration" block);
  check bool "contains task title" true
    (contains ~sub:"Fix auth" block)

(* ================================================================ *)
(* Statistics tests                                                  *)
(* ================================================================ *)

let test_calibration_stats () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  (* 2 approvals, 1 rejection *)
  let req1 = make_req ~title:"t1" ~notes:"n1" () in
  Cal.record_verdict ~task_id:"id1" ~req:req1
    ~result:(make_result ~verdict:(AR.Approve "") ~gate:AR.Structured_tool ()) ();
  let req2 = make_req ~title:"t2" ~notes:"n2" () in
  Cal.record_verdict ~task_id:"id2" ~req:req2
    ~result:(make_result ~verdict:(AR.Approve "") ~gate:AR.Structured_tool ()) ();
  let req3 = make_req ~title:"t3" ~notes:"n3" () in
  Cal.record_verdict ~task_id:"id3" ~req:req3
    ~result:(make_result ~verdict:(AR.Reject "bad") ~gate:AR.Structured_tool ()) ();
  let stats = Cal.calibration_stats () in
  let total = Yojson.Safe.Util.(stats |> member "total_verdicts" |> to_int) in
  let approves = Yojson.Safe.Util.(stats |> member "approve_count" |> to_int) in
  let rejects = Yojson.Safe.Util.(stats |> member "reject_count" |> to_int) in
  check int "total = 3" 3 total;
  check int "approves = 2" 2 approves;
  check int "rejects = 1" 1 rejects;
  (* None of the above passed ~gen_runtime, so the cross-model
     counters should be zero and the rate degenerate to 0.0. *)
  let with_gen =
    Yojson.Safe.Util.(stats |> member "verdicts_with_generator_runtime" |> to_int) in
  let cross_match =
    Yojson.Safe.Util.(stats |> member "cross_model_match_count" |> to_int) in
  let cross_rate =
    Yojson.Safe.Util.(stats |> member "cross_model_rate" |> to_number) in
  check int "verdicts_with_generator_runtime = 0 when not recorded" 0 with_gen;
  check int "cross_model_match_count = 0 when no generator" 0 cross_match;
  check (float 1e-6) "cross_model_rate = 0.0 when no generator" 0.0 cross_rate;
  Cal.For_testing.reset_store ()

let test_calibration_stats_cross_model_mix () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.For_testing.set_store ~base_dir:dir;
  Fun.protect ~finally:Cal.For_testing.reset_store @@ fun () ->
  (* Four verdicts:
     - same runtime (generator = evaluator)     → NOT cross-model
     - distinct runtime (generator ≠ evaluator) → cross-model
     - distinct runtime                          → cross-model
     - no generator recorded                     → excluded from denominator
     Expected: denominator=3, cross_match=2, rate=2/3 ≈ 0.667. *)
  let same_runtime =
    make_result ~runtime:"verifier" ~gen_runtime:"verifier" () in
  let cross_a =
    make_result ~runtime:"verifier" ~gen_runtime:"default-runtime-fixture" () in
  let cross_b =
    make_result ~runtime:"evaluator_runtime" ~gen_runtime:"local_only" () in
  let no_generator = make_result ~runtime:"verifier" () in
  let req = make_req () in
  Cal.record_verdict ~task_id:"cm1"
    ~req:(make_req ~title:"a" ~notes:"na" ()) ~result:same_runtime ();
  Cal.record_verdict ~task_id:"cm2"
    ~req:(make_req ~title:"b" ~notes:"nb" ()) ~result:cross_a ();
  Cal.record_verdict ~task_id:"cm3"
    ~req:(make_req ~title:"c" ~notes:"nc" ()) ~result:cross_b ();
  Cal.record_verdict ~task_id:"cm4" ~req ~result:no_generator ();
  let stats = Cal.calibration_stats () in
  let with_gen =
    Yojson.Safe.Util.(stats |> member "verdicts_with_generator_runtime" |> to_int) in
  let cross_match =
    Yojson.Safe.Util.(stats |> member "cross_model_match_count" |> to_int) in
  let cross_rate =
    Yojson.Safe.Util.(stats |> member "cross_model_rate" |> to_number) in
  check int "verdicts_with_generator_runtime = 3 (one was Null)" 3 with_gen;
  check int "cross_model_match_count = 2 (two distinct)" 2 cross_match;
  check (float 1e-3) "cross_model_rate approx 0.667" (2.0 /. 3.0) cross_rate

(* ================================================================ *)
(* AGENT_CORE Harness.verdict conversion tests (#3165)                      *)
(* ================================================================ *)



(* ================================================================ *)
(* Test Suite                                                        *)
(* ================================================================ *)

let () =
  run "eval_calibration" [
    "hashing", [
      test_case "deterministic" `Quick test_notes_hash_deterministic;
      test_case "sensitive" `Quick test_notes_hash_sensitive;
      test_case "length" `Quick test_notes_hash_length;
      test_case "known vector" `Quick test_notes_hash_known_vector;
    ];
    "record_verdict", [
      test_case "writes to store" `Quick test_record_verdict_writes;
      test_case "a date filter does not remove the row cap" `Quick
        test_a_date_filter_does_not_remove_the_row_cap;
      test_case "reject verdict" `Quick test_record_verdict_reject;
      test_case "hash matches" `Quick test_record_verdict_hash_matches;
    ];
    "human_label", [
      test_case "writes label" `Quick test_record_human_label;
    ];
    "divergences", [
      test_case "false positive" `Quick test_find_divergences_false_positive;
      test_case "false negative" `Quick test_find_divergences_false_negative;
      test_case "agreement" `Quick test_find_divergences_agreement;
      test_case "no labels" `Quick test_find_divergences_no_labels;
    ];
    "examples", [
      test_case "max cap" `Quick test_select_examples_max;
      test_case "empty" `Quick test_select_examples_empty;
      test_case "format empty" `Quick test_format_few_shot_block_empty;
      test_case "format nonempty" `Quick test_format_few_shot_block_nonempty;
    ];
    "stats", [
      test_case "counts" `Quick test_calibration_stats;
      test_case "cross_model mix" `Quick test_calibration_stats_cross_model_mix;
    ];
              ]
