(* Feature tests for Keeper_ask: a Keeper asks a human a structured question,
   a human answers it from some surface, and the log folds to one row. *)

open Masc
open Keeper_ask

let fail_with prefix message = Alcotest.fail (prefix ^ ": " ^ message)

let ok_choice ~id ~label =
  match choice ~choice_id:id ~label () with
  | Ok c -> c
  | Error e -> fail_with "choice" (invalid_choice_to_string e)

let ok_question ~id ~choices ~mode ~free_text =
  match
    question ~question_id:id ~header:"Route" ~prompt:"Which way should I go?" ~choices ~mode
      ~free_text
  with
  | Ok q -> q
  | Error e -> fail_with "question" (invalid_question_to_string e)

let dashboard_channel thread_id =
  match Keeper_continuation_channel.dashboard ~thread_id with
  | Ok c -> c
  | Error e -> fail_with "continuation" e

let ok_ask ~questions =
  match
    ask ~ask_id:"ask-1" ~keeper_name:"asker" ~questions ~context:"picking a migration order"
      ~continuation:(dashboard_channel "thread-1") ~asked_at:1000.0 ()
  with
  | Ok a -> a
  | Error e -> fail_with "ask" (invalid_ask_to_string e)

let two_choice_question ~mode ~free_text =
  ok_question ~id:"q1"
    ~choices:[ ok_choice ~id:"a" ~label:"Cut over now"; ok_choice ~id:"b" ~label:"Stage it" ]
    ~mode ~free_text

let responder_on surface =
  { surface; actor_id = Some "vincent"; display_name = Some "Vincent" }

let dashboard_responder = responder_on (Surface_ref.Dashboard { session_id = Some "s1" })
let agent_responder = responder_on Surface_ref.Agent

let error_names errors = List.map invalid_answer_to_string errors

(* A question that offers nothing and refuses free text cannot be answered by
   any submission, so it must not be constructible. *)
let question_with_no_answer_path_is_rejected () =
  match
    question ~question_id:"q1" ~header:"Route" ~prompt:"Which way?" ~choices:[] ~mode:Single
      ~free_text:Choices_only
  with
  | Error No_way_to_answer -> ()
  | Error other -> fail_with "expected No_way_to_answer" (invalid_question_to_string other)
  | Ok _ -> Alcotest.fail "a question with no choices and no free text was accepted"

let open_question_needs_no_choices () =
  match
    question ~question_id:"q1" ~header:"Note" ~prompt:"Anything I should know?" ~choices:[]
      ~mode:Single ~free_text:(Free_text_allowed { hint = Some "optional" })
  with
  | Ok _ -> ()
  | Error e -> fail_with "free-text-only question rejected" (invalid_question_to_string e)

let duplicate_choice_ids_are_rejected () =
  match
    question ~question_id:"q1" ~header:"Route" ~prompt:"Which way?"
      ~choices:[ ok_choice ~id:"a" ~label:"One"; ok_choice ~id:"a" ~label:"Two" ]
      ~mode:Single ~free_text:Choices_only
  with
  | Error (Duplicate_choice_ids [ "a" ]) -> ()
  | Error other -> fail_with "expected Duplicate_choice_ids" (invalid_question_to_string other)
  | Ok _ -> Alcotest.fail "duplicate choice_id was accepted"

(* The ordinary round: the Keeper asks, a human picks one of the offered
   choices, and the submission parses. *)
let a_human_picks_an_offered_choice () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  match parse_answers ~ask:a ~submissions:[ ("q1", Chose { choice_ids = [ "b" ] }) ] with
  | Ok [ { question_id = "q1"; response = Chose { choice_ids = [ "b" ] } } ] -> ()
  | Ok _ -> Alcotest.fail "parsed answer did not carry the submitted choice"
  | Error errors -> fail_with "valid answer rejected" (String.concat "; " (error_names errors))

let skipping_is_a_valid_answer () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  match parse_answers ~ask:a ~submissions:[ ("q1", Skipped) ] with
  | Ok [ { response = Skipped; _ } ] -> ()
  | Ok _ -> Alcotest.fail "skip did not survive parsing"
  | Error errors -> fail_with "skip rejected" (String.concat "; " (error_names errors))

let choice_the_question_never_offered_is_rejected () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  match parse_answers ~ask:a ~submissions:[ ("q1", Chose { choice_ids = [ "zzz" ] }) ] with
  | Error [ Unknown_choice { question_id = "q1"; choice_id = "zzz" } ] -> ()
  | Error errors -> fail_with "expected Unknown_choice" (String.concat "; " (error_names errors))
  | Ok _ -> Alcotest.fail "an unoffered choice was accepted"

let single_choice_question_refuses_two_picks () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  match parse_answers ~ask:a ~submissions:[ ("q1", Chose { choice_ids = [ "a"; "b" ] }) ] with
  | Error [ Multiple_choices_for_single { question_id = "q1"; count = 2 } ] -> ()
  | Error errors ->
      fail_with "expected Multiple_choices_for_single" (String.concat "; " (error_names errors))
  | Ok _ -> Alcotest.fail "a single-choice question accepted two picks"

let multi_choice_question_accepts_two_picks () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Multi ~free_text:Choices_only ] in
  match parse_answers ~ask:a ~submissions:[ ("q1", Chose { choice_ids = [ "a"; "b" ] }) ] with
  | Ok [ { response = Chose { choice_ids = [ "a"; "b" ] }; _ } ] -> ()
  | Ok _ -> Alcotest.fail "multi-select lost a pick"
  | Error errors -> fail_with "multi-select rejected" (String.concat "; " (error_names errors))

let free_text_is_refused_when_not_offered () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  match parse_answers ~ask:a ~submissions:[ ("q1", Wrote "something else") ] with
  | Error [ Free_text_not_offered { question_id = "q1" } ] -> ()
  | Error errors ->
      fail_with "expected Free_text_not_offered" (String.concat "; " (error_names errors))
  | Ok _ -> Alcotest.fail "free text was accepted by a choices-only question"

let a_question_left_out_is_reported () =
  let a =
    ok_ask
      ~questions:
        [
          two_choice_question ~mode:Single ~free_text:Choices_only;
          ok_question ~id:"q2"
            ~choices:[ ok_choice ~id:"y" ~label:"Yes" ]
            ~mode:Single ~free_text:Choices_only;
        ]
  in
  match parse_answers ~ask:a ~submissions:[ ("q1", Chose { choice_ids = [ "a" ] }) ] with
  | Error [ Unanswered { question_id = "q2" } ] -> ()
  | Error errors -> fail_with "expected Unanswered" (String.concat "; " (error_names errors))
  | Ok _ -> Alcotest.fail "a missing submission was accepted"

(* The .mli promises every violation is reported, so a surface can show all of
   them at once instead of making the human pay a round trip per mistake. *)
let every_violation_is_reported_at_once () =
  let a =
    ok_ask
      ~questions:
        [
          two_choice_question ~mode:Single ~free_text:Choices_only;
          ok_question ~id:"q2"
            ~choices:[ ok_choice ~id:"y" ~label:"Yes" ]
            ~mode:Single ~free_text:Choices_only;
        ]
  in
  match
    parse_answers ~ask:a
      ~submissions:[ ("q1", Chose { choice_ids = [ "a"; "nope" ] }); ("q3", Skipped) ]
  with
  | Ok _ -> Alcotest.fail "a submission with several violations was accepted"
  | Error errors ->
      let has p = List.exists p errors in
      let missing =
        List.filter_map
          (fun (name, present) -> if present then None else Some name)
          [
            ( "Multiple_choices_for_single",
              has (function Multiple_choices_for_single _ -> true | _ -> false) );
            ("Unknown_choice", has (function Unknown_choice _ -> true | _ -> false));
            ("Unknown_question", has (function Unknown_question _ -> true | _ -> false));
            ("Unanswered", has (function Unanswered _ -> true | _ -> false));
          ]
      in
      if missing <> [] then
        Alcotest.failf "these violations were not reported: %s" (String.concat ", " missing)

(* Two surfaces answering the same question is a race the log has to settle
   without asking anyone which one counted. *)
let first_answer_wins_when_two_surfaces_race () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  let answers_for choice_id =
    match parse_answers ~ask:a ~submissions:[ ("q1", Chose { choice_ids = [ choice_id ] }) ] with
    | Ok answers -> answers
    | Error errors -> fail_with "setup answer rejected" (String.concat "; " (error_names errors))
  in
  let events =
    [
      Asked a;
      Answered
        {
          ask_id = "ask-1";
          answers = answers_for "a";
          responder = dashboard_responder;
          answered_at = 1100.0;
        };
      Answered
        {
          ask_id = "ask-1";
          answers = answers_for "b";
          responder = agent_responder;
          answered_at = 1200.0;
        };
    ]
  in
  match fold_events events with
  | [ ("ask-1", (_, Answered_by { answers = [ { response = Chose { choice_ids = [ id ] }; _ } ]; answered_at; _ })) ]
    ->
      Alcotest.(check string) "first write won" "a" id;
      Alcotest.(check (float 0.001)) "first timestamp kept" 1100.0 answered_at
  | rows -> Alcotest.failf "expected one answered row, got %d" (List.length rows)

let a_withdrawn_question_is_no_longer_open () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  let events =
    [ Asked a; Withdrawn { ask_id = "ask-1"; reason = "found it myself"; withdrawn_at = 1300.0 } ]
  in
  Alcotest.(check int) "no open asks" 0 (List.length (open_asks events));
  match fold_events events with
  | [ ("ask-1", (_, Withdrawn_because { reason; _ })) ] ->
      Alcotest.(check string) "reason kept" "found it myself" reason
  | rows -> Alcotest.failf "expected one withdrawn row, got %d" (List.length rows)

let an_unanswered_question_stays_open () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  match open_asks [ Asked a ] with
  | [ { ask_id = "ask-1"; _ } ] -> ()
  | asks -> Alcotest.failf "expected one open ask, got %d" (List.length asks)

let an_answer_for_an_unknown_ask_is_dropped () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  let events =
    [
      Asked a;
      Answered
        { ask_id = "ask-missing"; answers = []; responder = dashboard_responder; answered_at = 1.0 };
    ]
  in
  Alcotest.(check int) "one open ask survives" 1 (List.length (open_asks events))

(* A question that survives a write and a read is the same question, including
   the choice ids answers reference. *)
let an_event_survives_the_log_round_trip () =
  let a =
    ok_ask
      ~questions:
        [
          two_choice_question ~mode:Multi
            ~free_text:(Free_text_allowed { hint = Some "or say something else" });
        ]
  in
  let encoded = event_to_json (Asked a) in
  match event_of_json encoded with
  | Error e -> fail_with "round trip failed" e
  | Ok (Asked restored) ->
      Alcotest.(check string) "ask_id" a.ask_id restored.ask_id;
      Alcotest.(check string) "context kept" "picking a migration order"
        (Option.value restored.context ~default:"");
      Alcotest.(check (list string))
        "choice ids"
        (List.concat_map (fun q -> List.map (fun c -> c.choice_id) q.choices) a.questions)
        (List.concat_map (fun q -> List.map (fun c -> c.choice_id) q.choices) restored.questions);
      Alcotest.(check string) "json is stable"
        (Yojson.Safe.to_string encoded)
        (Yojson.Safe.to_string (event_to_json (Asked restored)))
  | Ok _ -> Alcotest.fail "round trip changed the event kind"

let an_answered_event_survives_the_log_round_trip () =
  let a = ok_ask ~questions:[ two_choice_question ~mode:Single ~free_text:Choices_only ] in
  let answers =
    match parse_answers ~ask:a ~submissions:[ ("q1", Chose { choice_ids = [ "a" ] }) ] with
    | Ok answers -> answers
    | Error errors -> fail_with "setup answer rejected" (String.concat "; " (error_names errors))
  in
  let event =
    Answered
      { ask_id = "ask-1"; answers; responder = dashboard_responder; answered_at = 1100.0 }
  in
  match event_of_json (event_to_json event) with
  | Ok restored ->
      Alcotest.(check string) "json is stable"
        (Yojson.Safe.to_string (event_to_json event))
        (Yojson.Safe.to_string (event_to_json restored))
  | Error e -> fail_with "answered round trip failed" e

(* A truncated or hand-edited line must fail to parse rather than load as
   something weaker. *)
let an_unknown_event_kind_is_an_error () =
  match event_of_json (`Assoc [ ("event", `String "expired") ]) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "an unknown event kind was accepted"

let an_unknown_response_kind_is_an_error () =
  let json =
    `Assoc
      [
        ("event", `String "answered");
        ("ask_id", `String "ask-1");
        ( "answers",
          `List
            [
              `Assoc
                [
                  ("question_id", `String "q1");
                  ("response", `Assoc [ ("kind", `String "maybe") ]);
                ];
            ] );
        ("responder", `Assoc [ ("surface", `Assoc [ ("kind", `String "agent") ]) ]);
        ("answered_at", `Float 1.0);
      ]
  in
  match event_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "an unknown response kind was accepted"

let () =
  Alcotest.run "keeper_ask"
    [
      ( "a question must be answerable",
        [
          Alcotest.test_case "no choices and no free text is rejected" `Quick
            question_with_no_answer_path_is_rejected;
          Alcotest.test_case "free text alone is enough" `Quick open_question_needs_no_choices;
          Alcotest.test_case "duplicate choice ids are rejected" `Quick
            duplicate_choice_ids_are_rejected;
        ] );
      ( "answering",
        [
          Alcotest.test_case "a human picks an offered choice" `Quick
            a_human_picks_an_offered_choice;
          Alcotest.test_case "skipping is an answer" `Quick skipping_is_a_valid_answer;
          Alcotest.test_case "an unoffered choice is rejected" `Quick
            choice_the_question_never_offered_is_rejected;
          Alcotest.test_case "single refuses two picks" `Quick
            single_choice_question_refuses_two_picks;
          Alcotest.test_case "multi accepts two picks" `Quick multi_choice_question_accepts_two_picks;
          Alcotest.test_case "free text refused when not offered" `Quick
            free_text_is_refused_when_not_offered;
          Alcotest.test_case "a question left out is reported" `Quick a_question_left_out_is_reported;
          Alcotest.test_case "every violation is reported at once" `Quick
            every_violation_is_reported_at_once;
        ] );
      ( "folding the log",
        [
          Alcotest.test_case "first answer wins a race" `Quick
            first_answer_wins_when_two_surfaces_race;
          Alcotest.test_case "withdrawn is no longer open" `Quick
            a_withdrawn_question_is_no_longer_open;
          Alcotest.test_case "unanswered stays open" `Quick an_unanswered_question_stays_open;
          Alcotest.test_case "answer for unknown ask is dropped" `Quick
            an_answer_for_an_unknown_ask_is_dropped;
        ] );
      ( "the log round trip",
        [
          Alcotest.test_case "asked survives" `Quick an_event_survives_the_log_round_trip;
          Alcotest.test_case "answered survives" `Quick
            an_answered_event_survives_the_log_round_trip;
          Alcotest.test_case "unknown event kind is an error" `Quick
            an_unknown_event_kind_is_an_error;
          Alcotest.test_case "unknown response kind is an error" `Quick
            an_unknown_response_kind_is_an_error;
        ] );
    ]
