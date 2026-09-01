(* Evidence JSON schema for the keeper canary harness (masc, task-11, M1
   PR1). Pins the field shape a follow-up judge/promote PR and the
   dashboard will read — see lib/keeper_canary/keeper_canary_evidence.ml
   for the module under test. *)

open Masc

let sample_fact : Keeper_canary_facts.fact =
  { category = "project_codename"; statement = "The project codename is X."; value = "X" }

let sample_score : Keeper_canary_facts.score =
  { facts_total = 1
  ; facts_recalled = 1
  ; order_matches = true
  ; recalled_categories = [ "project_codename" ]
  ; missing_categories = []
  ; per_fact =
      [ { category = "project_codename"; value = "X"; recalled = true; first_index = Some 0 } ]
  }

let sample_turn : Keeper_canary_evidence.turn_evidence =
  { index = 1
  ; category = Some "project_codename"
  ; delivery_key = Some (`Assoc [ ("kind", `String "operation"); ("operation_id", `String "canary-1") ])
  ; turn_ref = Some "trace-abc#1"
  ; sent_at = "2026-08-16T00:00:00Z"
  ; round_trip_s = 1.5
  ; reply_digest = Some "deadbeef"
  }

let sample_recall_turn : Keeper_canary_evidence.turn_evidence =
  { sample_turn with index = 2; category = None; turn_ref = Some "trace-abc#2" }

let sample_evidence : Keeper_canary_evidence.run_evidence =
  { captured_at = "2026-08-16T00:00:05Z"
  ; harness_git_commit = Some "deadbeef"
  ; run_id = "run-sample"
  ; keeper_name = "canary-test"
  ; runtime = Some "ollama-local"
  ; base_path = "/tmp/masc-base"
  ; endpoint = "http://127.0.0.1:8935/api/v1/keepers/chat/stream"
  ; turn_interval_s = 0.0
  ; wall_clock_target_s = None
  ; facts = [ sample_fact ]
  ; turns = [ sample_turn; sample_recall_turn ]
  ; recall =
      { turn_index = 2
      ; request_id = "canary-2"
      ; prompt = Keeper_canary_facts.recall_prompt ()
      ; reply = "X"
      }
  ; timing = { min_s = 1.0; median_s = 1.25; max_s = 1.5 }
  ; deterministic_signal = sample_score
  ; judgment = None
  ; injections = []
  ; serving = None
  ; notes = []
  }

let member key = function
  | `Assoc fields -> List.assoc key fields
  | _ -> Alcotest.fail (Printf.sprintf "expected an object looking up %s" key)

let as_string = function
  | `String s -> s
  | _ -> Alcotest.fail "expected a JSON string"

let as_list = function
  | `List items -> items
  | _ -> Alcotest.fail "expected a JSON list"

let test_schema_field_matches_declared_version () =
  let json = Keeper_canary_evidence.to_yojson sample_evidence in
  Alcotest.(check string)
    "schema"
    Keeper_canary_evidence.schema_version
    (json |> member "schema" |> as_string)

let test_top_level_keys_are_present () =
  let json = Keeper_canary_evidence.to_yojson sample_evidence in
  let expected =
    [ "schema"
    ; "captured_at"
    ; "harness"
    ; "run_id"
    ; "keeper"
    ; "transport"
    ; "facts_established"
    ; "turns"
    ; "recall"
    ; "timing"
    ; "deterministic_signal"
    ; "judgment"
    ; "injections"
    ; "serving"
    ; "notes"
    ]
  in
  match json with
  | `Assoc fields ->
    let actual = List.map fst fields in
    List.iter
      (fun key ->
         Alcotest.(check bool)
           (Printf.sprintf "top-level key %s present" key)
           true
           (List.mem key actual))
      expected
  | _ -> Alcotest.fail "expected a JSON object"

let test_wall_clock_target_serializes_when_present () =
  let json =
    Keeper_canary_evidence.to_yojson
      { sample_evidence with wall_clock_target_s = Some 3600.0 }
  in
  (match json |> member "transport" |> member "wall_clock_target_s" with
   | `Float s -> Alcotest.(check (float 1e-9)) "target seconds" 3600.0 s
   | _ -> Alcotest.fail "expected transport.wall_clock_target_s to serialize as a float");
  match
    Keeper_canary_evidence.to_yojson sample_evidence
    |> member "transport"
    |> member "wall_clock_target_s"
  with
  | `Null -> ()
  | _ -> Alcotest.fail "expected transport.wall_clock_target_s to be null when unset"

let sample_restart : Keeper_canary_evidence.restart_injection =
  { after_turn = 5
  ; started_at = "2026-08-16T00:00:03Z"
  ; duration_s = 4.5
  ; trace_id_before = "trace-abc"
  ; trace_id_after = "trace-abc"
  ; generation_before = 1
  ; generation_after = 1
  }

let test_injection_serializes_with_continuation () =
  let json =
    Keeper_canary_evidence.to_yojson
      { sample_evidence with
        injections = [ Keeper_canary_evidence.Restart sample_restart ]
      }
  in
  (match json |> member "injections" with
   | `List [ `Assoc kvs ] ->
     Alcotest.(check string)
       "kind" "restart"
       (match List.assoc "kind" kvs with `String s -> s | _ -> "?");
     Alcotest.(check bool)
       "continuation derived true" true
       (match List.assoc "continuation" kvs with `Bool b -> b | _ -> false)
   | _ -> Alcotest.fail "expected one injection object");
  (* Identity loss must read as continuation=false. *)
  let broken = { sample_restart with trace_id_after = "trace-xyz" } in
  Alcotest.(check bool)
    "changed trace_id is not a continuation"
    false
    (Keeper_canary_evidence.restart_is_continuation broken);
  let bumped = { sample_restart with generation_after = 2 } in
  Alcotest.(check bool)
    "bumped generation is not a continuation"
    false
    (Keeper_canary_evidence.restart_is_continuation bumped)

let test_failover_injection_serializes () =
  let attempt : Keeper_canary_failover.attempt =
    { ts = "2026-08-16T00:00:04Z"
    ; keeper_turn_id = Some 7
    ; event = Keeper_canary_failover.Failed
    ; runtime_id = "llama_cpp.local-head"
    ; error_kind = Some (Keeper_canary_failover.error_kind_of_wire "provider_unreachable")
    }
  in
  let failover : Keeper_canary_evidence.failover_injection =
    { after_turn = 2
    ; started_at = "2026-08-16T00:00:03Z"
    ; duration_s = 0.2
    ; down_cmd = "kill-head"
    ; up_cmd = Some "start-head"
    ; window_start = "2026-08-16T00:00:03Z"
    ; mode = Keeper_canary_failover.In_turn
    ; attempts = [ attempt ]
    }
  in
  let json =
    Keeper_canary_evidence.to_yojson
      { sample_evidence with injections = [ Keeper_canary_evidence.Failover failover ] }
  in
  match json |> member "injections" with
  | `List [ `Assoc kvs ] ->
    Alcotest.(check string)
      "kind" "failover"
      (match List.assoc "kind" kvs with `String s -> s | _ -> "?");
    Alcotest.(check string)
      "mode" "in_turn"
      (match List.assoc "mode" kvs with `String s -> s | _ -> "?");
    (match List.assoc "attempts" kvs with
     | `List [ `Assoc attempt_kvs ] ->
       Alcotest.(check string)
         "attempt event" "failed"
         (match List.assoc "event" attempt_kvs with `String s -> s | _ -> "?")
     | _ -> Alcotest.fail "expected one attempt row")
  | _ -> Alcotest.fail "expected one injection object"

let test_injections_empty_by_default () =
  match Keeper_canary_evidence.to_yojson sample_evidence |> member "injections" with
  | `List [] -> ()
  | _ -> Alcotest.fail "expected empty injections list"

let test_judgment_is_null_without_a_judge () =
  let json = Keeper_canary_evidence.to_yojson sample_evidence in
  match json |> member "judgment" with
  | `Null -> ()
  | _ -> Alcotest.fail "expected judgment to be JSON null when no judge ran"

let test_judgment_serializes_when_present () =
  let judgment =
    match
      Keeper_canary_judge.parse_reply
        ~judge_runtime:"rt.judge-test"
        ~facts:[ sample_fact ]
        {|{"per_fact": [{"category": "project_codename", "recalled": true}], "rationale": "value present"}|}
    with
    | Ok j -> j
    | Error msg -> Alcotest.failf "fixture judgment failed to parse: %s" msg
  in
  let json =
    Keeper_canary_evidence.to_yojson { sample_evidence with judgment = Some judgment }
  in
  match json |> member "judgment" with
  | `Assoc kvs ->
    Alcotest.(check bool) "judge_runtime present" true (List.mem_assoc "judge_runtime" kvs);
    Alcotest.(check bool) "all_recalled present" true (List.mem_assoc "all_recalled" kvs)
  | _ -> Alcotest.fail "expected judgment to serialize as an object when present"

let test_run_id_round_trips () =
  let json = Keeper_canary_evidence.to_yojson sample_evidence in
  Alcotest.(check string) "run_id" "run-sample" (json |> member "run_id" |> as_string)

let test_turns_array_has_two_entries_with_indices_1_and_2 () =
  let json = Keeper_canary_evidence.to_yojson sample_evidence in
  let turns = json |> member "turns" |> as_list in
  Alcotest.(check int) "two turns" 2 (List.length turns);
  let indices =
    List.map
      (fun t -> match member "index" t with `Int i -> i | _ -> Alcotest.fail "expected int index")
      turns
  in
  Alcotest.(check (list int)) "indices" [ 1; 2 ] indices

let test_turn_category_none_becomes_null () =
  let json = Keeper_canary_evidence.to_yojson sample_evidence in
  let recall_turn = List.nth (json |> member "turns" |> as_list) 1 in
  match member "category" recall_turn with
  | `Null -> ()
  | _ -> Alcotest.fail "expected the recall turn's category to be JSON null"

let test_runtime_none_becomes_null_under_keeper () =
  let evidence = { sample_evidence with runtime = None } in
  let json = Keeper_canary_evidence.to_yojson evidence in
  match json |> member "keeper" |> member "runtime" with
  | `Null -> ()
  | _ -> Alcotest.fail "expected null runtime when runtime is None"

let test_timing_fields_are_present () =
  let json = Keeper_canary_evidence.to_yojson sample_evidence in
  let timing = json |> member "timing" in
  match member "min_s" timing, member "median_s" timing, member "max_s" timing with
  | `Float 1.0, `Float 1.25, `Float 1.5 -> ()
  | _ -> Alcotest.fail "expected timing.{min_s,median_s,max_s} to round-trip"

let serialized_harness_git_commit resolution =
  Keeper_canary_evidence.to_yojson
    { sample_evidence with
      harness_git_commit = resolution.Build_identity.binary_commit
    }
  |> member "harness"
  |> member "git_commit"

let test_harness_commit_uses_embedded_binary_identity () =
  let resolution =
    Build_identity.resolve_commit_details
      ~embedded:(Some "embedded-canary-source")
      ~probe:(fun () -> Some "ambient-checkout-head")
  in
  Alcotest.(check string)
    "serialized harness commit is the embedded binary source"
    "embedded-canary-source"
    (serialized_harness_git_commit resolution |> as_string)

let test_harness_commit_is_null_without_build_stamp () =
  let resolution =
    Build_identity.resolve_commit_details
      ~embedded:None
      ~probe:(fun () -> Some "ambient-checkout-head")
  in
  Alcotest.(check bool)
    "ambient checkout does not populate harness identity"
    true
    (serialized_harness_git_commit resolution = `Null)

let test_pretty_string_is_parseable_json () =
  let text = Keeper_canary_evidence.to_pretty_string sample_evidence in
  match Yojson.Safe.from_string text with
  | _ -> ()
  | exception _ -> Alcotest.fail "to_pretty_string did not produce valid JSON"

let test_timing_of_empty_list_is_all_zero () =
  let t = Keeper_canary_evidence.timing_of [] in
  Alcotest.(check bool) "zeroed" true (t.min_s = 0.0 && t.median_s = 0.0 && t.max_s = 0.0)

let test_timing_of_single_value () =
  let t = Keeper_canary_evidence.timing_of [ 2.5 ] in
  Alcotest.(check bool) "min = max = median = the one value" true (t.min_s = 2.5 && t.median_s = 2.5 && t.max_s = 2.5)

let test_timing_of_odd_count_median_is_middle_element () =
  let t = Keeper_canary_evidence.timing_of [ 3.0; 1.0; 2.0 ] in
  Alcotest.(check (float 0.0001)) "min" 1.0 t.min_s;
  Alcotest.(check (float 0.0001)) "median" 2.0 t.median_s;
  Alcotest.(check (float 0.0001)) "max" 3.0 t.max_s

let test_timing_of_even_count_median_averages_middle_two () =
  let t = Keeper_canary_evidence.timing_of [ 4.0; 1.0; 2.0; 3.0 ] in
  Alcotest.(check (float 0.0001)) "min" 1.0 t.min_s;
  Alcotest.(check (float 0.0001)) "median" 2.5 t.median_s;
  Alcotest.(check (float 0.0001)) "max" 4.0 t.max_s

let () =
  Alcotest.run
    "keeper_canary_evidence"
    [ ( "to_yojson"
      , [ Alcotest.test_case
            "schema field matches declared version"
            `Quick
            test_schema_field_matches_declared_version
        ; Alcotest.test_case "top-level keys are present" `Quick test_top_level_keys_are_present
        ; Alcotest.test_case
            "wall clock target serializes"
            `Quick
            test_wall_clock_target_serializes_when_present
        ; Alcotest.test_case
            "injection serializes with continuation"
            `Quick
            test_injection_serializes_with_continuation
        ; Alcotest.test_case
            "failover injection serializes"
            `Quick
            test_failover_injection_serializes
        ; Alcotest.test_case
            "injections empty by default"
            `Quick
            test_injections_empty_by_default
        ; Alcotest.test_case
            "judgment is null without a judge"
            `Quick
            test_judgment_is_null_without_a_judge
        ; Alcotest.test_case
            "judgment serializes when present"
            `Quick
            test_judgment_serializes_when_present
        ; Alcotest.test_case "run_id round-trips" `Quick test_run_id_round_trips
        ; Alcotest.test_case
            "turns array has two entries with indices 1 and 2"
            `Quick
            test_turns_array_has_two_entries_with_indices_1_and_2
        ; Alcotest.test_case
            "turn category None becomes null"
            `Quick
            test_turn_category_none_becomes_null
        ; Alcotest.test_case
            "runtime None becomes null under keeper"
            `Quick
            test_runtime_none_becomes_null_under_keeper
        ; Alcotest.test_case "timing fields are present" `Quick test_timing_fields_are_present
        ; Alcotest.test_case
            "harness commit uses embedded binary identity"
            `Quick
            test_harness_commit_uses_embedded_binary_identity
        ; Alcotest.test_case
            "harness commit is null without build stamp"
            `Quick
            test_harness_commit_is_null_without_build_stamp
        ] )
    ; ( "to_pretty_string"
      , [ Alcotest.test_case "is parseable JSON" `Quick test_pretty_string_is_parseable_json ] )
    ; ( "timing_of"
      , [ Alcotest.test_case "empty list is all zero" `Quick test_timing_of_empty_list_is_all_zero
        ; Alcotest.test_case "single value" `Quick test_timing_of_single_value
        ; Alcotest.test_case
            "odd count median is the middle element"
            `Quick
            test_timing_of_odd_count_median_is_middle_element
        ; Alcotest.test_case
            "even count median averages the middle two"
            `Quick
            test_timing_of_even_count_median_averages_middle_two
        ] )
    ]
