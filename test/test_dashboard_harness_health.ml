open Alcotest

module H = Dashboard_harness_health
module Calibration = Masc.Eval_calibration
module Review = Masc.Task.Anti_rationalization

let temp_dir_counter = ref 0

let with_temp_dir prefix f =
  incr temp_dir_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s-%d-%06d"
         prefix
         (Unix.getpid ())
         !temp_dir_counter)
  in
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path
      then (
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path)
      else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let sample_hash = String.concat "" (List.init 8 (fun _ -> "0123abcd"))

let test_model_identity_gaps_reach_the_dashboard_without_a_zero_rate () =
  with_temp_dir "harness-model-identities" @@ fun dir ->
  let assert_observation ~verdict_count ~runtime_rate =
    let json = H.json ~base_path:dir () in
    let overview = Yojson.Safe.Util.member "overview" json in
    let calibration = Yojson.Safe.Util.member "calibration" json in
    let observation = Yojson.Safe.Util.member "model_identity_observation" overview in
    check int "no complete model pair was observed" 0
      Yojson.Safe.Util.(observation |> member "observed_verdict_count" |> to_int);
    check int "the missing coverage reaches the overview" verdict_count
      Yojson.Safe.Util.(observation |> member "unobserved_verdict_count" |> to_int);
    check bool "the overview preserves the ledger's nullable runtime rate" true
      (Yojson.Safe.Util.member "distinct_runtime_rate" overview = runtime_rate);
    check bool "the ledger and overview retain the same identity observation" true
      (observation = Yojson.Safe.Util.member "model_identity_observation" calibration);
    check bool "the obsolete model-rate claim is absent" false
      (List.mem_assoc "cross_model_rate" (Yojson.Safe.Util.to_assoc overview))
  in
  assert_observation ~verdict_count:0 ~runtime_rate:`Null;
  let req : Review.review_request =
    { task_title = "bound output"; task_description = "review"; task_id = "task-model-gap"
    ; completion_notes = "filed"; agent_name = "producer"; evidence_refs = []; evidence_images = [] } in
  let result : Review.review_result =
    { verdict = Some (Review.Approve "")
    ; evaluator_runtime = "judge-alias"; generator_runtime = Some "producer-alias"
    ; evaluator_execution = None
    ; gate = Review.Structured_tool; fallback_reason = None
    ; retryable_runtimes = []; model_absent_runtimes = [] } in
  Calibration.record_verdict ~base_path:dir ~task_id:"task-model-gap" ~req ~result ();
  assert_observation ~verdict_count:1 ~runtime_rate:(`Float 1.0)

let test_label_body_approve_parses () =
  match
    Dashboard_harness_health.parse_label_body
      (Printf.sprintf
         {|{"notes_hash": "%s", "verdict": "approve", "reason": ""}|}
         sample_hash)
  with
  | Ok { label_notes_hash; label_verdict; label_reason } ->
      Alcotest.(check string) "hash" sample_hash label_notes_hash;
      Alcotest.(check bool) "approve side" true
        (match label_verdict with
         | Masc.Eval_calibration.Approve_label -> true
         | Masc.Eval_calibration.Reject_label -> false);
      Alcotest.(check string) "reason" "" label_reason
  | Error e -> Alcotest.failf "expected Ok, got: %s" e

let test_label_body_reject_parses () =
  match
    Dashboard_harness_health.parse_label_body
      (Printf.sprintf
         {|{"notes_hash": "%s", "verdict": "reject", "reason": " evidence was sufficient "}|}
         sample_hash)
  with
  | Ok { label_verdict; label_reason; _ } ->
      Alcotest.(check bool) "reject side" true
        (match label_verdict with
         | Masc.Eval_calibration.Reject_label -> true
         | Masc.Eval_calibration.Approve_label -> false);
      Alcotest.(check string) "reason trimmed" "evidence was sufficient"
        label_reason
  | Error e -> Alcotest.failf "expected Ok, got: %s" e

let test_label_body_bad_hash_refused () =
  match
    Dashboard_harness_health.parse_label_body
      {|{"notes_hash": "SHOUTY", "verdict": "approve", "reason": ""}|}
  with
  | Ok _ -> Alcotest.fail "a malformed hash must be refused"
  | Error e ->
      Alcotest.(check bool) "names the hash rule" true
        (Astring.String.is_infix ~affix:"hex" e)

let test_label_body_unknown_verdict_refused () =
  match
    Dashboard_harness_health.parse_label_body
      (Printf.sprintf
         {|{"notes_hash": "%s", "verdict": "maybe", "reason": ""}|}
         sample_hash)
  with
  | Ok _ -> Alcotest.fail "an unknown verdict word must be refused"
  | Error e ->
      Alcotest.(check bool) "names the vocabulary" true
        (Astring.String.is_infix ~affix:"approve" e)

let () =
  Eio_main.run @@ fun _env ->
  run
    "dashboard_harness_health"
    [
      ( "model_identity",
        [ test_case "identity gaps reach the dashboard without a zero rate" `Quick
            test_model_identity_gaps_reach_the_dashboard_without_a_zero_rate ] );
      ( "operator_labels",
        [
          test_case "a well-formed approve label parses" `Quick
            test_label_body_approve_parses;
          test_case "a reject label parses with its reason" `Quick
            test_label_body_reject_parses;
          test_case "a malformed notes hash is refused" `Quick
            test_label_body_bad_hash_refused;
          test_case "an unknown verdict word is refused" `Quick
            test_label_body_unknown_verdict_refused;
        ] );
    ]
