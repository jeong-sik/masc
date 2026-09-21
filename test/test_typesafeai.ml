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
          "score": 1.25,
          "probabilities": { "2": 0.25, "0": 0, "1": 0.75 },
          "confidence": 0.5
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
       Alcotest.(check (list (pair string (float 0.001))))
         "choice probabilities retain named options"
         [ "frontend", 0.05; "backend", 0.95 ] probabilities
     | _ -> Alcotest.fail "expected choice answer");
    (match List.assoc_opt "urgency" res.answers with
     | Some (T.Score_answer { score; confidence; probabilities }) ->
       Alcotest.(check (float 0.001)) "score is 1.25" 1.25 score;
       Alcotest.(check (float 0.001)) "confidence is 0.5" 0.5 confidence;
       Alcotest.(check int) "all score levels are retained" 3 (List.length probabilities);
       Alcotest.(check (list (pair int (float 0.001))))
         "score probabilities retain level indices in response order"
         [ 2, 0.25; 0, 0.0; 1, 0.75 ]
         probabilities
     | _ -> Alcotest.fail "expected score answer");
    (match res.usage with
     | Some u ->
       Alcotest.(check int) "input tokens" 120 u.input_tokens;
       Alcotest.(check int) "output tokens free" 0 u.output_tokens
     | None -> Alcotest.fail "expected usage")
;;

let test_score_response_rejects_invalid_probabilities () =
  let check_error (label, probability_fields) =
    let response =
      `Assoc
        [ "model", `String "jev-latest"
        ; "answers",
          `Assoc
            [ "urgency",
              `Assoc
                ([ "type", `String "score"
                 ; "score", `Float 1.25
                 ; "confidence", `Float 0.5
                 ] @ probability_fields)
            ]
        ]
    in
    match T.eval_response_of_yojson response with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "score response accepted %s" label
  in
  List.iter check_error
    [ "missing probabilities", []
    ; "null probabilities", [ "probabilities", `Null ]
    ; "an array", [ "probabilities", `List [ `Float 0.5; `Float 0.5 ] ]
    ; "an empty map", [ "probabilities", `Assoc [] ]
    ; "a nonnumeric probability",
      [ "probabilities", `Assoc [ "0", `Float 0.5; "1", `String "0.5" ] ]
    ; "a nonnumeric level", [ "probabilities", `Assoc [ "high", `Float 1.0 ] ]
    ; "a fractional level", [ "probabilities", `Assoc [ "1.5", `Float 1.0 ] ]
    ; "a negative level", [ "probabilities", `Assoc [ "-1", `Float 1.0 ] ]
    ]
;;

let test_choice_response_rejects_empty_probabilities () =
  let response =
    Yojson.Safe.from_string
      {|{"model":"jev-latest","answers":{"team":{
        "type":"choice","choice":"backend","confidence":0.9,"probabilities":{}
      }}}|}
  in
  match T.eval_response_of_yojson response with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "choice response accepted empty probabilities"
;;

let test_response_rejects_every_nonfinite_answer_field () =
  let forms =
    [ "noul", (fun number -> Printf.sprintf {|{"type":"noul","noul":%s}|} number)
    ; "choice confidence",
      (fun number ->
        Printf.sprintf
          {|{"type":"choice","choice":"yes","confidence":%s,"probabilities":{"yes":1}}|}
          number)
    ; "choice probability",
      (fun number ->
        Printf.sprintf
          {|{"type":"choice","choice":"yes","confidence":1,"probabilities":{"yes":%s}}|}
          number)
    ; "score",
      (fun number ->
        Printf.sprintf
          {|{"type":"score","score":%s,"confidence":1,"probabilities":{"0":1}}|}
          number)
    ; "score confidence",
      (fun number ->
        Printf.sprintf
          {|{"type":"score","score":0,"confidence":%s,"probabilities":{"0":1}}|}
          number)
    ; "score probability",
      (fun number ->
        Printf.sprintf
          {|{"type":"score","score":0,"confidence":1,"probabilities":{"0":%s}}|}
          number)
    ]
  in
  List.iter (fun (field, form) ->
    List.iter (fun number ->
      let answer = form number in
      let response =
        Yojson.Safe.from_string
          (Printf.sprintf {|{"model":"jev-test","answers":{"q":%s}}|} answer)
      in
      match T.eval_response_of_yojson response with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "accepted non-finite %s: %s" field number)
      [ "NaN"; "Infinity"; "-Infinity"; "1e400"; "-1e400" ]) forms
;;

let test_response_preserves_answers_with_unknown_usage () =
  let counts input output =
    `Assoc [ "input_tokens", input; "output_tokens", output ]
  in
  let cases =
    [ "absent", None, None
    ; "null", Some `Null, None
    ; "not an object", Some (`String "unknown"), None
    ; "empty object", Some (`Assoc []), None
    ; "missing input", Some (`Assoc [ "output_tokens", `Int 0 ]), None
    ; "missing output", Some (`Assoc [ "input_tokens", `Int 12 ]), None
    ; "string input", Some (counts (`String "12") (`Int 0)), None
    ; "string output", Some (counts (`Int 12) (`String "0")), None
    ; "float input", Some (counts (`Float 12.0) (`Int 0)), None
    ; "float output", Some (counts (`Int 12) (`Float 0.0)), None
    ; "negative input", Some (counts (`Int (-1)) (`Int 0)), None
    ; "negative output", Some (counts (`Int 12) (`Int (-1))), None
    ; "measured zero", Some (counts (`Int 0) (`Int 0)), Some (0, 0)
    ; "measured counts", Some (counts (`Int 12) (`Int 3)), Some (12, 3)
    ]
  in
  List.iter (fun (label, usage, expected) ->
    let response =
      `Assoc
        ([ "model", `String "jev-test"
         ; "answers", `Assoc [ "q", `Assoc [ "type", `String "noul"; "noul", `Int 1 ] ]
         ] @ match usage with None -> [] | Some usage -> [ "usage", usage ])
    in
    match T.eval_response_of_yojson response with
    | Error detail -> Alcotest.failf "%s usage rejected a valid answer: %s" label detail
    | Ok response ->
      (match response.answers with
       | [ "q", T.Noul_answer { noul = 1.0 } ] -> ()
       | _ -> Alcotest.failf "%s usage changed the answer" label);
      Alcotest.(check (option (pair int int))) label expected
        (Option.map (fun (usage : T.usage) -> usage.input_tokens, usage.output_tokens)
           response.usage)) cases
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


let policy
      ?(enabled = true)
      ?(endpoint = C.default_endpoint)
      ?(model = C.default_model)
      ?(board_attention = true)
      ?(absorb_gate = false)
      ?(context_review = false)
      ?(excluded_keepers = [])
      ()
  : Runtime_schema.typesafeai
  =
  { Runtime_schema.lane_enabled = enabled
  ; lane_endpoint = endpoint
  ; lane_model = model
  ; board_attention
  ; absorb_gate
  ; context_review
  ; excluded_keepers
  }
;;

let with_policy p f = Masc_test_deps.with_typesafeai_policy p f
let with_key key f = Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" key f

(* The lane reads the published [typesafeai] table; before any load that is
   the default, and the key alone comes from the environment. *)
let test_config_reads_the_published_policy () =
  with_policy (policy ()) (fun () ->
    Alcotest.(check string) "the default endpoint" C.default_endpoint (C.endpoint ());
    Alcotest.(check string) "the default model" C.default_model (C.model ()));
  with_policy (policy ~endpoint:"https://fixture.invalid/systemone" ~model:"jev-next" ()) (fun () ->
    Alcotest.(check string) "the table's endpoint" "https://fixture.invalid/systemone" (C.endpoint ());
    Alcotest.(check string) "the table's model" "jev-next" (C.model ()))
;;

let test_config_readiness_is_typed_and_credential_free () =
  with_key None (fun () ->
    with_policy (policy ()) (fun () ->
      match C.readiness () with
      | C.Off -> ()
      | C.Configured _ -> Alcotest.fail "a missing key reported JEV configured"));
  with_key (Some "secret-not-for-projection") (fun () ->
    with_policy (policy ~enabled:false ()) (fun () ->
      match C.readiness () with
      | C.Off -> ()
      | C.Configured _ -> Alcotest.fail "a lane turned off reported JEV configured");
    with_policy (policy ~model:"jev-next" ()) (fun () ->
      match C.readiness () with
      | C.Off -> Alcotest.fail "an enabled configuration reported JEV off"
      | C.Configured { model } ->
        Alcotest.(check string) "readiness carries the model, never the key" "jev-next" model))
;;

(* Each gate has its own switch on top of the lane's: a key turns the lane
   on, and a gate can still be turned off by name without touching the other. *)
let test_each_gate_has_its_own_switch () =
  let gates () = C.is_board_attention_enabled (), C.is_absorb_gate_enabled () in
  with_key (Some "synthetic-jev-key") (fun () ->
    with_policy (policy ()) (fun () ->
      Alcotest.(check (pair bool bool))
        "a key with the default table turns the board gate on and leaves the absorb gate off"
        (true, false) (gates ()));
    with_policy (policy ~board_attention:false ~absorb_gate:true ()) (fun () ->
      (match C.readiness () with
       | C.Off -> ()
       | C.Configured _ -> Alcotest.fail "a disabled Board gate reported JEV configured");
      Alcotest.(check (pair bool bool)) "each switch reaches only its own gate"
        (false, true) (gates ()));
    with_policy (policy ~absorb_gate:true ()) (fun () ->
      Alcotest.(check (pair bool bool)) "the absorb gate turned on leaves the board gate on"
        (true, true) (gates ()));
    with_policy (policy ~enabled:false ~absorb_gate:true ()) (fun () ->
      Alcotest.(check (pair bool bool)) "the lane off turns both gates off"
        (false, false) (gates ())));
  with_key None (fun () ->
    with_policy (policy ~absorb_gate:true ()) (fun () ->
      Alcotest.(check (pair bool bool)) "without a key neither gate is on"
        (false, false) (gates ())))
;;

(* A keeper named in [excluded_keepers] is never asked about, whichever gate
   asks; every other keeper gets the key. The reason a gate is off is the
   first of the lane switch, the key, the gate's switch and the exclusion. *)
let test_an_excluded_keeper_keeps_its_content_home () =
  let state = function
    | Error reason -> C.unavailable_reason_to_string reason
    | Ok api_key -> "on:" ^ api_key
  in
  let excluded = "kidsnote-slack-context-collector" in
  with_key (Some "synthetic-jev-key") (fun () ->
    with_policy (policy ~absorb_gate:true ~excluded_keepers:[ excluded ] ()) (fun () ->
      Alcotest.(check string) "the absorb gate excludes the named keeper" "keeper_excluded"
        (state (C.absorb_gate_api_key ~keeper_id:excluded));
      Alcotest.(check string) "the Board gate excludes the same keeper" "keeper_excluded"
        (state (C.board_attention_api_key ~keeper_id:excluded));
      Alcotest.(check string) "another keeper gets the key at the absorb gate" "on:synthetic-jev-key"
        (state (C.absorb_gate_api_key ~keeper_id:"polisher"));
      Alcotest.(check string) "and at the Board gate" "on:synthetic-jev-key"
        (state (C.board_attention_api_key ~keeper_id:"polisher"));
      Alcotest.(check bool) "the exclusion is one question" true (C.is_excluded ~keeper_id:excluded));
    with_policy (policy ~excluded_keepers:[ "polisher" ] ()) (fun () ->
      Alcotest.(check string) "an exclusion does not turn a gate on" "absorb_gate_disabled"
        (state (C.absorb_gate_api_key ~keeper_id:"polisher")));
    with_policy (policy ~enabled:false ~absorb_gate:true ~excluded_keepers:[ "polisher" ] ()) (fun () ->
      Alcotest.(check string) "the lane switch is named before the exclusion" "lane_disabled"
        (state (C.absorb_gate_api_key ~keeper_id:"polisher"))));
  with_key None (fun () ->
    with_policy (policy ~absorb_gate:true ~excluded_keepers:[ "polisher" ] ()) (fun () ->
      Alcotest.(check string) "no key is named before the exclusion" "missing_api_key"
        (state (C.absorb_gate_api_key ~keeper_id:"polisher"))))
;;

(* The names in [excluded_keepers] are checked against the keepers of the
   base path at boot: a misspelt name excludes nobody, so it is reported. *)
let test_new_review_requires_its_own_opt_in () =
  let state = function
    | Ok _ -> "enabled"
    | Error reason -> C.unavailable_reason_to_string reason
  in
  let check_review label expected =
    Alcotest.(check string) label expected
      (state (C.context_review_api_key ~keeper_id:"polisher"))
  in
  with_key (Some "synthetic-jev-key") (fun () ->
    with_policy (policy ()) (fun () ->
      check_review "a key alone does not enable the new review" "context_review_disabled");
    with_policy (policy ~context_review:true ()) (fun () ->
      check_review "explicit opt-in enables review" "enabled");
    with_policy (policy ~context_review:true ~excluded_keepers:[ "polisher" ] ()) (fun () ->
      check_review "review honors the common exclusion" "keeper_excluded");
    with_policy (policy ~enabled:false ~context_review:true ()) (fun () ->
      check_review "lane disabled" "lane_disabled"));
  with_key None (fun () ->
    with_policy (policy ~context_review:true ()) (fun () ->
      check_review "review requires a key" "missing_api_key"))
;;

(* Names are checked against the declared Keeper roster at boot. *)
let test_unknown_excluded_keepers_are_named () =
  with_policy (policy ~excluded_keepers:[ "kidsnote-slack-context-collector"; "collecter" ] ()) (fun () ->
    Alcotest.(check (list string)) "the name that is no keeper" [ "collecter" ]
      (C.unknown_excluded_keepers ~known:[ "kidsnote-slack-context-collector"; "polisher" ]))
;;


let () =
  Alcotest.run "typesafeai"
    [ ( "codecs"
      , [ Alcotest.test_case "request_encoding" `Quick test_request_encoding
        ; Alcotest.test_case "response_decoding" `Quick test_response_decoding
        ; Alcotest.test_case
            "score response rejects invalid probabilities"
            `Quick
            test_score_response_rejects_invalid_probabilities
        ; Alcotest.test_case
            "choice response rejects empty probabilities"
            `Quick
            test_choice_response_rejects_empty_probabilities
        ; Alcotest.test_case
            "every non-finite answer field is rejected"
            `Quick
            test_response_rejects_every_nonfinite_answer_field
        ; Alcotest.test_case
            "unknown usage preserves valid answers without inventing zero"
            `Quick
            test_response_preserves_answers_with_unknown_usage
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
    ; ( "config"
      , [ Alcotest.test_case "defaults" `Quick test_config_defaults
        ; Alcotest.test_case "typed credential-free readiness" `Quick
            test_config_readiness_is_typed_and_credential_free
        ; Alcotest.test_case "reads the published policy" `Quick
            test_config_reads_the_published_policy
        ; Alcotest.test_case "an excluded keeper keeps its content home, at both gates" `Quick
            test_an_excluded_keeper_keeps_its_content_home
        ; Alcotest.test_case "New review requires its own opt-in" `Quick
            test_new_review_requires_its_own_opt_in
        ; Alcotest.test_case "unknown excluded keepers are named" `Quick
            test_unknown_excluded_keepers_are_named
        ; Alcotest.test_case "each gate has its own switch" `Quick
            test_each_gate_has_its_own_switch
        ] )

    ]
;;
