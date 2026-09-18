(** Unit tests for TypeSafe AI System One integration and Board Attention adapter. *)

module T = Masc.Typesafe_types
module C = Masc.Typesafe_config
module B = Masc.Typesafe_board_attention
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

let test_config_defaults () =
  Alcotest.(check string) "default endpoint"
    "https://api.typesafe.ai/v1/systemone" C.default_endpoint;
  Alcotest.(check string) "default model" "jev-latest" C.default_model
;;

let () =
  Alcotest.run "typesafe"
    [ ( "codecs"
      , [ Alcotest.test_case "request_encoding" `Quick test_request_encoding
        ; Alcotest.test_case "response_decoding" `Quick test_response_decoding
        ] )
    ; "config", [ Alcotest.test_case "defaults" `Quick test_config_defaults ]
    ]
;;
