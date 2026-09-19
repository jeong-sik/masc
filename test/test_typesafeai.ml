(** Unit tests for TypeSafe AI System One integration and Board Attention adapter. *)

module T = Masc.Typesafeai_types
module C = Masc.Typesafeai_config
module B = Masc.Typesafeai_board_attention
module J = Masc.Keeper_board_attention_judgment

let test_request_encoding () =
  let state = `Assoc [ "text", `String "Please review this pull request" ] in
  let questions =
    [ ( "is_review"
      , T.Noul
          { instructions = "Is this requesting a review?"
          ; criteria = Some ("Yes, explicit review request", "No, other topic")
          } )
    ; ( "team"
      , T.Choice
          { instructions = "Which team should review?"
          ; criteria =
              [ "frontend", Some "React / UI changes"
              ; "backend", Some "OCaml / database changes"
              ]
          } )
    ; ( "urgency"
      , T.Score
          { instructions = "Review urgency level"
          ; criteria = [ "low"; "medium"; "high" ]
          } )
    ]
  in
  let req = T.request_to_yojson ~model:"jev-latest" ~state ~questions in
  match req with
  | `Assoc fields ->
    Alcotest.(check string) "model is jev-latest" "jev-latest"
      (match List.assoc_opt "model" fields with
       | Some (`String s) -> s
       | _ -> Alcotest.fail "missing model");
    Alcotest.(check bool) "has state" true (List.mem_assoc "state" fields);
    Alcotest.(check bool) "has questions" true (List.mem_assoc "questions" fields)
  | _ -> Alcotest.fail "request must be an assoc"
;;

let test_response_decoding () =
  let json_str =
    {|{
      "model": "jev-latest",
      "answers": {
        "is_review": {
          "type": "noul",
          "noul": 0.96
        },
        "team": {
          "type": "choice",
          "choice": "backend",
          "probabilities": { "frontend": 0.05, "backend": 0.95 },
          "confidence": 0.92
        },
        "urgency": {
          "type": "score",
          "score": 2.1,
          "probabilities": [0.1, 0.2, 0.7],
          "confidence": 0.85
        }
      },
      "usage": {
        "input_tokens": 120,
        "output_tokens": 0
      }
    }|}
  in
  let json = Yojson.Safe.from_string json_str in
  match T.eval_response_of_yojson json with
  | Error err -> Alcotest.fail ("decoding failed: " ^ err)
  | Ok res ->
    Alcotest.(check string) "model matches" "jev-latest" res.model;
    Alcotest.(check int) "3 answers" 3 (List.length res.answers);
    (match List.assoc_opt "is_review" res.answers with
     | Some (T.Noul_answer { noul }) ->
       Alcotest.(check (float 0.001)) "noul is 0.96" 0.96 noul
     | _ -> Alcotest.fail "expected noul answer");
    (match List.assoc_opt "team" res.answers with
     | Some (T.Choice_answer { choice; confidence; probabilities }) ->
       Alcotest.(check string) "choice is backend" "backend" choice;
       Alcotest.(check (float 0.001)) "confidence is 0.92" 0.92 confidence;
       Alcotest.(check int) "2 probabilities" 2 (List.length probabilities)
     | _ -> Alcotest.fail "expected choice answer");
    (match List.assoc_opt "urgency" res.answers with
     | Some (T.Score_answer { score; confidence; _ }) ->
       Alcotest.(check (float 0.001)) "score is 2.1" 2.1 score;
       Alcotest.(check (float 0.001)) "confidence is 0.85" 0.85 confidence
     | _ -> Alcotest.fail "expected score answer");
    (match res.usage with
     | Some u ->
       Alcotest.(check int) "input tokens" 120 u.input_tokens;
       Alcotest.(check int) "output tokens free" 0 u.output_tokens
     | None -> Alcotest.fail "expected usage")
;;

type team =
  | Frontend
  | Backend

let team_label = function
  | Frontend -> "frontend"
  | Backend -> "backend"
;;

let teams () =
  match
    T.choice_set
      ~options:[ Frontend; Backend ]
      ~label:team_label
      ~describe:(function
        | Frontend -> Some "React / UI changes"
        | Backend -> Some "OCaml / database changes")
  with
  | Ok set -> set
  | Error detail -> Alcotest.fail detail
;;

let choice_answer ~choice ~probabilities =
  T.Choice_answer { choice; probabilities; confidence = 0.9 }
;;

let test_choice_set_builds_request_and_decodes_answer () =
  (match T.question_to_yojson (T.choice_of_set ~instructions:"Which team?" (teams ())) with
   | `Assoc fields ->
     (match List.assoc_opt "criteria" fields with
      | Some (`Assoc criteria) ->
        Alcotest.(check (list string))
          "the request offers the set's labels, in order"
          [ "frontend"; "backend" ]
          (List.map fst criteria)
      | _ -> Alcotest.fail "a choice question must carry a criteria map")
   | _ -> Alcotest.fail "question must be an assoc");
  match
    T.decode_choice
      (teams ())
      (choice_answer ~choice:"backend" ~probabilities:[ "frontend", 0.05; "backend", 0.95 ])
  with
  | Ok { T.choice = Backend; probabilities = [ (Frontend, _); (Backend, _) ]; _ } -> ()
  | Ok _ -> Alcotest.fail "the answer decoded to the wrong options"
  | Error detail -> Alcotest.fail detail
;;

let test_answer_outside_the_set_is_an_error () =
  let check_error label answer =
    match T.decode_choice (teams ()) answer with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "%s decoded to an option" label
  in
  check_error
    "a choice the question did not offer"
    (choice_answer ~choice:"infra" ~probabilities:[ "frontend", 0.5; "backend", 0.5 ]);
  check_error
    "a probability key the question did not offer"
    (choice_answer ~choice:"backend" ~probabilities:[ "backend", 0.9; "infra", 0.1 ]);
  check_error
    "a score answer"
    (T.Score_answer { score = 1.0; probabilities = []; confidence = 0.9 })
;;

let test_choice_set_rejects_no_options_and_shared_labels () =
  let describe _ = None in
  (match T.choice_set ~options:[] ~label:team_label ~describe with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a choice set with no options was accepted");
  match T.choice_set ~options:[ Frontend; Backend ] ~label:(fun _ -> "team") ~describe with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "two options sharing a label were accepted"
;;

let test_config_defaults () =
  Alcotest.(check string) "default endpoint"
    "https://api.typesafe.ai/v1/systemone" C.default_endpoint;
  Alcotest.(check string) "default model" "jev-latest" C.default_model
;;

let () =
  Alcotest.run "typesafeai"
    [ ( "codecs"
      , [ Alcotest.test_case "request_encoding" `Quick test_request_encoding
        ; Alcotest.test_case "response_decoding" `Quick test_response_decoding
        ; Alcotest.test_case
            "choice set builds the request and decodes the answer"
            `Quick
            test_choice_set_builds_request_and_decodes_answer
        ; Alcotest.test_case
            "an answer outside the choice set is an error"
            `Quick
            test_answer_outside_the_set_is_an_error
        ; Alcotest.test_case
            "a choice set needs options with distinct labels"
            `Quick
            test_choice_set_rejects_no_options_and_shared_labels
        ] )
    ; "config", [ Alcotest.test_case "defaults" `Quick test_config_defaults ]
    ]
;;
