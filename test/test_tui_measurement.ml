module UI = Masc_tui_types
module R = Masc.Librarian_continuity_report

let case : R.case =
  { id = "synthetic"
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

let failed : R.failed_generation =
  { request = generation.request; error = "provider unavailable"; incomplete_response = None }

let judge_request =
  R.judge_request ~endpoint:"https://judge.invalid/eval" ~model:"requested-judge"
    case ~question:"What color?" ~answer:"Unknown."

let judgment probability : R.judgment =
  { request = judge_request; response_model = "actual-judge"
  ; request_body_sha256 = R.sha256 "request"; probability }

let report : R.t =
  { schema = R.schema; run_id = "measurement-fixture"; started_at = "2026-09-21T00:00:00Z"
  ; input_path = "synthetic.json"; input_sha256 = R.sha256 "input"
  ; output_path = "result.json"; config_revision = "fixture"
  ; binary_commit = None; executable_sha256 = None
  ; samples =
      List.mapi (fun index progress ->
        { R.case = { case with id = string_of_int index }; progress })
        [ R.Not_started; R.Question_ready generation; R.Answer_ready (generation, generation)
        ; R.Question_failed failed; R.Answer_failed (generation, failed)
        ; R.Judge_failed (generation, generation, { request = judge_request; error = "HTTP 503" })
        ; R.Scored (generation, generation, judgment 0.)
        ; R.Scored (generation, generation, judgment 1.) ]
  }

let envelope content =
  `Assoc [ "sha256", `String (R.sha256 content); "bytes", `Int (String.length content)
         ; "content", `String content ]

let test_stage_counts () =
  let counts = UI.Measurement.counts report in
  Alcotest.(check int) "both boundary probabilities are scored" 2 counts.scored;
  Alcotest.(check int) "only explicit failures count as failures" 3 counts.failed;
  Alcotest.(check int) "question/answer ready are incomplete" 3 counts.incomplete

let test_artifact_integrity () =
  let content = Yojson.Safe.to_string (R.to_yojson report) in
  let sha256 = R.sha256 content in
  let decode json = UI.Measurement.decode_artifact ~sha256 json in
  (match decode (envelope content) with
   | Error detail -> Alcotest.fail detail
   | Ok actual -> Alcotest.(check string) "exact report" content
       (Yojson.Safe.to_string (R.to_yojson actual)));
  let rejects label json = Alcotest.(check bool) label true (Result.is_error (decode json)) in
  rejects "a valid different blob is not this request" (envelope (content ^ " "));
  rejects "content tampering cannot retain a hash" (`Assoc
    [ "sha256", `String sha256; "bytes", `Int (String.length content)
    ; "content", `String (String.make (String.length content) 'x') ]);
  rejects "byte count is checked" (`Assoc
    [ "sha256", `String sha256; "bytes", `Int (-1); "content", `String content ]);
  let invalid = "not-json" in
  Alcotest.(check bool) "valid hash does not excuse malformed report" true
    (Result.is_error (UI.Measurement.decode_artifact ~sha256:(R.sha256 invalid) (envelope invalid)))

let test_stale_results () =
  let state = UI.create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.lanes_mode <- UI.Lanes_measurement_detail "selected";
  state.lane_run_detail_generation <- 2;
  let accept sha256 generation result =
    UI.accept_measurement_artifact state ~sha256 ~generation result in
  accept "selected" 1 (Ok report);
  accept "other" 2 (Ok report);
  Alcotest.(check bool) "late generations and other artifacts cannot populate detail"
    true (state.measurement_report = None);
  accept "selected" 2 (Ok report);
  Alcotest.(check bool) "selected result populates detail" true
    (state.measurement_report = Some report);
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

let () =
  Alcotest.run "TUI measurement artifacts"
    [ "reader", [ Alcotest.test_case "incomplete is not failed or scored" `Quick test_stage_counts
                ; Alcotest.test_case "SHA bytes and typed report" `Quick test_artifact_integrity
                ; Alcotest.test_case "late results cannot retarget detail" `Quick test_stale_results ] ]
