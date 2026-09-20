module R = Masc.Librarian_continuity_report
module T = Masc.Typesafeai_types

let get = function Ok value -> value | Error error -> Alcotest.fail error
let rejects label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail (label ^ " was accepted")

let case : R.case =
  { id = "retained"
  ; source = { trace_id = "synthetic-original"; turn = 1; text = "The cabinet code is ORCHID-731." }
  ; context =
      { keeper_name = "synthetic-keeper"; trace_id = "synthetic-current"; read_position = 17
      ; facts = [ { id = "memory-1"; claim = "The cabinet code is ORCHID-731." } ]
      ; unread = "The cabinet is still locked."
      }
  }

let test_answer_boundary () =
  let question = "What is the cabinet code?" in
  let absent = { case.context with facts = [] } in
  let request = R.answer_prompt ~question absent in
  Alcotest.(check string) "answer receives only question and allowed context"
    (Yojson.Safe.to_string
       (`Assoc [ "question", `String question; "facts", `List []; "unread", `String absent.unread ]))
    request.user;
  let different_reference = { case with source = { case.source with text = "The code is WILLOW-924." } } in
  Alcotest.(check string) "reference changes cannot change answer context"
    request.user (R.answer_prompt ~question { different_reference.context with facts = [] }).user;
  Alcotest.(check bool) "retaining a fact changes the actual request"
    false (String.equal request.user (R.answer_prompt ~question case.context).user)

let test_dataset_boundary () =
  let input : R.dataset = { synthetic = true; cases = [ case ] } in
  ignore (get (R.parse_dataset (R.dataset_to_yojson input)));
  rejects "live export" (R.parse_dataset (R.dataset_to_yojson { input with synthetic = false }));
  rejects "empty export" (R.parse_dataset (R.dataset_to_yojson { input with cases = [] }));
  rejects "duplicate sample" (R.parse_dataset (R.dataset_to_yojson { input with cases = [ case; case ] }))

let request = R.judge_request ~endpoint:"https://judge.invalid/eval" ~model:"configured-judge"
    case ~question:"What is the cabinet code?" ~answer:"The information is unavailable."

let evaluated answers : Masc.Typesafeai_client.evaluated =
  { response = { model = "actual-judge"; answers; usage = None }
  ; destination_uri = request.endpoint
  ; request_body_sha256 = R.sha256 "synthetic request"
  }

let test_judge_boundary () =
  let answer value = T.Noul_answer { noul = value } in
  let judgment = get (R.judgment request (evaluated [ case.id, answer 0. ])) in
  Alcotest.(check (float 0.)) "zero is a completed observation" 0. judgment.probability;
  Alcotest.(check string) "actual model retained" "actual-judge" judgment.response_model;
  List.iter (fun answers -> rejects "invalid judge response" (R.judgment request (evaluated answers)))
    [ []; [ "different-id", answer 0.9 ]; [ case.id, answer 0.1; case.id, answer 0.9 ]
    ; [ case.id, answer nan ]; [ case.id, answer infinity ]; [ case.id, answer (-0.1) ]
    ; [ case.id, answer 1.1 ]
    ; [ case.id, T.Choice_answer { choice = "yes"; probabilities = [ "yes", 1. ]; confidence = 1. } ]
    ]

let test_report_keeps_incomplete_and_failed () =
  let request : R.generation_request =
    { runtime_id = "configured-runtime"; requested_model = "configured-model"
    ; prompt = R.question_prompt case.source; prepared_requests = [] }
  in
  let response : R.text_response =
    { response_id = "synthetic-response"; model = "actual-model"; text = "What is the cabinet code?" }
  in
  let generation : R.generation = { request; response } in
  let states =
    [ R.Not_started
    ; R.Question_failed { request; error = "provider unavailable"; incomplete_response = None }
    ; R.Question_ready generation
    ; R.Answer_failed (generation, { request; error = "incomplete"; incomplete_response = Some response })
    ; R.Answer_ready (generation, generation)
    ; R.Judge_failed (generation, generation, { request =
        R.judge_request ~endpoint:"https://judge.invalid/eval" ~model:"judge" case ~question:"q" ~answer:"a"
        ; error = "HTTP 503" })
    ]
  in
  let report : R.t =
    { schema = R.schema; run_id = "synthetic-test"; started_at = "2026-09-21T00:00:00Z"
    ; input_path = "synthetic.json"; input_sha256 = R.sha256 "synthetic"
    ; output_path = "report.json"; config_revision = "synthetic"
    ; binary_commit = None; executable_sha256 = None
    ; samples = List.mapi (fun i progress ->
        { R.case = { case with id = string_of_int i }; progress }) states
    }
  in
  let encoded = R.to_yojson report in
  let decoded = get (R.of_yojson encoded) in
  Alcotest.(check int) "all samples survive the stored report" 6 (List.length decoded.samples);
  Alcotest.(check string) "all failure and intermediate states survive"
    (Yojson.Safe.to_string encoded) (Yojson.Safe.to_string (R.to_yojson decoded));
  rejects "different report kind" (R.of_yojson (R.to_yojson { report with schema = "other" }))

let () =
  Alcotest.run "Librarian continuity measurement"
    [ "boundaries",
      [ Alcotest.test_case "answer sees limited context" `Quick test_answer_boundary
      ; Alcotest.test_case "explicit synthetic cases" `Quick test_dataset_boundary
      ; Alcotest.test_case "judge identity and probability" `Quick test_judge_boundary
      ; Alcotest.test_case "failures and incomplete samples are retained" `Quick test_report_keeps_incomplete_and_failed
      ]
    ]
