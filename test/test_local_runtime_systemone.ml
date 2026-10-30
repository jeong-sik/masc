(** Offline tests for the [/v1/systemone] client: argument decoding, the
    wire shapes the live endpoint enforces (measured 2026-10-19 against
    clef:cloud), and answer decoding. No test here talks to Ollama. *)

open Alcotest

module S = Masc.Tool_local_runtime_systemone

let error_of = function
  | Error message -> message
  | Ok _ -> failwith "expected an error"

let args json = S.args_of_yojson (Yojson.Safe.from_string json)

let noul_question ?true_description ?false_description () =
  S.Noul
    { instructions = "Is the build green?"
    ; true_description
    ; false_description
    }

let choice_question criteria =
  S.Choice { instructions = "Pick one."; criteria }

let score_question scale =
  S.Score { instructions = "Rate it."; scale }

(* ── Tool arguments ─────────────────────────────────────── *)

let test_default_backend_and_model () =
  let parsed =
    args
      {|{"state":"s","questions":{"q":{"type":"noul","instructions":"ok"}}}|}
  in
  match parsed with
  | Error message -> fail message
  | Ok { S.backend = Local; model; timeout_sec; _ } ->
      check int "local is the default backend" 0
        (match S.default_model Local with "nimble" -> 0 | _ -> 1);
      check bool "no model override by default" true (Option.is_none model);
      check int "default timeout" S.default_timeout_sec timeout_sec
  | Ok { S.backend = Cloud; _ } -> fail "expected the local backend"

let test_unknown_backend_is_rejected () =
  let message =
    error_of
      (args
         {|{"state":"s","backend":"ollama","questions":{"q":{"type":"noul","instructions":"ok"}}}|})
  in
  check bool "backend must be local or cloud" true
    (String.length message > 0)

let test_state_is_required_and_nonblank () =
  check bool "missing state rejected" true
    (Result.is_error (args {|{"questions":{"q":{"type":"noul","instructions":"ok"}}}|}));
  check bool "blank state rejected" true
    (Result.is_error
       (args {|{"state":"   ","questions":{"q":{"type":"noul","instructions":"ok"}}}|}))

let test_question_decoding () =
  let parsed =
    args
      {|{"state":"s","questions":{
           "depth":{"type":"choice","instructions":"Which?","criteria":{"skim":"tiny","deep":null}},
           "green":{"type":"noul","instructions":"Green?","criteria":{"true":"yes","false":"no"}},
           "risk":{"type":"score","instructions":"Risk?","criteria":["low","mid","high"]}
         }}|}
  in
  match parsed with
  | Error message -> fail message
  | Ok { S.questions; _ } ->
      (match List.assoc_opt "depth" questions with
       | Some (S.Choice { instructions; criteria }) ->
           check string "choice instructions" "Which?" instructions;
           check int "null description decodes as None" 1
             (List.length (List.filter (fun (_, d) -> Option.is_none d) criteria))
       | Some (S.Noul _ | S.Score _) | None -> fail "depth did not decode as a choice");
      (match List.assoc_opt "green" questions with
       | Some (S.Noul { true_description; false_description; _ }) ->
           check (option string) "noul true description" (Some "yes") true_description;
           check (option string) "noul false description" (Some "no") false_description
       | Some (S.Choice _ | S.Score _) | None -> fail "green did not decode as a noul");
      (match List.assoc_opt "risk" questions with
       | Some (S.Score { scale; _ }) ->
           check (list string) "score scale keeps its order" [ "low"; "mid"; "high" ] scale
       | Some (S.Choice _ | S.Noul _) | None -> fail "risk did not decode as a score")

let test_bad_questions_are_rejected () =
  let expect_error label json =
    check bool label true (Result.is_error (args json))
  in
  expect_error "missing questions" {|{"state":"s"}|};
  expect_error "unknown type"
    {|{"state":"s","questions":{"q":{"type":"rank","instructions":"?"}}}|};
  expect_error "missing instructions"
    {|{"state":"s","questions":{"q":{"type":"noul"}}}|};
  expect_error "duplicate names"
    {|{"state":"s","questions":{
        "q":{"type":"noul","instructions":"a"},
        "q":{"type":"noul","instructions":"b"}}}|};
  expect_error "invalid name characters"
    {|{"state":"s","questions":{"has space":{"type":"noul","instructions":"a"}}}|}

let test_criteria_preserve_the_asked_meaning () =
  let parse_question question =
    args (Printf.sprintf {|{"state":"s","questions":{"q":%s}}|} question)
  in
  List.iter
    (fun (label, question) ->
      check bool label true (Result.is_error (parse_question question)))
    [ ("object choice description",
       {|{"type":"choice","instructions":"?","criteria":{"approve":{"rule":"all checked"},"reject":"missing"}}|})
    ; ("numeric choice description",
       {|{"type":"choice","instructions":"?","criteria":{"approve":1,"reject":null}}|})
    ; ("duplicate choice option",
       {|{"type":"choice","instructions":"?","criteria":{"approve":null,"approve":"changed"}}|})
    ; ("blank choice key",
       {|{"type":"choice","instructions":"?","criteria":{" ":null,"reject":null}}|})
    ; ("malformed noul criteria",
       {|{"type":"noul","instructions":"?","criteria":["yes","no"]}|})
    ; ("malformed noul description",
       {|{"type":"noul","instructions":"?","criteria":{"true":false}}|})
    ; ("unknown noul outcome",
       {|{"type":"noul","instructions":"?","criteria":{"yes":"agreed"}}|})
    ; ("duplicate noul outcome",
       {|{"type":"noul","instructions":"?","criteria":{"true":null,"true":"changed"}}|})
    ];
  List.iter
    (fun criteria ->
      match parse_question
              (Printf.sprintf {|{"type":"noul","instructions":"?"%s}|} criteria) with
      | Ok { S.questions; _ } ->
          (match questions with
           | [ (name, question) ] ->
               check string "question name is retained" "q" name;
               (match question with
                | S.Noul { true_description; false_description; _ } ->
                    check (option string) "true description remains absent" None true_description;
                    check (option string) "false description remains absent" None false_description
                | S.Choice _ | S.Score _ -> fail "expected the original noul question")
           | [] | _ :: _ :: _ -> fail "expected exactly one question")
      | Error message -> fail message)
    [ ""; {|,"criteria":null|}; {|,"criteria":{}|}
    ; {|,"criteria":{"true":null,"false":null}|}
    ]

let test_timeout_bounds_are_enforced () =
  check bool "timeout 0 rejected" true
    (Result.is_error
       (args
          {|{"state":"s","timeout_sec":0,"questions":{"q":{"type":"noul","instructions":"a"}}}|}));
  check bool "timeout above max rejected" true
    (Result.is_error
       (args
          {|{"state":"s","timeout_sec":121,"questions":{"q":{"type":"noul","instructions":"a"}}}|}))

(* ── Request validation and wire shape ──────────────────── *)

let test_request_validation_bounds () =
  let request ~questions =
    { S.model = "nimble"; state = "s"; questions }
  in
  let choice count =
    let criteria =
      List.init count (fun i -> (Printf.sprintf "o%d" i, None))
    in
    ( "q"
    , choice_question
        (List.map (fun (o, d) -> (o, Option.map (fun () -> "") d)) criteria) )
  in
  check bool "one choice option is rejected" true
    (Result.is_error (S.validate_request (request ~questions:[ choice 1 ])));
  check bool "two choice options pass" true
    (Result.is_ok (S.validate_request (request ~questions:[ choice 2 ])));
  check bool "eleven rubric entries are rejected" true
    (Result.is_error
       (S.validate_request
          (request
             ~questions:
               [ ( "q"
                 , score_question (List.init 11 (fun i -> Printf.sprintf "r%d" i)) ) ])));
  check bool "blank rubric entry is rejected" true
    (Result.is_error
       (S.validate_request (request ~questions:[ ("q", score_question [ ""; "high" ]) ])));
  check bool "blank state is rejected" true
    (Result.is_error
       (S.validate_request
          { S.model = "nimble"; state = "  "; questions = [ ("q", noul_question ()) ] }))

let test_wire_shape_matches_the_endpoint () =
  (* The live endpoint refuses a noul whose true/false descriptions sit
     beside the question instead of inside a criteria object, and a score
     whose criteria is not an ordered array (2026-10-19, clef:cloud). *)
  let request =
    { S.model = "clef:cloud"
    ; state = "state text"
    ; questions =
        [ ( "green"
          , noul_question ~true_description:"yes" ~false_description:"no" () )
        ; ("risk", score_question [ "low"; "high" ])
        ; ( "depth"
          , choice_question [ ("skim", Some "tiny"); ("deep", None) ] )
        ]
    }
  in
  let open Yojson.Safe.Util in
  let json = S.request_to_yojson request in
  check string "model" "clef:cloud" (json |> member "model" |> to_string);
  let noul = json |> member "questions" |> member "green" in
  check string "noul type" "noul" (noul |> member "type" |> to_string);
  check string "noul true description lives under criteria"
    "yes" (noul |> member "criteria" |> member "true" |> to_string);
  (match json |> member "questions" |> member "risk" |> member "criteria" with
   | `List [ `String "low"; `String "high" ] -> ()
   | _ -> fail "score criteria must be the ordered array [low; high]");
  let choice = json |> member "questions" |> member "depth" in
  check string "null description encodes as null" "null"
    (Yojson.Safe.to_string (choice |> member "criteria" |> member "deep"))

(* ── Answers ────────────────────────────────────────────── *)

let test_answers_decode_from_a_live_capture () =
  (* Captured from clef:cloud 2026-10-19. *)
  let body =
    {|{"model":"clef:cloud","answers":{
         "merged":{"type":"noul","noul":0.0155},
         "depth":{"type":"choice","choice":"deep",
                  "probabilities":{"skim":0.1833,"normal":0.3597,"deep":0.457},
                  "confidence":0.0578}},
       "usage":{"input_tokens":267,"output_tokens":0}}|}
  in
  let request =
    { S.model = "clef:cloud"
    ; state = "s"
    ; questions =
        [ ("merged", noul_question ())
        ; ("depth", choice_question [ ("skim", None); ("normal", None); ("deep", None) ]) ]
    }
  in
  let open Yojson.Safe.Util in
  let answers = Yojson.Safe.from_string body |> member "answers" in
  (match S.decode_answer ("merged", snd (List.hd request.questions))
         (answers |> member "merged") with
   | Ok (S.Noul_answer probability) ->
       check (float 0.001) "noul probability" 0.0155 probability
   | Ok (S.Choice_answer _ | S.Score_answer _) -> fail "merged did not decode as a noul answer"
   | Error message -> fail message);
  (match S.decode_answer ("depth", snd (List.nth request.questions 1))
         (answers |> member "depth") with
   | Ok (S.Choice_answer { choice; probabilities; confidence }) ->
       check string "chosen option" "deep" choice;
       check int "one probability per option" 3 (List.length probabilities);
       check (float 0.0001) "confidence" 0.0578 confidence
   | Ok (S.Noul_answer _ | S.Score_answer _) -> fail "depth did not decode as a choice answer"
   | Error message -> fail message)

let test_answer_type_mismatch_is_rejected () =
  let asked = ("q", noul_question ()) in
  let answered = `Assoc [ ("type", `String "choice"); ("choice", `String "x") ] in
  check bool "answered type must match the asked type" true
    (Result.is_error (S.decode_answer asked answered))

let choice_answer ?(choice = "deep") ?(confidence = `Float 0.5) probabilities =
  `Assoc
    [ ("type", `String "choice"); ("choice", `String choice)
    ; ("probabilities", `Assoc probabilities); ("confidence", confidence)
    ]

let test_choice_answers_belong_to_the_request () =
  let asked = ("depth", choice_question [ ("skim", None); ("deep", None) ]) in
  let probabilities = [ ("deep", `Float 0.8); ("skim", `Float 0.2) ] in
  (match S.decode_answer asked (choice_answer probabilities) with
   | Ok (S.Choice_answer { probabilities; _ }) ->
       check (list string) "response object order does not change request order"
         [ "skim"; "deep" ] (List.map fst probabilities)
   | Ok (S.Noul_answer _ | S.Score_answer _) -> fail "expected a choice answer"
   | Error message -> fail message);
  List.iter
    (fun (label, answer) ->
      check bool label true (Result.is_error (S.decode_answer asked answer)))
    [ ("original live-capture mismatch is rejected",
       choice_answer [ ("skim", `Float 0.1833); ("normal", `Float 0.3597); ("deep", `Float 0.457) ])
    ; ("missing requested probability", choice_answer [ ("deep", `Float 0.8) ])
    ; ("duplicate probability key", choice_answer (probabilities @ [ ("deep", `Float 0.8) ]))
    ; ("unasked selected option", choice_answer ~choice:"normal" probabilities)
    ];
  (* Rounded distributions need not sum to exactly one. *)
  check bool "rounded probabilities remain valid" true
    (Result.is_ok
       (S.decode_answer asked
          (choice_answer [ ("skim", `Float 0.3333); ("deep", `Float 0.6666) ])))

let score_answer ?(score = `Float 0.8) ?(confidence = `Float 0.5)
    ?(legend = `Assoc [ ("1", `String "high"); ("0", `String "low") ])
    ?(probabilities = `Assoc [ ("1", `Float 0.8); ("0", `Float 0.2) ]) () =
  `Assoc
    [ ("type", `String "score"); ("score", score); ("legend", legend)
    ; ("probabilities", probabilities); ("confidence", confidence)
    ]

let test_score_answers_belong_to_the_requested_scale () =
  let asked = ("risk", score_question [ "low"; "high" ]) in
  (match S.decode_answer asked (score_answer ()) with
   | Ok (S.Score_answer { score; legend; probabilities; _ } as answer) ->
       check (float 0.0001) "weighted zero-based score" 0.8 score;
       check (list string) "indexed legend follows request order" [ "low"; "high" ] legend;
       check (list (float 0.0001)) "indexed probabilities follow request order"
         [ 0.2; 0.8 ] probabilities;
       let open Yojson.Safe.Util in
       check (list string) "tool result normalizes the legend to an ordered array"
         [ "low"; "high" ] (S.answer_to_yojson answer |> member "legend" |> to_list |> List.map to_string)
   | Ok (S.Choice_answer _ | S.Noul_answer _) -> fail "expected a score answer"
   | Error message -> fail message);
  List.iter
    (fun (label, answer) ->
      check bool label true (Result.is_error (S.decode_answer asked answer)))
    [ ("different legend", score_answer ~legend:(`Assoc [ ("0", `String "low"); ("1", `String "other") ]) ())
    ; ("missing legend level", score_answer ~legend:(`Assoc [ ("0", `String "low") ]) ())
    ; ("unasked probability level", score_answer ~probabilities:(`Assoc [ ("0", `Float 0.1); ("1", `Float 0.8); ("2", `Float 0.1) ]) ())
    ; ("missing probability level", score_answer ~probabilities:(`Assoc [ ("0", `Float 1.) ]) ())
    ; ("duplicate probability level", score_answer ~probabilities:(`Assoc [ ("0", `Float 0.1); ("0", `Float 0.1); ("1", `Float 0.8) ]) ())
    ; ("array is not the endpoint's indexed legend", score_answer ~legend:(`List [ `String "low"; `String "high" ]) ())
    ; ("score exceeds the requested scale", score_answer ~score:(`Float 2.) ())
    ]

let test_numeric_answers_are_finite_and_in_range () =
  let choice = ("depth", choice_question [ ("skim", None); ("deep", None) ]) in
  let score = ("risk", score_question [ "low"; "high" ]) in
  List.iter
    (fun value ->
      let reject asked answer =
        check bool "invalid numeric answer is rejected" true
          (Result.is_error (S.decode_answer asked answer))
      in
      reject ("merged", noul_question ())
        (`Assoc [ ("type", `String "noul"); ("noul", value) ]);
      reject choice (choice_answer [ ("skim", value); ("deep", `Float 0.8) ]);
      reject choice (choice_answer ~confidence:value [ ("skim", `Float 0.2); ("deep", `Float 0.8) ]);
      reject score (score_answer ~score:value ());
      reject score (score_answer ~confidence:value ());
      reject score (score_answer ~probabilities:(`Assoc [ ("0", value); ("1", `Float 0.8) ]) ()))
    [ `Float (-0.1); `Float 1.1; `Float Float.nan; `Float Float.infinity
    ; `Float Float.neg_infinity
    ];
  List.iter
    (fun value ->
      check bool "probability endpoints remain valid" true
        (Result.is_ok
           (S.decode_answer ("merged", noul_question ())
              (`Assoc [ ("type", `String "noul"); ("noul", value) ]))))
    [ `Int 0; `Int 1 ]

let () =
  run
    "local_runtime_systemone"
    [ ( "args"
      , [ test_case "defaults" `Quick test_default_backend_and_model
        ; test_case "unknown backend" `Quick test_unknown_backend_is_rejected
        ; test_case "state required" `Quick test_state_is_required_and_nonblank
        ; test_case "question decoding" `Quick test_question_decoding
        ; test_case "bad questions" `Quick test_bad_questions_are_rejected
        ; test_case "criteria preserve meaning" `Quick test_criteria_preserve_the_asked_meaning
        ; test_case "timeout bounds" `Quick test_timeout_bounds_are_enforced
        ] )
    ; ( "request"
      , [ test_case "validation bounds" `Quick test_request_validation_bounds
        ; test_case "wire shape" `Quick test_wire_shape_matches_the_endpoint
        ] )
    ; ( "answers"
      , [ test_case "live capture" `Quick test_answers_decode_from_a_live_capture
        ; test_case "type mismatch" `Quick test_answer_type_mismatch_is_rejected
        ; test_case "choice request binding" `Quick test_choice_answers_belong_to_the_request
        ; test_case "score request binding" `Quick test_score_answers_belong_to_the_requested_scale
        ; test_case "numeric answer bounds" `Quick test_numeric_answers_are_finite_and_in_range
        ] )
    ]
