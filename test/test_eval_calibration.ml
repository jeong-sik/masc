(** Tests for Eval_calibration — verdict logging, divergence analysis,
    and few-shot calibration example generation.

    All tests use temporary directories and Eio_main.run for
    Dated_jsonl mutex safety. *)

open Alcotest
module Cal = Masc.Eval_calibration
module AR = Masc.Task.Anti_rationalization

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

let make_result ?(verdict = AR.Approve) ?(runtime = "verifier")
    ?gen_runtime ?(gate = AR.Structured_tool) ?fallback_reason () : AR.review_result =
  { verdict = Some verdict; evaluator_runtime = runtime;
    generator_runtime = gen_runtime; gate; fallback_reason }

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

(* ================================================================ *)
(* Record verdict tests                                              *)
(* ================================================================ *)

let test_record_verdict_writes () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"task-1" ~req ~result ();
  let store = Cal.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  check bool "at least 1 record written" true (List.length records >= 1);
  let first = List.hd records in
  let rt = Yojson.Safe.Util.(first |> member "record_type" |> to_string) in
  check string "record_type = verdict" "verdict" rt;
  Cal.reset_store_for_testing ()

let test_record_verdict_reject () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
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
  Cal.reset_store_for_testing ()

(* Prove that [AR.review]'s [on_verdict] callback composes with
   [Cal.record_verdict] without requiring a live judge LLM. *)
let test_review_on_verdict_records () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Prompt_registry.set_markdown_dir
    (Filename.concat (Sys.getcwd ()) "config/prompts");
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let saved = Atomic.get AR.run_llm_reviewer_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set AR.run_llm_reviewer_fn saved;
      Cal.reset_store_for_testing ())
    (fun () ->
      (* Fake judge: a structured Reject, no live LLM. *)
      Atomic.set AR.run_llm_reviewer_fn
        (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
          Ok (Some (AR.Reject "fabricated evidence")));
      let req =
        make_req ~notes:"Implemented the change and verified it end to end." ()
      in
      let result =
        AR.review ~evaluator_runtime:"judge-runtime"
          ~generator_runtime:"keeper-runtime"
          ~on_verdict:(fun result ->
            Cal.record_verdict ~task_id:req.AR.task_id ~req ~result ())
          req
      in
      check bool "judge rejected" true
        (match result.AR.verdict with Some (AR.Reject _) -> true | _ -> false);
      let records = Dated_jsonl.read_recent (Cal.get_store ()) 10 in
      check bool "verdict recorded via on_verdict" true
        (List.length records >= 1);
      let v =
        Yojson.Safe.Util.(List.hd records |> member "verdict" |> to_string)
      in
      check string "recorded the fake judge's reject" "reject:fabricated evidence"
        v)

let test_record_verdict_hash_matches () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"task-3" ~req ~result ();
  let expected_hash = Cal.notes_hash
    ~task_title:req.task_title ~notes:req.completion_notes in
  let store = Cal.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  let first = List.hd records in
  let stored_hash = Yojson.Safe.Util.(first |> member "notes_hash" |> to_string) in
  check string "notes_hash matches" expected_hash stored_hash;
  Cal.reset_store_for_testing ()

(* ================================================================ *)
(* Human label tests                                                 *)
(* ================================================================ *)

let test_record_human_label () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
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
  Cal.reset_store_for_testing ()

(* ================================================================ *)
(* Divergence analysis tests                                         *)
(* ================================================================ *)

let test_find_divergences_false_positive () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let req = make_req ~title:"FP task" ~notes:"looks ok but not" () in
  let result = make_result ~verdict:AR.Approve ~gate:AR.Structured_tool () in
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
  Cal.reset_store_for_testing ()

let test_find_divergences_false_negative () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
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
  Cal.reset_store_for_testing ()

let test_find_divergences_agreement () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let req = make_req ~title:"OK task" ~notes:"done correctly" () in
  let result = make_result ~verdict:AR.Approve () in
  Cal.record_verdict ~task_id:"t3" ~req ~result ();
  let hash = Cal.notes_hash ~task_title:"OK task" ~notes:"done correctly" in
  Cal.record_human_label
    ~notes_hash:hash ~human_verdict:Cal.Approve_label
    ~labeler:"vincent" ~reason:"";
  let divs = Cal.find_divergences () in
  check int "no divergences when agreement" 0 (List.length divs);
  Cal.reset_store_for_testing ()

let test_find_divergences_no_labels () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"t4" ~req ~result ();
  let divs = Cal.find_divergences () in
  check int "no divergences without labels" 0 (List.length divs);
  Cal.reset_store_for_testing ()

(* ================================================================ *)
(* Few-shot example tests                                            *)
(* ================================================================ *)

let test_select_examples_max () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  (* Create 3 false positives *)
  for i = 1 to 3 do
    let title = Printf.sprintf "task-%d" i in
    let notes = Printf.sprintf "notes-%d" i in
    let req = make_req ~title ~notes () in
    let result = make_result ~verdict:AR.Approve () in
    Cal.record_verdict ~task_id:(Printf.sprintf "t%d" i) ~req ~result ();
    let hash = Cal.notes_hash ~task_title:title ~notes in
    Cal.record_human_label
      ~notes_hash:hash ~human_verdict:Cal.Reject_label
      ~labeler:"vincent" ~reason:"bad";
  done;
  let examples = Cal.select_examples ~max_examples:2 in
  check int "capped at max_examples" 2 (List.length examples);
  Cal.reset_store_for_testing ()

let test_select_examples_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let examples = Cal.select_examples ~max_examples:5 in
  check int "empty when no data" 0 (List.length examples);
  Cal.reset_store_for_testing ()

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
  Cal.set_store_for_testing ~base_dir:dir;
  (* 2 approvals, 1 rejection *)
  let req1 = make_req ~title:"t1" ~notes:"n1" () in
  Cal.record_verdict ~task_id:"id1" ~req:req1
    ~result:(make_result ~verdict:AR.Approve ~gate:AR.Structured_tool ()) ();
  let req2 = make_req ~title:"t2" ~notes:"n2" () in
  Cal.record_verdict ~task_id:"id2" ~req:req2
    ~result:(make_result ~verdict:AR.Approve ~gate:AR.Structured_tool ()) ();
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
  Cal.reset_store_for_testing ()

let test_calibration_stats_cross_model_mix () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  Fun.protect ~finally:Cal.reset_store_for_testing @@ fun () ->
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
    make_result ~runtime:"cross_verifier" ~gen_runtime:"local_only" () in
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
(* OAS Harness.verdict conversion tests (#3165)                      *)
(* ================================================================ *)

let test_to_harness_verdict_approve () =
  let record : Cal.verdict_record = {
    record_type = Cal.Verdict_record; notes_hash = "abc";
    task_id = "t1"; task_title = "Fix login";
    agent_name = "alice"; verdict = AR.Approve;
    gate = AR.Structured_tool; evaluator_runtime = "glm5";
    generator_runtime = Some "claude"; fallback_reason = None;
    timestamp = 0.0;
  } in
  let hv = Cal.to_harness_verdict record in
  check bool "passed" true hv.Agent_sdk.Harness.passed;
  check (option (float 0.01)) "score 1.0" (Some 1.0) hv.score;
  check bool "evidence has gate" true
    (List.exists (fun s -> contains ~sub:"gate=structured_tool" s) hv.evidence);
  check (option string) "no detail" None hv.detail

let test_to_harness_verdict_reject () =
  let record : Cal.verdict_record = {
    record_type = Cal.Verdict_record; notes_hash = "def";
    task_id = "t2"; task_title = "Deploy fix";
    agent_name = "bob"; verdict = AR.Reject "evaluator unavailable";
    gate = AR.Evaluator_unavailable; evaluator_runtime = "verifier";
    generator_runtime = None; fallback_reason = Some "evaluator unavailable";
    timestamp = 0.0;
  } in
  let hv = Cal.to_harness_verdict record in
  check bool "not passed" false hv.passed;
  check (option (float 0.01)) "score 0.0" (Some 0.0) hv.score;
  check bool "detail mentions gate" true
    (match hv.detail with
     | Some d -> contains ~sub:"evaluator_unavailable" d
     | None -> false)

let test_on_harness_verdict_callback () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let received = ref None in
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"cb-1" ~req ~result
    ~on_harness_verdict:(fun hv -> received := Some hv) ();
  (match !received with
   | None -> Alcotest.fail "on_harness_verdict not called"
   | Some hv ->
     check bool "passed" true hv.Agent_sdk.Harness.passed;
     check (option (float 0.01)) "score" (Some 1.0) hv.score);
  Cal.reset_store_for_testing ()

let test_on_harness_verdict_with_collector () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let collector = Agent_sdk.Eval.create_collector
    ~agent_name:"test-agent" ~run_id:"run-1" in
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"col-1" ~req ~result
    ~on_harness_verdict:(Agent_sdk.Eval.add_verdict collector) ();
  let metrics = Agent_sdk.Eval.finalize collector in
  check int "1 harness verdict" 1 (List.length metrics.harness_verdicts);
  let hv = List.hd metrics.harness_verdicts in
  check bool "passed" true hv.passed;
  Cal.reset_store_for_testing ()

let test_on_harness_verdict_exception_safe () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir () in
  Cal.set_store_for_testing ~base_dir:dir;
  let req = make_req () in
  let result = make_result () in
  Cal.record_verdict ~task_id:"exc-1" ~req ~result
    ~on_harness_verdict:(fun _hv -> failwith "boom") ();
  let store = Cal.get_store () in
  let records = Dated_jsonl.read_recent store 10 in
  check bool "record persisted despite callback failure" true
    (List.length records >= 1);
  Cal.reset_store_for_testing ()

(* ================================================================ *)
(* resolve_record_verdicts_store — verdict-store isolation guard     *)
(* ================================================================ *)

let live_store = "/live/base/data/verdicts"

let test_store_not_recording () =
  match
    Cal.resolve_record_verdicts_store ~record_verdicts:false
      ~verdict_store_dir:None ~live_store_dir:(Some live_store)
      ()
  with
  | Ok None -> ()
  | _ -> fail "expected Ok None when not recording"

let test_store_requires_dir () =
  (* --record-verdicts without an explicit store dir must error rather than
     silently fall back to the live store. *)
  match
    Cal.resolve_record_verdicts_store ~record_verdicts:true
      ~verdict_store_dir:None ~live_store_dir:(Some live_store)
      ()
  with
  | Error msg ->
    check bool "mentions --verdict-store-dir" true
      (contains ~sub:"--verdict-store-dir" msg)
  | Ok _ -> fail "expected Error when --record-verdicts lacks a store dir"

let test_store_rejects_empty_dir () =
  match
    Cal.resolve_record_verdicts_store ~record_verdicts:true
      ~verdict_store_dir:(Some "  ") ~live_store_dir:(Some live_store)
      ()
  with
  | Error msg -> check bool "mentions empty" true (contains ~sub:"empty" msg)
  | Ok _ -> fail "expected Error when --verdict-store-dir is empty"

let test_store_rejects_live () =
  (* Explicitly pointing the store at the live ledger must also error. *)
  match
    Cal.resolve_record_verdicts_store ~record_verdicts:true
      ~verdict_store_dir:(Some live_store) ~live_store_dir:(Some live_store)
      ()
  with
  | Error msg -> check bool "mentions live store" true (contains ~sub:"live" msg)
  | Ok _ -> fail "expected Error when store dir is the live store"

let test_store_rejects_live_aliases () =
  let cases = [
    "trailing slash", live_store ^ "/";
    "dot segment", "/live/base/data/./verdicts";
    "dotdot segment", "/live/base/data/tmp/../verdicts";
    "relative live path", "data/verdicts";
  ] in
  List.iter
    (fun (name, dir) ->
      match
        Cal.resolve_record_verdicts_store ~cwd:"/live/base"
          ~record_verdicts:true ~verdict_store_dir:(Some dir)
          ~live_store_dir:(Some live_store)
          ()
      with
      | Error msg ->
        check bool (name ^ " mentions live store") true (contains ~sub:"live" msg)
      | Ok _ -> fail (name ^ " should be rejected as a live-store alias"))
    cases

let test_store_rejects_live_alias_with_relative_base () =
  let cwd = tmpdir () in
  let base_path = Cal.absolute_workspace_base_path ~cwd "repo" in
  match
    Cal.resolve_record_verdicts_store ~cwd:base_path
      ~record_verdicts:true
      ~verdict_store_dir:(Some "data/verdicts")
      ~live_store_dir:(Some (Filename.concat base_path "data/verdicts"))
      ()
  with
  | Error msg ->
    check bool "mentions live store" true (contains ~sub:"live" msg);
    check bool "base path is absolute" false (Filename.is_relative base_path)
  | Ok _ ->
    fail
      "expected relative --base plus relative live verdict dir to be rejected"

let test_store_rejects_live_child () =
  let child = Filename.concat live_store "eval-scratch" in
  match
    Cal.resolve_record_verdicts_store ~record_verdicts:true
      ~verdict_store_dir:(Some child) ~live_store_dir:(Some live_store)
      ()
  with
  | Error msg -> check bool "mentions live store" true (contains ~sub:"live" msg)
  | Ok _ -> fail "expected Error when store dir is under the live store"

let test_store_accepts_isolated () =
  let isolated = "/scratch/verdicts" in
  match
    Cal.resolve_record_verdicts_store ~record_verdicts:true
      ~verdict_store_dir:(Some isolated) ~live_store_dir:(Some live_store)
      ()
  with
  | Ok (Some d) -> check string "uses the isolated dir" isolated d
  | _ -> fail "expected Ok (Some isolated) for an isolated store dir"

let test_store_no_live_no_collision () =
  (* When MASC_BASE_PATH is unset there is no live store, so any explicit dir is
     accepted (even one that textually matches the would-be live path). *)
  match
    Cal.resolve_record_verdicts_store ~record_verdicts:true
      ~verdict_store_dir:(Some live_store) ~live_store_dir:None
      ()
  with
  | Ok (Some d) -> check string "accepts dir when no live store" live_store d
  | _ -> fail "expected Ok (Some _) when there is no live store to collide with"

(* ================================================================ *)
(* resolve_record_verdicts_evaluator — cross-model guard            *)
(* ================================================================ *)

let test_evaluator_not_recording_passthrough () =
  match
    Cal.resolve_record_verdicts_evaluator ~record_verdicts:false
      ~generator_runtime:"generator" ~evaluator_runtime:(Some " judge ")
      ~cross_verifier_runtime:None
  with
  | Ok (Some id) -> check string "passthrough" " judge " id
  | _ -> fail "expected non-recording path to preserve evaluator_runtime"

let test_evaluator_requires_cross_verifier () =
  match
    Cal.resolve_record_verdicts_evaluator ~record_verdicts:true
      ~generator_runtime:"generator" ~evaluator_runtime:None
      ~cross_verifier_runtime:None
  with
  | Error msg ->
    check bool "mentions cross_verifier" true (contains ~sub:"cross_verifier" msg)
  | Ok _ -> fail "expected Error when cross_verifier is missing"

let test_evaluator_rejects_default_same_as_generator () =
  match
    Cal.resolve_record_verdicts_evaluator ~record_verdicts:true
      ~generator_runtime:"local.json" ~evaluator_runtime:None
      ~cross_verifier_runtime:(Some " local.json ")
  with
  | Error msg ->
    check bool "mentions distinct" true (contains ~sub:"distinct" msg);
    check bool "mentions --runtime" true (contains ~sub:"--runtime" msg)
  | Ok _ -> fail "expected Error when default cross_verifier equals generator"

let test_evaluator_accepts_default_distinct_cross_verifier () =
  match
    Cal.resolve_record_verdicts_evaluator ~record_verdicts:true
      ~generator_runtime:"generator" ~evaluator_runtime:None
      ~cross_verifier_runtime:(Some "judge")
  with
  | Ok None -> ()
  | _ -> fail "expected Ok None for distinct default cross_verifier"

let test_evaluator_accepts_explicit_same_model_override () =
  match
    Cal.resolve_record_verdicts_evaluator ~record_verdicts:true
      ~generator_runtime:"local.json" ~evaluator_runtime:(Some " local.json ")
      ~cross_verifier_runtime:(Some "local.json")
  with
  | Ok (Some id) -> check string "trimmed explicit evaluator" "local.json" id
  | _ -> fail "expected explicit same-model evaluator override to be accepted"

let test_evaluator_rejects_empty_explicit_override () =
  match
    Cal.resolve_record_verdicts_evaluator ~record_verdicts:true
      ~generator_runtime:"generator" ~evaluator_runtime:(Some "  ")
      ~cross_verifier_runtime:(Some "judge")
  with
  | Error msg -> check bool "mentions empty" true (contains ~sub:"empty" msg)
  | Ok _ -> fail "expected Error for empty explicit evaluator runtime"

(* ================================================================ *)
(* Test Suite                                                        *)
(* ================================================================ *)

let () =
  run "eval_calibration" [
    "hashing", [
      test_case "deterministic" `Quick test_notes_hash_deterministic;
      test_case "sensitive" `Quick test_notes_hash_sensitive;
      test_case "length" `Quick test_notes_hash_length;
    ];
    "record_verdict", [
      test_case "writes to store" `Quick test_record_verdict_writes;
      test_case "reject verdict" `Quick test_record_verdict_reject;
      test_case "hash matches" `Quick test_record_verdict_hash_matches;
      test_case "review on_verdict records" `Quick test_review_on_verdict_records;
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
    "record_verdicts_store", [
      test_case "not recording -> none" `Quick test_store_not_recording;
      test_case "requires store dir" `Quick test_store_requires_dir;
      test_case "rejects empty store dir" `Quick test_store_rejects_empty_dir;
      test_case "rejects live store" `Quick test_store_rejects_live;
      test_case "rejects live store aliases" `Quick test_store_rejects_live_aliases;
      test_case "rejects relative-base live alias" `Quick
        test_store_rejects_live_alias_with_relative_base;
      test_case "rejects live store child" `Quick test_store_rejects_live_child;
      test_case "accepts isolated" `Quick test_store_accepts_isolated;
      test_case "no live store -> no collision" `Quick test_store_no_live_no_collision;
    ];
    "record_verdicts_evaluator", [
      test_case "not recording passthrough" `Quick test_evaluator_not_recording_passthrough;
      test_case "requires cross verifier" `Quick test_evaluator_requires_cross_verifier;
      test_case "rejects default same as generator" `Quick
        test_evaluator_rejects_default_same_as_generator;
      test_case "accepts default distinct cross verifier" `Quick
        test_evaluator_accepts_default_distinct_cross_verifier;
      test_case "accepts explicit same-model override" `Quick
        test_evaluator_accepts_explicit_same_model_override;
      test_case "rejects empty explicit override" `Quick
        test_evaluator_rejects_empty_explicit_override;
    ];
    "oas_conversion", [
      test_case "approve verdict" `Quick test_to_harness_verdict_approve;
      test_case "reject verdict" `Quick test_to_harness_verdict_reject;
    ];
    "oas_integration", [
      test_case "callback invoked" `Quick test_on_harness_verdict_callback;
      test_case "with Eval.collector" `Quick test_on_harness_verdict_with_collector;
      test_case "callback exception safe" `Quick test_on_harness_verdict_exception_safe;
    ];
  ]
