module R = Masc.Librarian_continuity_report
module T = Masc.Typesafeai_types

let get = function Ok value -> value | Error error -> Alcotest.fail error
let rejects label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail (label ^ " was accepted")

let case : R.case =
  { id = "retained"
  ; question = None
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
  let input : R.dataset = { provenance = R.Synthetic; cases = [ case ] } in
  let encoded = R.dataset_to_yojson input in
  let decoded = get (R.parse_dataset encoded) in
  Alcotest.(check bool) "explicit provenance retained" true (decoded.provenance = R.Synthetic);
  Alcotest.(check (list (option string))) "no fixed question requests generation"
    [ None ] (List.map (fun (case : R.case) -> case.question) decoded.cases);
  Alcotest.(check string) "provenance wire contract" "[\"Synthetic\"]"
    (Yojson.Safe.to_string (Yojson.Safe.Util.member "provenance" encoded));
  rejects "unknown provenance"
    (R.parse_dataset
       (`Assoc [ "provenance", `List [ `String "Observed" ]; "cases", `List [ R.case_to_yojson case ] ]));
  rejects "missing provenance" (R.parse_dataset (`Assoc [ "cases", `List [ R.case_to_yojson case ] ]));
  rejects "empty export" (R.parse_dataset (R.dataset_to_yojson { input with cases = [] }));
  rejects "duplicate sample" (R.parse_dataset (R.dataset_to_yojson { input with cases = [ case; case ] }));
  List.iter (fun question ->
    rejects "blank fixed question" (R.parse_dataset (R.dataset_to_yojson
      { input with cases = [ { case with question = Some question } ] }))) [ ""; " \t\n" ]

let request = R.judge_request ~endpoint:"https://judge.invalid/eval" ~model:"configured-judge"
    case ~question:"What is the cabinet code?" ~answer:"The information is unavailable."

let evaluated answers : Masc.Typesafeai_client.evaluated =
  { response = { model = "actual-judge"; answers; usage = None }
  ; destination_uri = request.endpoint
  ; request_body_sha256 = Digestif.SHA256.(to_hex (digest_string "synthetic request"))
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

let generated_question : R.generation =
  { request =
      { runtime_id = "configured-runtime"; requested_model = "configured-model"
      ; prompt = R.question_prompt case.source; prepared_requests = [] }
  ; response =
      { response_id = "synthetic-question"; model = "actual-model"; text = "What is the cabinet code?" }
  }

let answer : R.generation =
  { request = { generated_question.request with prompt = R.answer_prompt ~question:generated_question.response.text case.context }
  ; response = { generated_question.response with response_id = "synthetic-answer"; text = "ORCHID-731" }
  }

let question = R.Generated generated_question

let report samples : R.t =
    { schema = R.schema; provenance = R.Synthetic; run_id = "synthetic-test"; started_at = "2026-09-21T00:00:00Z"
    ; input_path = "synthetic.json"; input_sha256 = Digestif.SHA256.(to_hex (digest_string "synthetic"))
    ; output_path = "report.json"; config_revision = "synthetic"
    ; binary_commit = None; executable_sha256 = None
    ; samples
    }

let test_report_keeps_incomplete_and_failed () =
  let sample id progress : R.sample = { case = { case with id }; progress } in
  let judgment = get (R.judgment request (evaluated [ case.id, T.Noul_answer { noul = 0. } ])) in
  let report = report
    [ sample "not-started" R.Not_started
    ; sample "question-failed" (R.Question_failed { request = generated_question.request; error = "provider unavailable"; incomplete_response = None })
    ; sample "question-ready" (R.Question_ready question)
    ; sample "answer-failed" (R.Answer_failed (question, { request = answer.request; error = "incomplete"; incomplete_response = Some answer.response }))
    ; sample "answer-ready" (R.Answer_ready { question; answer })
    ; sample "judge-failed" (R.Judge_failed { question; answer; failure = { request = { request with question_id = "judge-failed" }; error = "HTTP 503" } })
    ; sample case.id (R.Scored { question; answer; judgment })
    ]
  in
  let encoded = R.to_yojson report in
  let decoded = get (R.of_yojson encoded) in
  Alcotest.(check string) "report schema" "masc.librarian-continuity.v1" decoded.schema;
  Alcotest.(check bool) "report provenance retained" true (decoded.provenance = R.Synthetic);
  Alcotest.(check string) "report provenance wire contract" "[\"Synthetic\"]"
    (Yojson.Safe.to_string (Yojson.Safe.Util.member "provenance" encoded));
  Alcotest.(check int) "all samples survive the stored report" 7 (List.length decoded.samples);
  Alcotest.(check string) "all failure and intermediate states survive"
    (Yojson.Safe.to_string encoded) (Yojson.Safe.to_string (R.to_yojson decoded));
  List.iter (fun (sample : R.sample) ->
    match sample.progress with
    | R.Answer_ready { question; answer }
    | R.Judge_failed { question; answer; _ }
    | R.Scored { question; answer; _ } ->
        Alcotest.(check string) "question retains its role" "What is the cabinet code?" (R.question_text question);
        Alcotest.(check string) "answer retains its role" "ORCHID-731" answer.response.text;
        (match question with
         | R.Generated generation ->
             Alcotest.(check string) "question keeps provider evidence" "synthetic-question" generation.response.response_id
         | R.Provided _ -> Alcotest.fail "Generated question lost its origin")
    | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _ -> ()) decoded.samples;
  let unknown_provenance = match encoded with
    | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
        key, if key = "provenance" then `List [ `String "Observed" ] else value) fields)
    | _ -> Alcotest.fail "Expected report object"
  in
  rejects "unknown report provenance" (R.of_yojson unknown_provenance);
  rejects "different report kind" (R.of_yojson (R.to_yojson { report with schema = "other" }))

let test_provided_question () =
  let text = "Which code unlocks the cabinet?" in
  let case = { case with question = Some text } in
  let dataset : R.dataset = { provenance = R.Synthetic; cases = [ case ] } in
  let decoded = get (R.parse_dataset (R.dataset_to_yojson dataset)) in
  Alcotest.(check (list (option string))) "fixed wording survives dataset"
    [ Some text ] (List.map (fun (case : R.case) -> case.question) decoded.cases);
  let question = R.Provided text in
  let answer = { answer with request =
      { answer.request with prompt = R.answer_prompt ~question:text case.context } } in
  let request = R.judge_request ~endpoint:request.endpoint ~model:request.model case
      ~question:text ~answer:answer.response.text in
  let judgment = get (R.judgment request (evaluated [ case.id, T.Noul_answer { noul = 0.5 } ])) in
  let states =
    [ R.Question_ready question
    ; R.Answer_failed (question, { request = answer.request; error = "provider unavailable"; incomplete_response = None })
    ; R.Answer_ready { question; answer }
    ; R.Judge_failed { question; answer; failure = { request; error = "HTTP 503" } }
    ; R.Scored { question; answer; judgment }
    ]
  in
  List.iter (fun progress ->
    let encoded = R.to_yojson (report [ { R.case; progress } ]) in
    let decoded = get (R.of_yojson encoded) in
    Alcotest.(check string) "fixed question and prior evidence survive"
      (Yojson.Safe.to_string encoded) (Yojson.Safe.to_string (R.to_yojson decoded));
    match decoded.samples with
    | [ { progress = R.Question_ready question | R.Answer_failed (question, _)
          | R.Answer_ready { question; _ } | R.Judge_failed { question; _ }
          | R.Scored { question; _ }; _ } ] ->
        Alcotest.(check string) "fixed question text" text (R.question_text question);
        (match question with
         | R.Provided supplied -> Alcotest.(check string) "provided origin" text supplied
         | R.Generated _ -> Alcotest.fail "Provided question acquired fake generation")
    | _ -> Alcotest.fail "Question progress was lost") states;
  (match R.progress_to_yojson (R.Answer_ready { question; answer }) with
   | `List [ `String "Answer_ready"; `Assoc fields ] ->
       Alcotest.(check string) "named question wire keeps provided origin"
         (Yojson.Safe.to_string (`List [ `String "Provided"; `String text ]))
         (Yojson.Safe.to_string (List.assoc "question" fields));
       Alcotest.(check string) "named answer wire retains answer role" "ORCHID-731"
         Yojson.Safe.Util.(List.assoc "answer" fields |> member "response" |> member "text" |> to_string)
   | _ -> Alcotest.fail "Expected named Answer_ready wire payload")

let test_report_judge_identity () =
  let judgment = get (R.judgment request (evaluated [ case.id, T.Noul_answer { noul = 0.5 } ])) in
  let decode progress = R.of_yojson (R.to_yojson (report [ { R.case; progress } ])) in
  rejects "scored request from another sample"
    (decode (R.Scored { question; answer; judgment = { judgment with request = { request with question_id = "other-case" } } }));
  rejects "failed request from another sample"
    (decode (R.Judge_failed { question; answer; failure = { request = { request with question_id = "other-case" }; error = "HTTP 503" } }));
  List.iter (fun probability ->
    rejects "invalid stored probability" (decode (R.Scored { question; answer; judgment = { judgment with probability } })))
    [ nan; infinity; -0.1; 1.1 ]

let test_report_question_origin () =
  let text = generated_question.response.text in
  let judgment = get (R.judgment request (evaluated [ case.id, T.Noul_answer { noul = 0.5 } ])) in
  let states question =
    [ R.Question_ready question
    ; R.Answer_failed (question, { request = answer.request; error = "provider unavailable"; incomplete_response = None })
    ; R.Answer_ready { question; answer }
    ; R.Judge_failed { question; answer; failure = { request; error = "HTTP 503" } }
    ; R.Scored { question; answer; judgment }
    ]
  in
  List.iter (fun (label, supplied, question) ->
    let case = { case with question = supplied } in
    List.iter (fun progress ->
      rejects label (R.of_yojson (R.to_yojson (report [ { R.case; progress } ]))))
      (states question))
    [ "changed provided wording", Some text, R.Provided (text ^ " Changed.")
    ; "generated origin for provided question", Some text, R.Generated generated_question
    ; "provided origin without supplied question", None, R.Provided text
    ];
  let case = { case with question = Some text } in
  let (_ : R.t) = get (R.of_yojson (R.to_yojson (report [ { R.case; progress = R.Not_started } ]))) in
  rejects "provided question cannot fail generation"
    (R.of_yojson (R.to_yojson (report
       [ { R.case; progress = R.Question_failed
           { request = generated_question.request; error = "provider unavailable"; incomplete_response = None } } ])))

let () =
  Alcotest.run "Librarian continuity measurement"
    [ "boundaries",
      [ Alcotest.test_case "answer sees limited context" `Quick test_answer_boundary
      ; Alcotest.test_case "explicit synthetic cases" `Quick test_dataset_boundary
      ; Alcotest.test_case "judge identity and probability" `Quick test_judge_boundary
      ; Alcotest.test_case "failures and incomplete samples are retained" `Quick test_report_keeps_incomplete_and_failed
      ; Alcotest.test_case "stored judgments belong to their sample" `Quick test_report_judge_identity
      ; Alcotest.test_case "fixed questions retain provided origin" `Quick test_provided_question
      ; Alcotest.test_case "stored questions match their sample origin and text" `Quick test_report_question_origin
      ]
    ]
