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

let with_base_path dir f =
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" dir;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_BASE_PATH" (Option.value previous ~default:""))
    f

let reset_after f =
  H.reset_runtime_stores_for_testing ();
  Fun.protect ~finally:H.reset_runtime_stores_for_testing f

let record_wake_payload ~trace_id =
  H.record_wake_payload
    ~keeper_name:"keeper-harness"
    ~trace_id
    ~turn_index:7
    ~context_window:4096
    ~system_prompt_bytes:10
    ~tool_schema_json_bytes:20
    ~message_content_bytes:70
    ~message_count:3
    ~role_counts:[ "user", 1; "assistant", 2 ]
    ~tool_count:4

(* A store nobody bound by hand opens where the workspace keeps its state.
   It used to open in the workspace's own [data/] folder, beside [.masc]. *)
let test_wake_payloads_live_under_the_masc_directory () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-home" @@ fun dir ->
  with_base_path dir @@ fun () ->
  ignore (record_wake_payload ~trace_id:"home");
  check int "the row is read back" 1 (List.length (H.read_wake_payload_events ()));
  check bool "the store is under .masc" true
    (Sys.is_directory (Filename.concat dir ".masc/keeper-wake-payload"));
  check bool "nothing is written beside .masc" false
    (Sys.file_exists (Filename.concat dir "data"))

(* The reader capped an unfiltered read and did not cap a filtered one, so
   supplying a date — which narrows the request — removed the row bound and
   scanned every day-file in range. Both branches must read at most the same
   number of rows. The cap's value is deliberately not asserted here: the
   invariant is that a filter cannot widen the read. *)
let test_a_date_filter_does_not_remove_the_row_cap () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-cap" @@ fun dir ->
  H.set_wake_payload_store_for_testing ~base_path:dir;
  let store = H.get_wake_payload_store () in
  ignore (record_wake_payload ~trace_id:"cap-seed");
  (* Copy the recorded row instead of hand-writing the schema, so this test
     does not need editing when the event shape changes. *)
  let template =
    match Dated_jsonl.read_recent store 1 with
    | [ row ] -> row
    | _ -> fail "expected exactly one seeded row"
  in
  let seeded = 600 in
  for _ = 1 to seeded do
    Dated_jsonl.append store template
  done;
  let unfiltered = List.length (H.read_wake_payload_events ()) in
  let filtered = List.length (H.read_wake_payload_events ~since:"2020-01-01" ()) in
  check bool "the unfiltered read is capped below what was seeded" true
    (unfiltered <= seeded);
  check int "a date filter reads no more than an unfiltered read" unfiltered
    filtered

let test_wake_payload_store_round_trip () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-store" @@ fun dir ->
  H.set_wake_payload_store_for_testing ~base_path:dir;
  ignore (H.get_wake_payload_store ());
  ignore (record_wake_payload ~trace_id:"trace-round-trip");
  match H.read_wake_payload_events () with
  | [ event ] ->
    check string "keeper" "keeper-harness" event.keeper_name;
    check string "trace" "trace-round-trip" event.trace_id;
    check int "turn index" 7 event.turn_index;
    check int "context window" 4096 event.context_window;
    check int "system prompt bytes" 10 event.system_prompt_bytes;
    check int "tool schema JSON bytes" 20 event.tool_schema_json_bytes;
    check int "message content bytes" 70 event.message_content_bytes;
    check int "tool count" 4 event.tool_count
  | events ->
    failf "expected one wake payload event, got %d" (List.length events)

let test_reset_rebinds_wake_payload_store () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-store-a" @@ fun first_dir ->
  with_temp_dir "wake-payload-store-b" @@ fun second_dir ->
  H.set_wake_payload_store_for_testing ~base_path:first_dir;
  ignore (record_wake_payload ~trace_id:"trace-first");
  H.reset_runtime_stores_for_testing ();
  H.set_wake_payload_store_for_testing ~base_path:second_dir;
  ignore (record_wake_payload ~trace_id:"trace-second");
  match H.read_wake_payload_events () with
  | [ event ] -> check string "trace after reset" "trace-second" event.trace_id
  | events -> failf "expected rebound store to contain one event, got %d" (List.length events)

let test_wake_payload_reader_rejects_malformed_exact_records () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-strict-reader" @@ fun dir ->
  H.set_wake_payload_store_for_testing ~base_path:dir;
  let valid_fields =
    [ "record_type", `String "wake_payload"
    ; "timestamp", `Float 1.0
    ; "keeper_name", `String "keeper-harness"
    ; "trace_id", `String "trace-strict-reader"
    ; "turn_index", `Int 7
    ; "context_window", `Int 4096
    ; "system_prompt_bytes", `Int 10
    ; "tool_schema_json_bytes", `Int 20
    ; "message_content_bytes", `Int 70
    ; "message_count", `Int 3
    ; "role_counts", `Assoc [ "user", `Int 1; "assistant", `Int 2 ]
    ; "tool_count", `Int 4
    ]
  in
  let replace key value fields =
    (key, value) :: List.remove_assoc key fields
  in
  let legacy_fields =
    valid_fields
    |> List.remove_assoc "tool_schema_json_bytes"
    |> List.remove_assoc "message_content_bytes"
    |> fun fields -> ("tool_defs_bytes", `Int 20) :: ("messages_bytes", `Int 70) :: fields
  in
  let malformed_records =
    [ `Assoc legacy_fields
    ; `Assoc (replace "system_prompt_bytes" (`String "10") valid_fields)
    ; `Assoc (replace "tool_count" (`Int (-1)) valid_fields)
    ; `Assoc (replace "role_counts" (`Assoc [ "user", `Int 1 ]) valid_fields)
    ; `Assoc
        (replace
           "role_counts"
           (`Assoc [ "user", `String "1" ])
           valid_fields)
    ]
  in
  List.iter
    (Dated_jsonl.append (H.get_wake_payload_store ()))
    malformed_records;
  check int
    "legacy, wrong numeric type, and partial role counts are rejected"
    0
    (List.length (H.read_wake_payload_events ()))

let sample_hash = String.concat "" (List.init 8 (fun _ -> "0123abcd"))

let test_model_identity_gaps_reach_the_dashboard_without_a_zero_rate () =
  with_temp_dir "harness-model-identities" @@ fun dir ->
  Calibration.For_testing.set_store ~base_path:dir;
  Fun.protect ~finally:Calibration.For_testing.reset_store @@ fun () ->
  let assert_observation ~verdict_count ~runtime_rate =
    let json = H.json () in
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
  Calibration.record_verdict ~task_id:"task-model-gap" ~req ~result ();
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
      ( "runtime_stores",
        [
          test_case "wake payload round trip" `Quick test_wake_payload_store_round_trip;
          test_case "wake payloads live under .masc" `Quick
            test_wake_payloads_live_under_the_masc_directory;
          test_case "a date filter does not remove the row cap" `Quick
            test_a_date_filter_does_not_remove_the_row_cap;
          test_case "wake payload reset rebinds store" `Quick
            test_reset_rebinds_wake_payload_store;
          test_case "malformed exact records are rejected" `Quick
            test_wake_payload_reader_rejects_malformed_exact_records;
        ] );
    ]
