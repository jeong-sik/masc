open Alcotest

module H = Dashboard_harness_health

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

(* The reader capped an unfiltered read and did not cap a filtered one, so
   supplying a date — which narrows the request — removed the row bound and
   scanned every day-file in range. Both branches must read at most the same
   number of rows. The cap's value is deliberately not asserted here: the
   invariant is that a filter cannot widen the read. *)
let test_a_date_filter_does_not_remove_the_row_cap () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-cap" @@ fun dir ->
  H.set_wake_payload_store_for_testing ~base_dir:dir;
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
  H.set_wake_payload_store_for_testing ~base_dir:dir;
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
  H.set_wake_payload_store_for_testing ~base_dir:first_dir;
  ignore (record_wake_payload ~trace_id:"trace-first");
  H.reset_runtime_stores_for_testing ();
  H.set_wake_payload_store_for_testing ~base_dir:second_dir;
  ignore (record_wake_payload ~trace_id:"trace-second");
  match H.read_wake_payload_events () with
  | [ event ] -> check string "trace after reset" "trace-second" event.trace_id
  | events -> failf "expected rebound store to contain one event, got %d" (List.length events)

let test_wake_payload_reader_rejects_malformed_exact_records () =
  reset_after @@ fun () ->
  with_temp_dir "wake-payload-strict-reader" @@ fun dir ->
  H.set_wake_payload_store_for_testing ~base_dir:dir;
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
          test_case "a date filter does not remove the row cap" `Quick
            test_a_date_filter_does_not_remove_the_row_cap;
          test_case "wake payload reset rebinds store" `Quick
            test_reset_rebinds_wake_payload_store;
          test_case "malformed exact records are rejected" `Quick
            test_wake_payload_reader_rejects_malformed_exact_records;
        ] );
    ]
