(** An installation's questions to the operator (RFC operator-quiz §4.6): the
    Keeper question lifecycle in a per-declaration log of the Lane store. *)
open Alcotest
module Asks = Masc.Lane_addon_asks
module Ask = Masc.Keeper_ask
module Store = Masc.Lane_addon_store

let require = function Ok value -> value | Error detail -> fail detail

let with_store f =
  let dir = Filename.temp_file "lane-asks-" ".fixture" in
  Sys.remove dir; Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f (Store.create ~root:(Filename.concat dir "lane-addons"))))

let questions =
  require
    (Asks.questions_of_json
       (`List
          [ `Assoc
              [ "question_id", `String "q1"; "header", `String "Ledger"; "prompt", `String "What does the ledger record?"
              ; "choices", `List [ `Assoc [ "choice_id", `String "a"; "label", `String "Facts"; "description", `Null ]
                                 ; `Assoc [ "choice_id", `String "b"; "label", `String "Plans"; "description", `Null ] ]
              ; "mode", `String "single"; "free_text", `Assoc [ "kind", `String "choices_only" ] ] ]))

let asked ?(id = "quiz-1") ?(qs = questions) () =
  require (Asks.ask ~ask_id:id ~declaration_id:"quiz" ~title:"Operator quiz" ~questions:qs ~asked_at:1.0 ())

let operator = { Ask.surface = Masc.Surface_ref.Dashboard { session_id = None }; actor_id = None; display_name = None }

let resolution store id =
  match List.assoc_opt id (require (Asks.rows store ~declaration_id:"quiz")) with
  | Some (_, resolution) -> resolution
  | None -> fail ("no row for " ^ id)

let test_a_question_is_recorded_once_per_request () =
  with_store (fun store ->
    check bool "first" true (Asks.record store (asked ()) = Ok Asks.Recorded);
    check bool "the same request again" true (Asks.record store (asked ()) = Ok Asks.Already_recorded);
    let other = require (Ask.question_of_json (`Assoc [ "question_id", `String "q2"; "header", `String "H"; "prompt", `String "P"
                                                      ; "choices", `List []; "mode", `String "single"
                                                      ; "free_text", `Assoc [ "kind", `String "allowed"; "hint", `Null ] ])) in
    check bool "the same id with other questions" true (Asks.record store (asked ~qs:[ other ] ()) = Ok Asks.Id_reused);
    check int "one row" 1 (List.length (require (Asks.rows store ~declaration_id:"quiz")));
    check (list string) "the declaration has a log" [ "quiz" ] (require (Asks.declarations store)))

let test_the_first_answer_wins () =
  with_store (fun store ->
    ignore (require (Asks.record store (asked ())));
    let answer choice now =
      Asks.answer store ~declaration_id:"quiz" ~ask_id:"quiz-1"
        ~submissions:[ "q1", Ask.Chose { choice_ids = [ choice ] } ] ~responder:operator ~now
    in
    check bool "the operator answers" true (Result.is_ok (answer "a" 2.0));
    (match answer "b" 3.0 with
     | Error (Asks.Already_answered { answered_at }) -> check (float 0.0) "the first answer stands" 2.0 answered_at
     | Ok _ | Error _ -> fail "a second answer must be refused");
    (match resolution store "quiz-1" with
     | Ask.Answered_by { answers = [ { response = Ask.Chose { choice_ids = [ id ] }; _ } ]; _ } -> check string "first" "a" id
     | Ask.Answered_by _ | Ask.Open | Ask.Withdrawn_because _ -> fail "answered by the first answer"))

let test_an_answer_naming_no_offered_choice_is_rejected () =
  with_store (fun store ->
    ignore (require (Asks.record store (asked ())));
    match Asks.answer store ~declaration_id:"quiz" ~ask_id:"quiz-1"
            ~submissions:[ "q1", Ask.Chose { choice_ids = [ "z" ] } ] ~responder:operator ~now:2.0 with
    | Error (Asks.Rejected _) -> check bool "still open" true (resolution store "quiz-1" = Ask.Open)
    | Ok _ | Error _ -> fail "an unoffered choice must be rejected")

let test_only_an_open_question_is_withdrawn () =
  with_store (fun store ->
    ignore (require (Asks.record store (asked ())));
    ignore (require (Asks.record store (asked ~id:"quiz-2" ())));
    check bool "withdrawn" true (Asks.withdraw store ~declaration_id:"quiz" ~ask_id:"quiz-1" ~reason:"superseded" ~now:2.0 = Ok Asks.Withdrawn);
    check bool "an answer after withdrawal is refused" true
      (match Asks.answer store ~declaration_id:"quiz" ~ask_id:"quiz-1"
               ~submissions:[ "q1", Ask.Skipped ] ~responder:operator ~now:3.0 with
       | Error (Asks.Already_withdrawn _) -> true | Ok _ | Error _ -> false);
    ignore (require (Asks.answer store ~declaration_id:"quiz" ~ask_id:"quiz-2" ~submissions:[ "q1", Ask.Skipped ] ~responder:operator ~now:4.0
                     |> Result.map_error Asks.answer_failure_to_string));
    check bool "an answered question is not withdrawn" true
      (Asks.withdraw store ~declaration_id:"quiz" ~ask_id:"quiz-2" ~reason:"late" ~now:5.0 = Ok Asks.Was_answered);
    check bool "an unknown question" true
      (Asks.withdraw store ~declaration_id:"quiz" ~ask_id:"nope" ~reason:"x" ~now:6.0 = Ok Asks.Not_asked))

let test_a_damaged_history_is_an_error_but_a_cut_last_line_is_not () =
  with_store (fun store ->
    ignore (require (Asks.record store (asked ())));
    let path = Filename.concat (Filename.concat (Store.root store) "asks") (Store.digest "quiz" ^ ".jsonl") in
    let append text = Out_channel.with_open_gen [ Open_append; Open_binary ] 0o600 path (fun channel -> output_string channel text) in
    append "{\"kind\":\n";
    check bool "a cut last line is tolerated" true (Result.is_ok (Asks.rows store ~declaration_id:"quiz"));
    append "{\"kind\":\"withdrawn\",\"ask_id\":\"quiz-1\",\"reason\":\"r\",\"withdrawn_at\":2.0}\n";
    check bool "a damaged line before the last is an error" true (Result.is_error (Asks.rows store ~declaration_id:"quiz")))

let () =
  run "lane add-on installation questions"
    [ ( "asks"
      , [ test_case "a question is recorded once per request" `Quick test_a_question_is_recorded_once_per_request
        ; test_case "the first answer wins" `Quick test_the_first_answer_wins
        ; test_case "an answer naming no offered choice is rejected" `Quick test_an_answer_naming_no_offered_choice_is_rejected
        ; test_case "only an open question is withdrawn" `Quick test_only_an_open_question_is_withdrawn
        ; test_case "a damaged history is an error but a cut last line is not" `Quick
            test_a_damaged_history_is_an_error_but_a_cut_last_line_is_not ] ) ]
