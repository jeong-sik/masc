module UI = Masc_tui_types
module R = Masc.Librarian_continuity_report

let case ?(question = None) id : R.case =
  { id; question
  ; source = { trace_id = "source"; turn = 1; text = "The label is blue." }
  ; context =
      { keeper_name = "fixture"; trace_id = "later"; read_position = 1
      ; facts = []; unread = "There is a label." }
  }

let generation : R.generation =
  { request =
      { runtime_id = "fixture-runtime"; requested_model = "requested-model"
      ; prompt = { system = "fixture"; user = "fixture" }; prepared_requests = [] }
  ; response = { response_id = "response"; model = "actual-model"; text = "What color?" }
  }

let generated_question = R.Generated generation

let failed : R.failed_generation =
  { request = generation.request; error = "provider unavailable"; incomplete_response = None }

let judge_request id =
  R.judge_request ~endpoint:"https://judge.invalid/eval" ~model:"requested-judge"
    (case id) ~question:"What color?" ~answer:"Unknown."

let judgment id probability : R.judgment =
  { request = judge_request id; response_model = "actual-judge"
  ; request_body_sha256 = Agent_core_sha256.(to_hex (digest_string "request")); probability }

let report : R.t =
  { schema = R.schema; provenance = R.Synthetic; run_id = "measurement-fixture"; started_at = "2026-09-21T00:00:00Z"
  ; input_path = "synthetic.json"; input_sha256 = Agent_core_sha256.(to_hex (digest_string "input"))
  ; output_path = "result.json"; config_revision = "fixture"
  ; binary_commit = None; executable_sha256 = None
  ; samples =
      [ { R.case = case "not-started"; progress = R.Not_started }
      ; { R.case = case ~question:(Some "What color?") "question-ready";
          progress = R.Question_ready (R.Provided "What color?") }
      ; { R.case = case "answer-ready";
          progress = R.Answer_ready { question = generated_question; answer = generation } }
      ; { R.case = case "question-failed"; progress = R.Question_failed failed }
      ; { R.case = case "answer-failed"; progress = R.Answer_failed (generated_question, failed) }
      ; { R.case = case "judge-failed";
          progress = R.Judge_failed
            { question = generated_question; answer = generation
            ; failure = { request = judge_request "judge-failed"; error = "HTTP 503" } } }
      ; { R.case = case "zero";
          progress = R.Scored
            { question = generated_question; answer = generation; judgment = judgment "zero" 0. } }
      ; { R.case = case "one";
          progress = R.Scored
            { question = generated_question; answer = generation; judgment = judgment "one" 1. } } ]
  }

let envelope content =
  `Assoc [ "sha256", `String (Agent_core_sha256.(to_hex (digest_string content))); "bytes", `Int (String.length content)
         ; "content", `String content ]

let test_stage_counts () =
  let counts = UI.Measurement.counts report in
  Alcotest.(check int) "both boundary probabilities are scored" 2 counts.scored;
  Alcotest.(check int) "only explicit failures count as failures" 3 counts.failed;
  Alcotest.(check int) "question/answer ready are incomplete" 3 counts.incomplete

let decoded_report () =
  let content = Yojson.Safe.to_string (R.to_yojson report) in
  let sha256 = Agent_core_sha256.(to_hex (digest_string content)) in
  match UI.Measurement.decode_artifact ~sha256 (envelope content) with
  | Ok loaded -> loaded
  | Error detail -> Alcotest.fail detail

let test_artifact_integrity () =
  let content = Yojson.Safe.to_string (R.to_yojson report) in
  let sha256 = Agent_core_sha256.(to_hex (digest_string content)) in
  let actual = decoded_report () in
  let actual = match actual with UI.Measurement.Snapshot actual -> actual
    | UI.Measurement.Temporal _ -> Alcotest.fail "expected synthetic report" in
  Alcotest.(check string) "exact report" content
    (Yojson.Safe.to_string (R.to_yojson actual.report));
  let rejects label expected json =
    match UI.Measurement.decode_artifact ~sha256 json with
    | Error detail -> Alcotest.(check string) label expected detail
    | Ok _ -> Alcotest.fail ("accepted " ^ label) in
  rejects "missing fields identify malformed envelope"
    "Measurement artifact response requires sha256, bytes and content fields" (`Assoc []);
  let other_content = content ^ " " in
  let other_sha = Agent_core_sha256.(to_hex (digest_string other_content)) in
  rejects "another blob identifies its SHA"
    ("Measurement artifact SHA " ^ other_sha ^ " differs from requested " ^ sha256)
    (envelope other_content);
  let tampered = String.make (String.length content) 'x' in
  let tampered_sha = Agent_core_sha256.(to_hex (digest_string tampered)) in
  rejects "same length corruption identifies content SHA"
    ("Measurement artifact content hashes to " ^ tampered_sha ^ ", expected " ^ sha256)
    (`Assoc [ "sha256", `String sha256; "bytes", `Int (String.length content)
            ; "content", `String tampered ]);
  rejects "wrong length identifies declared and actual bytes"
    (Printf.sprintf "Measurement artifact declares -1 bytes but carries %d" (String.length content))
    (`Assoc [ "sha256", `String sha256; "bytes", `Int (-1); "content", `String content ]);
  let invalid = "not-json" in
  Alcotest.(check bool) "valid hash does not excuse malformed report" true
    (Result.is_error (UI.Measurement.decode_artifact ~sha256:(Agent_core_sha256.(to_hex (digest_string invalid))) (envelope invalid)))

let test_loaded_context_hashes () =
  let loaded = decoded_report () in
  let loaded = match loaded with UI.Measurement.Snapshot loaded -> loaded
    | UI.Measurement.Temporal _ -> Alcotest.fail "expected synthetic report" in
  let expected = List.map (fun (sample : R.sample) ->
    sample.case.id, "23b660be57ad4c147a8b4b9ad1f5e1eae2cd266393670083de249f8f1b128f74") report.samples in
  Alcotest.(check (list (pair string string)))
    "verified artifact carries context hashes for every sample" expected loaded.context_hashes

let test_stale_results () =
  let loaded = decoded_report () in
  let state = UI.create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.lanes_mode <- UI.Lanes_measurement_detail "selected";
  state.lane_run_detail_generation <- 2;
  let accept sha256 generation result =
    UI.accept_measurement_artifact state ~sha256 ~generation result in
  accept "selected" 1 (Ok loaded);
  accept "other" 2 (Ok loaded);
  Alcotest.(check bool) "late generations and other artifacts cannot populate detail"
    true (state.measurement_report = None);
  accept "selected" 2 (Ok loaded);
  Alcotest.(check bool) "selected result populates detail" true
    (state.measurement_report = Some loaded);
  accept "selected" 1 (Error "stale error");
  Alcotest.(check bool) "stale error cannot obscure current result" true
    (state.lane_run_detail_error = None);
  state.lanes_mode <- UI.Lanes_overview;
  accept "selected" 2 (Error "late after leave");
  Alcotest.(check bool) "leaving rejects late results" true
    (state.lane_run_detail_error = None);
  state.lanes_mode <- UI.Lanes_measurement_detail "selected";
  accept "selected" 2 (Error "missing artifact");
  Alcotest.(check (option string)) "current read failure remains visible"
    (Some "missing artifact") state.lane_run_detail_error

let test_temporal_observations () =
  let module T = Masc.Tui_decode_temporal_continuity in
  let sha = String.make 64 'a' in
  let range first_atom = `Assoc ["capture_id", `String "fixture-request";
    "body_sha256", `String sha; "first_atom", `Int first_atom; "summary_end_atom", `Int 5] in
  let omission first_atom = `Assoc ["status", `String "observed";
    "target_boundary", `Assoc ["end_atom", `Int 5]; "requests", `List [range first_atom]] in
  let step ~w ~omitted ~probability ~model = `Assoc [
    "step_id", `String "probe"; "kind", `String "message"; "status", `String "captured";
    "operation_state", `String "Succeeded"; "turn_ref", `String "trace#12";
    "working_state_messages", w; "reply", `List [`String "The corrected observation continues."];
    "working_state", (match w with `Null -> `Null | `Int 0 -> `List [] | _ -> `List [`Assoc []]);
    "prefix_omission", omitted; "target_boundary", `Null;
    "judgments", `List [`Assoc ["criterion_id", `String "latest correction";
      "scope", `String "reply"; "status", `String "measured";
      "probability", probability; "response_model", model]]] in
  let view ?(passed = `Null) row = `Assoc [
    "schema", `String T.schema; "keeper", `String "fixture";
    "provenance", `String "assessment_of_captured_keeper_evidence";
    "measurement_status", `String "incomplete"; "error", `String "later observation unavailable";
    "started_at", `String "2026-10-30T00:00:00Z"; "finished_at", `Null;
    "report_path", `String "/private/report.json"; "report_sha256", `String sha;
    "harness_source_sha256", `String sha; "source_capture_sha256", `String sha;
    "binary_commit", `Null; "executable_sha256", `Null;
    "body_response_binding", `String "not_established";
    "librarian_causal_attribution", `String "not_established";
    "continuity_pass", passed; "timeline", `List [row]] in
  let row = step ~w:`Null ~omitted:(omission 5) ~probability:(`Float 0.) ~model:(`String "actual-judge") in
  let content = Yojson.Safe.to_string (view row) in
  let sha256 = Agent_core_sha256.(to_hex (digest_string content)) in
  (match UI.Measurement.decode_artifact ~sha256 (envelope content) with
   | Ok (UI.Measurement.Temporal loaded) ->
     Alcotest.(check bool) "incomplete capture remains incomplete" true (loaded.status = T.Incomplete);
     (match loaded.timeline with
      | [{working_state_messages = None; omission = T.Observed detail;
          judgments = [{result = T.Measured {probability = 0.; model = "actual-judge"}; _}]; _}] ->
        Alcotest.(check int) "exclusive target end retained" 5 detail.target_end_atom
      | _ -> Alcotest.fail "lost unknown W, exact cut or raw boundary probability")
   | Ok _ -> Alcotest.fail "expected temporal view" | Error detail -> Alcotest.fail detail);
  let rejects label json = Alcotest.(check bool) label true (Result.is_error (T.of_yojson json)) in
  rejects "report does not certify pass" (view ~passed:(`Bool true) row);
  rejects "earlier request cannot certify omission"
    (view (step ~w:(`Int 1) ~omitted:(omission 4) ~probability:(`Float 1.) ~model:(`String "actual")));
  rejects "measured probability requires actual model"
    (view (step ~w:(`Int 0) ~omitted:`Null ~probability:(`Float 0.5) ~model:`Null));
  rejects "probability is a bounded raw observation"
    (view (step ~w:`Null ~omitted:`Null ~probability:(`Float 1.1) ~model:(`String "actual")))

let () =
  Alcotest.run "TUI measurement artifacts"
    [ "reader", [ Alcotest.test_case "incomplete is not failed or scored" `Quick test_stage_counts
                ; Alcotest.test_case "SHA bytes and typed report" `Quick test_artifact_integrity
                ; Alcotest.test_case "context hashes are derived at load" `Quick test_loaded_context_hashes
                ; Alcotest.test_case "late results cannot retarget detail" `Quick test_stale_results
                ; Alcotest.test_case "temporal evidence retains uncertainty" `Quick test_temporal_observations ] ]
