(* Feature tests for the durable question log: what a Keeper asks survives a
   restart, an answer closes it once, and a crash-truncated tail does not take
   the recorded history with it. *)

open Masc

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_ask_store_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let keeper = "asker"

let fail_with prefix message = Alcotest.fail (prefix ^ ": " ^ message)

let a_choice ~id ~label =
  match Keeper_ask.choice ~choice_id:id ~label () with
  | Ok c -> c
  | Error e -> fail_with "choice" (Keeper_ask.invalid_choice_to_string e)

let a_question () =
  match
    Keeper_ask.question ~question_id:"q1" ~header:"Route" ~prompt:"Which way should I go?"
      ~choices:[ a_choice ~id:"a" ~label:"Cut over now"; a_choice ~id:"b" ~label:"Stage it" ]
      ~mode:Keeper_ask.Single ~free_text:Keeper_ask.Choices_only
  with
  | Ok q -> q
  | Error e -> fail_with "question" (Keeper_ask.invalid_question_to_string e)

let an_ask ~ask_id =
  let continuation =
    match Keeper_continuation_channel.dashboard ~thread_id:"thread-1" with
    | Ok c -> c
    | Error e -> fail_with "continuation" e
  in
  match
    Keeper_ask.ask ~ask_id ~keeper_name:keeper ~questions:[ a_question () ]
      ~context:"picking a migration order" ~continuation ~asked_at:1000.0 ()
  with
  | Ok a -> a
  | Error e -> fail_with "ask" (Keeper_ask.invalid_ask_to_string e)

let responder =
  {
    Keeper_ask.surface = Surface_ref.Dashboard { session_id = Some "s1" };
    actor_id = Some "vincent";
    display_name = Some "Vincent";
  }

let record base_path ask_id =
  match Keeper_ask_store.record_ask ~base_path (an_ask ~ask_id) with
  | Ok () -> ()
  | Error e -> fail_with "record_ask" e

(* Everything below reads through a fresh load, so passing means the state came
   off disk rather than out of a value the test was still holding. *)
let a_recorded_question_survives_a_reload () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  match Keeper_ask_store.open_asks ~base_path ~keeper_name:keeper with
  | [ a ] ->
      Alcotest.(check string) "ask_id" "ask-1" a.Keeper_ask.ask_id;
      Alcotest.(check string) "context survived" "picking a migration order"
        (Option.value a.Keeper_ask.context ~default:"");
      Alcotest.(check int) "open count" 1
        (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper)
  | asks -> Alcotest.failf "expected one open ask, got %d" (List.length asks)

let answering_closes_the_question_and_keeps_the_answer () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  (match
     Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
       ~submissions:[ ("q1", Keeper_ask.Chose { choice_ids = [ "b" ] }) ]
       ~responder ~now:1100.0
   with
  | Ok _ -> ()
  | Error e -> fail_with "answer" (Keeper_ask_store.answer_failure_to_string e));
  Alcotest.(check int) "no longer open" 0
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper);
  match Keeper_ask_store.settled ~base_path ~keeper_name:keeper ~ask_id:"ask-1" with
  | Some (Keeper_ask.Answered_by { answers = [ { response = Chose { choice_ids = [ id ] }; _ } ]; _ })
    ->
      Alcotest.(check string) "the choice that was made" "b" id
  | Some _ -> Alcotest.fail "settled to something other than the recorded answer"
  | None -> Alcotest.fail "the ask disappeared"

let a_written_alternative_survives_reload () =
  let base_path = temp_dir () in
  record base_path "ask-alternative";
  let text = "제시된 선택지 대신 직접 확인해주세요.\n  원문 그대로  " in
  (match Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-alternative"
     ~submissions:[("q1", Keeper_ask.Wrote text)] ~responder ~now:1100. with
   | Ok _ -> ()
   | Error e -> fail_with "alternative" (Keeper_ask_store.answer_failure_to_string e));
  match Keeper_ask_store.settled ~base_path ~keeper_name:keeper ~ask_id:"ask-alternative" with
  | Some (Keeper_ask.Answered_by { answers = [{response = Wrote actual; _}]; _ }) ->
      Alcotest.(check string) "exact alternative is durable" text actual
  | _ -> Alcotest.fail "alternative did not survive the durable log"

(* The second surface has to be able to show what was already chosen, not just
   be told no. *)
let a_second_answer_reports_what_already_landed () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  let submit choice_id now =
    Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~submissions:[ ("q1", Keeper_ask.Chose { choice_ids = [ choice_id ] }) ]
      ~responder ~now
  in
  (match submit "a" 1100.0 with
  | Ok _ -> ()
  | Error e -> fail_with "first answer" (Keeper_ask_store.answer_failure_to_string e));
  match submit "b" 1200.0 with
  | Error
      (Keeper_ask_store.Already_answered
        { answers = [ { response = Chose { choice_ids = [ id ] }; _ } ]; answered_at; _ }) ->
      Alcotest.(check string) "reports the winning choice" "a" id;
      Alcotest.(check (float 0.001)) "reports when it landed" 1100.0 answered_at
  | Error e ->
      fail_with "expected Already_answered" (Keeper_ask_store.answer_failure_to_string e)
  | Ok _ -> Alcotest.fail "a second answer was accepted"

let answering_an_unknown_ask_is_refused () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  match
    Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-missing"
      ~submissions:[ ("q1", Keeper_ask.Skipped) ]
      ~responder ~now:1100.0
  with
  | Error (Keeper_ask_store.Ask_not_found { ask_id = "ask-missing" }) -> ()
  | Error e -> fail_with "expected Ask_not_found" (Keeper_ask_store.answer_failure_to_string e)
  | Ok _ -> Alcotest.fail "an unknown ask was answered"

let a_withdrawn_question_refuses_answers () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  (match
     Keeper_ask_store.withdraw ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
       ~reason:"found it myself" ~now:1100.0
   with
  | Ok () -> ()
  | Error e -> fail_with "withdraw" (Keeper_ask_store.withdraw_failure_to_string e));
  Alcotest.(check int) "no longer open" 0
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper);
  match
    Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~submissions:[ ("q1", Keeper_ask.Chose { choice_ids = [ "a" ] }) ]
      ~responder ~now:1200.0
  with
  | Error (Keeper_ask_store.Already_withdrawn { reason; _ }) ->
      Alcotest.(check string) "reason kept" "found it myself" reason
  | Error e -> fail_with "expected Already_withdrawn" (Keeper_ask_store.answer_failure_to_string e)
  | Ok _ -> Alcotest.fail "a withdrawn ask was answered"

let an_answer_that_does_not_fit_the_question_is_refused () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  match
    Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~submissions:[ ("q1", Keeper_ask.Chose { choice_ids = [ "not-offered" ] }) ]
      ~responder ~now:1100.0
  with
  | Error (Keeper_ask_store.Rejected [ Unknown_choice _ ]) -> ()
  | Error e -> fail_with "expected Rejected" (Keeper_ask_store.answer_failure_to_string e)
  | Ok _ -> Alcotest.fail "an unoffered choice was stored"

let append_raw base_path text =
  let path = Keeper_ask_store.log_path ~base_path ~keeper_name:keeper in
  let out = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  output_string out text;
  close_out out

(* A process killed mid-append leaves a half-written final line. Losing every
   recorded question to that is worse than dropping the incomplete write. *)
let a_truncated_final_line_does_not_erase_the_history () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  record base_path "ask-2";
  append_raw base_path "{\"event\":\"asked\",\"ask\":{\"ask_id\":\"ask-3\"";
  Alcotest.(check int) "both complete asks survive" 2
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper)

(* Damage anywhere else means the history itself is not trustworthy, and a
   reader that skipped it would report a shortened past as complete. *)
let a_damaged_middle_line_fails_the_read () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  append_raw base_path "{\"event\":\"asked\",\"ask\":{\"ask_id\":\"ask-2\"\n";
  record base_path "ask-3";
  Alcotest.(check int) "read yields nothing rather than a shortened history" 0
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper)

(* The decoded log is kept while the file is unchanged. A row another writer
   appends, without going through this store, changes the file and is read
   on the next load. *)
let a_row_another_writer_appends_is_read () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  Alcotest.(check int) "one open question" 1
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper);
  append_raw base_path
    (Yojson.Safe.to_string (Keeper_ask.event_to_json (Keeper_ask.Asked (an_ask ~ask_id:"ask-2")))
     ^ "\n");
  Alcotest.(check int) "the appended question is read" 2
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper)

let a_keeper_with_no_log_has_no_questions () =
  let base_path = temp_dir () in
  Alcotest.(check int) "no log, no questions" 0
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:keeper);
  Alcotest.(check bool) "settled says nothing" true
    (Keeper_ask_store.settled ~base_path ~keeper_name:keeper ~ask_id:"ask-1" = None)

let the_log_is_per_keeper () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  Alcotest.(check int) "another keeper sees none" 0
    (Keeper_ask_store.open_ask_count ~base_path ~keeper_name:"analyst")

let strict_reads_distinguish_missing_empty_and_damage () =
  let base_path = temp_dir () in
  (match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
   | Ok Keeper_ask_store.Missing_log -> ()
   | Ok (Stored_rows _) | Error _ -> Alcotest.fail "missing log was not classified as missing");
  record base_path "ask-1";
  let path = Keeper_ask_store.log_path ~base_path ~keeper_name:keeper in
  let out = open_out path in close_out out;
  (match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
   | Ok (Keeper_ask_store.Stored_rows []) -> ()
   | Ok _ | Error _ -> Alcotest.fail "existing empty log was not classified as stored");
  record base_path "ask-1";
  append_raw base_path "{broken middle row}\n";
  record base_path "ask-2";
  let before = (Unix.stat path).Unix.st_size in
  (match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
   | Error (Keeper_ask_store.Log_decode_failed _) -> ()
   | Error error -> Alcotest.fail (Keeper_ask_store.read_error_to_string error)
   | Ok _ -> Alcotest.fail "damaged history authorized a complete fold");
  (match Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~submissions:[ "q1", Keeper_ask.Chose { choice_ids = [ "a" ] } ] ~responder ~now:1200. with
   | Error (Keeper_ask_store.Store_failed _) -> ()
   | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error)
   | Ok _ -> Alcotest.fail "damaged history authorized an answer");
  Alcotest.(check int) "failed authoritative read writes no answer" before (Unix.stat path).Unix.st_size

let optimistic_answer_reports_the_canonical_first_writer () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  let loser = { responder with Keeper_ask.actor_id = Some "other-operator" } in
  let before_append () =
    match Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
        ~submissions:[ "q1", Keeper_ask.Chose { choice_ids = [ "a" ] } ] ~responder ~now:1100. with
    | Ok _ -> ()
    | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error) in
  match Keeper_ask_store.For_testing.answer_with_interleaving ~before_append
      ~after_append:(fun () -> ()) ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~submissions:[ "q1", Keeper_ask.Chose { choice_ids = [ "b" ] } ] ~responder:loser ~now:1200. with
  | Error (Keeper_ask_store.Already_answered
      { answers = [ { response = Keeper_ask.Chose { choice_ids = [ chosen ] }; _ } ]; responder = canonical; answered_at }) ->
      Alcotest.(check string) "optimistic loser returns the stored winning choice" "a" chosen;
      Alcotest.(check bool) "stored responder is the winner" true (canonical = responder);
      Alcotest.(check (float 0.)) "stored first-answer time is retained" 1100. answered_at
  | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error)
  | Ok _ -> Alcotest.fail "optimistic loser was acknowledged as the canonical winner"

let committed_answer_with_unreadable_winner_is_explicit () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  let path = Keeper_ask_store.log_path ~base_path ~keeper_name:keeper in
  let saved = path ^ ".committed" in
  let after_append () =
    Unix.rename path saved;
    let out = open_out path in
    output_string out ("{broken middle row}\n" ^
      Yojson.Safe.to_string (Keeper_ask.event_to_json (Keeper_ask.Asked (an_ask ~ask_id:"ask-1"))) ^ "\n");
    close_out out in
  (match Keeper_ask_store.For_testing.answer_with_interleaving
      ~before_append:(fun () -> ()) ~after_append ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~submissions:[ "q1", Keeper_ask.Chose { choice_ids = [ "a" ] } ] ~responder ~now:1100. with
   | Error (Keeper_ask_store.Answer_recorded_unconfirmed _) -> ()
   | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error)
   | Ok _ -> Alcotest.fail "unreadable first-winner read became confirmed success");
  Unix.unlink path;
  Unix.rename saved path;
  match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
  | Ok (Keeper_ask_store.Stored_rows [ _, (_, Keeper_ask.Answered_by _) ]) -> ()
  | Ok _ | Error _ -> Alcotest.fail "the committed answer did not survive the failed reread"

let same_size_external_mutation_cannot_reuse_a_cached_answer () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  (match Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~submissions:[ "q1", Keeper_ask.Chose { choice_ids = [ "a" ] } ] ~responder ~now:1100. with
   | Ok _ -> () | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error));
  ignore (Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper);
  let path = Keeper_ask_store.log_path ~base_path ~keeper_name:keeper in
  let before = Unix.stat path in
  let ask = an_ask ~ask_id:"ask-1" in
  let answers = Keeper_ask.parse_answers ~ask
      ~submissions:[ "q1", Keeper_ask.Chose { choice_ids = [ "b" ] } ] |> Result.get_ok in
  let bytes = String.concat "" (List.map (fun event ->
      Yojson.Safe.to_string (Keeper_ask.event_to_json event) ^ "\n")
      [ Keeper_ask.Asked ask; Keeper_ask.Answered { ask_id = "ask-1"; answers; responder; answered_at = 1100. } ]) in
  Alcotest.(check int) "external mutation preserves byte length" before.st_size (String.length bytes);
  let out = open_out path in output_string out bytes; close_out out;
  Unix.utimes path before.st_atime before.st_mtime;
  match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
  | Ok (Keeper_ask_store.Stored_rows
      [ _, (_, Keeper_ask.Answered_by { answers = [ { response = Keeper_ask.Chose { choice_ids = [ chosen ] }; _ } ]; _ }) ]) ->
      Alcotest.(check string) "owned current bytes determine the answer" "b" chosen
  | Ok _ | Error _ -> Alcotest.fail "external mutation was not read canonically"

let () =
  Alcotest.run "keeper_ask_store"
    [
      ( "what a Keeper asked survives",
        [
          Alcotest.test_case "written alternative survives reload" `Quick a_written_alternative_survives_reload;
          Alcotest.test_case "a recorded question survives a reload" `Quick
            a_recorded_question_survives_a_reload;
          Alcotest.test_case "no log means no questions" `Quick
            a_keeper_with_no_log_has_no_questions;
          Alcotest.test_case "the log is per keeper" `Quick the_log_is_per_keeper;
        ] );
      ( "answering",
        [
          Alcotest.test_case "answering closes it and keeps the answer" `Quick
            answering_closes_the_question_and_keeps_the_answer;
          Alcotest.test_case "a second answer reports what landed" `Quick
            a_second_answer_reports_what_already_landed;
          Alcotest.test_case "an unknown ask is refused" `Quick answering_an_unknown_ask_is_refused;
          Alcotest.test_case "a withdrawn question refuses answers" `Quick
            a_withdrawn_question_refuses_answers;
          Alcotest.test_case "an answer that does not fit is refused" `Quick
            an_answer_that_does_not_fit_the_question_is_refused;
          Alcotest.test_case "optimistic answer reports the first writer" `Quick
            optimistic_answer_reports_the_canonical_first_writer;
          Alcotest.test_case "committed answer with unreadable winner is explicit" `Quick
            committed_answer_with_unreadable_winner_is_explicit;
        ] );
      ( "a damaged log",
        [
          Alcotest.test_case "a row another writer appends is read" `Quick
            a_row_another_writer_appends_is_read;
          Alcotest.test_case "a truncated final line keeps the history" `Quick
            a_truncated_final_line_does_not_erase_the_history;
          Alcotest.test_case "a damaged middle line fails the read" `Quick
            a_damaged_middle_line_fails_the_read;
          Alcotest.test_case "strict reads distinguish missing empty and damage" `Quick
            strict_reads_distinguish_missing_empty_and_damage;
          Alcotest.test_case "same-size external mutation changes the cached answer" `Quick
            same_size_external_mutation_cannot_reuse_a_cached_answer;
        ] );
    ]
