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

let an_ask_at ~ask_id ~asked_at ~context =
  let continuation =
    match Keeper_continuation_channel.dashboard ~thread_id:"thread-1" with
    | Ok c -> c
    | Error e -> fail_with "continuation" e
  in
  match
    Keeper_ask.ask ~ask_id ~keeper_name:keeper ~questions:[ a_question () ]
      ~context ~continuation ~asked_at ()
  with
  | Ok a -> a
  | Error e -> fail_with "ask" (Keeper_ask.invalid_ask_to_string e)

let an_ask ~ask_id = an_ask_at ~ask_id ~asked_at:1000.0 ~context:"picking a migration order"

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

let a_racing_answer_prevents_withdrawal_acknowledgement () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  let before_append () =
    match Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
        ~submissions:["q1", Keeper_ask.Chose {choice_ids=["a"]}] ~responder ~now:1100. with
    | Ok _ -> ()
    | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error) in
  (match Keeper_ask_store.For_testing.withdraw_with_interleaving ~before_append
      ~after_append:(fun () -> ()) ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~reason:"found another route" ~now:1200. with
   | Error (Keeper_ask_store.Withdraw_already_answered {answered_at}) ->
       Alcotest.(check (float 0.)) "the operator's winning answer time" 1100. answered_at
   | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error)
   | Ok () -> Alcotest.fail "a losing withdrawal was reported as accepted");
  match Keeper_ask_store.settled ~base_path ~keeper_name:keeper ~ask_id:"ask-1" with
  | Some (Keeper_ask.Answered_by {answers=[{response=Keeper_ask.Chose {choice_ids=[choice]};_}];_}) ->
      Alcotest.(check string) "the answer remains available for its wake" "a" choice
  | Some (Keeper_ask.Open | Keeper_ask.Withdrawn_because _)
  | Some (Keeper_ask.Answered_by _) | None -> Alcotest.fail "the winning answer was lost"

let a_racing_withdrawal_keeps_the_first_reason () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  let before_append () =
    match Keeper_ask_store.withdraw ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
        ~reason:"original reason" ~now:1100. with
    | Ok () -> ()
    | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error) in
  (match Keeper_ask_store.For_testing.withdraw_with_interleaving ~before_append
      ~after_append:(fun () -> ()) ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~reason:"later reason" ~now:1200. with
   | Error (Keeper_ask_store.Withdraw_already_withdrawn {withdrawn_at}) ->
       Alcotest.(check (float 0.)) "the first withdrawal wins" 1100. withdrawn_at
   | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error)
   | Ok () -> Alcotest.fail "a later withdrawal was acknowledged as the first");
  match Keeper_ask_store.settled ~base_path ~keeper_name:keeper ~ask_id:"ask-1" with
  | Some (Keeper_ask.Withdrawn_because {reason;_}) ->
      Alcotest.(check string) "the original reason remains" "original reason" reason
  | Some (Keeper_ask.Open | Keeper_ask.Answered_by _) | None ->
      Alcotest.fail "the first withdrawal was lost"

let identical_racing_withdrawals_confirm_the_same_outcome () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  let withdraw () = Keeper_ask_store.withdraw ~base_path ~keeper_name:keeper
      ~ask_id:"ask-1" ~reason:"done elsewhere" ~now:1100. in
  let before_append () = match withdraw () with
    | Ok () -> ()
    | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error) in
  (match Keeper_ask_store.For_testing.withdraw_with_interleaving ~before_append
      ~after_append:(fun () -> ()) ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~reason:"done elsewhere" ~now:1100. with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error));
  (match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
   | Ok (Keeper_ask_store.Stored_rows [_, (_, Keeper_ask.Withdrawn_because {reason;withdrawn_at})]) ->
       Alcotest.(check string) "one canonical outcome retains its reason" "done elsewhere" reason;
       Alcotest.(check (float 0.)) "and its timestamp" 1100. withdrawn_at
   | Ok _ | Error _ -> Alcotest.fail "matching withdrawals lost their canonical outcome");
  let path = Keeper_ask_store.log_path ~base_path ~keeper_name:keeper in
  let before = (Unix.stat path).Unix.st_size in
  (match withdraw () with
   | Error (Keeper_ask_store.Withdraw_already_withdrawn _) -> ()
   | Ok () -> Alcotest.fail "a settled preflight was treated as an overlapping request"
   | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error));
  Alcotest.(check int) "settled preflight appends nothing" before (Unix.stat path).Unix.st_size

let committed_withdrawal_without_a_terminal_row_is_unconfirmed ~missing () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  let path = Keeper_ask_store.log_path ~base_path ~keeper_name:keeper in
  let saved = path ^ ".committed" in
  let after_append () =
    Unix.rename path saved;
    if not missing then
      Out_channel.with_open_bin path (fun out ->
        output_string out (Yojson.Safe.to_string
          (Keeper_ask.event_to_json (Keeper_ask.Asked (an_ask ~ask_id:"ask-1"))) ^ "\n")) in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists saved then (
        if Sys.file_exists path then Unix.unlink path;
        Unix.rename saved path))
    (fun () ->
      match Keeper_ask_store.For_testing.withdraw_with_interleaving
          ~before_append:(fun () -> ()) ~after_append ~base_path ~keeper_name:keeper
          ~ask_id:"ask-1" ~reason:"done elsewhere" ~now:1100. with
      | Error (Keeper_ask_store.Withdraw_recorded_unconfirmed _) -> ()
      | Ok () -> Alcotest.fail "an absent canonical withdrawal became confirmed success"
      | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error));
  match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
  | Ok (Keeper_ask_store.Stored_rows [_, (_, Keeper_ask.Withdrawn_because _)]) -> ()
  | Ok _ | Error _ -> Alcotest.fail "confirmation failure changed the committed withdrawal"

let committed_withdrawal_with_unreadable_outcome_is_explicit () =
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
  (match Keeper_ask_store.For_testing.withdraw_with_interleaving
      ~before_append:(fun () -> ()) ~after_append ~base_path ~keeper_name:keeper ~ask_id:"ask-1"
      ~reason:"done elsewhere" ~now:1100. with
   | Error (Keeper_ask_store.Withdraw_recorded_unconfirmed _) -> ()
   | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error)
   | Ok () -> Alcotest.fail "an unreadable canonical outcome became withdrawal success");
  Unix.unlink path;
  Unix.rename saved path;
  match Keeper_ask_store.rows_result ~base_path ~keeper_name:keeper with
  | Ok (Keeper_ask_store.Stored_rows [_, (_, Keeper_ask.Withdrawn_because {reason;_})]) ->
      Alcotest.(check string) "the committed append survives a failed confirmation" "done elsewhere" reason
  | Ok _ | Error _ -> Alcotest.fail "the committed withdrawal did not survive"

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

let ask_status base_path arguments =
  let ctx : Mcp_tool_runtime_ask.context =
    { config = Workspace.default_config base_path; agent_name = keeper; arguments } in
  match Mcp_tool_runtime_ask.handle_ask_status ~tool_name:"masc_ask_status"
      ~start_time:(Tool_timing.start ()) ctx with
  | Some result -> result
  | None -> Alcotest.fail "Ask status did not handle its operation"

let ask_status_distinguishes_missing_questions_from_unreadable_history () =
  let base_path = temp_dir () in
  let missing = ask_status base_path (`Assoc []) in
  Alcotest.(check bool) "a missing log is a successful empty reading" true
    (Tool_result.is_success missing);
  let json = Yojson.Safe.from_string (Tool_result.message missing) in
  Alcotest.(check int) "no stored questions" 0
    Yojson.Safe.Util.(json |> member "open_count" |> to_int);
  record base_path "ask-1";
  append_raw base_path "{broken middle row}\n";
  record base_path "ask-2";
  let unreadable = ask_status base_path (`Assoc []) in
  Alcotest.(check bool) "damaged history cannot report an empty queue" false
    (Tool_result.is_success unreadable);
  Alcotest.(check bool) "the failure belongs to storage, not the request" true
    (Tool_result.failure_class unreadable = Some Tool_result.Runtime_failure)

let ask_status_counts_the_same_snapshot_it_filters () =
  let base_path = temp_dir () in
  record base_path "answered";
  record base_path "pending";
  (match Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id:"answered"
      ~submissions:["q1", Keeper_ask.Chose {choice_ids=["a"]}] ~responder ~now:1100. with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error));
  let result = ask_status base_path
      (`Assoc ["ask_id", `String "answered"; "include_resolved", `Bool true]) in
  Alcotest.(check bool) "resolved selection is readable" true (Tool_result.is_success result);
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  Alcotest.(check int) "open count covers the Keeper's whole snapshot" 1
    Yojson.Safe.Util.(json |> member "open_count" |> to_int);
  match Yojson.Safe.Util.(json |> member "asks" |> to_list) with
  | [row] ->
      Alcotest.(check string) "the requested resolved Ask remains selected" "answered"
        Yojson.Safe.Util.(row |> member "ask_id" |> to_string);
      Alcotest.(check string) "the canonical answer is reported" "answered"
        Yojson.Safe.Util.(row |> member "resolution" |> member "state" |> to_string)
  | _ -> Alcotest.fail "Ask status lost its requested canonical row"

let record_at base_path ~ask_id ~asked_at ~context =
  match Keeper_ask_store.record_ask ~base_path (an_ask_at ~ask_id ~asked_at ~context) with
  | Ok () -> ()
  | Error e -> fail_with "record_ask" e

let answer_ask base_path ask_id =
  match Keeper_ask_store.answer ~base_path ~keeper_name:keeper ~ask_id
      ~submissions:["q1", Keeper_ask.Chose {choice_ids=["a"]}] ~responder ~now:5000. with
  | Ok _ -> ()
  | Error error -> Alcotest.fail (Keeper_ask_store.answer_failure_to_string error)

let withdraw_ask base_path ask_id =
  match Keeper_ask_store.withdraw ~base_path ~keeper_name:keeper ~ask_id
      ~reason:"done elsewhere" ~now:5000. with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Keeper_ask_store.withdraw_failure_to_string error)

let status_json base_path arguments =
  let result = ask_status base_path arguments in
  Alcotest.(check bool) "the reading succeeds" true (Tool_result.is_success result);
  Yojson.Safe.from_string (Tool_result.message result)

let asked_ids json =
  Yojson.Safe.Util.(json |> member "asks" |> to_list
    |> List.map (fun row -> row |> member "ask_id" |> to_string))

let count json key = Yojson.Safe.Util.(json |> member key |> to_int)

(* The store keeps rows oldest first. A Keeper that reads its asks wants the
   open ones in the order it asked them, and after them the newest answers, so
   that is the order of the rows. *)
let ask_status_lists_open_asks_first_then_the_newest_resolved () =
  let base_path = temp_dir () in
  List.iter
    (fun (ask_id, asked_at) -> record_at base_path ~ask_id ~asked_at ~context:"why")
    ["old-open", 1000.; "old-answered", 2000.; "new-open", 3000.;
     "mid-withdrawn", 3500.; "new-answered", 4000.];
  answer_ask base_path "old-answered";
  answer_ask base_path "new-answered";
  withdraw_ask base_path "mid-withdrawn";
  let everything = status_json base_path (`Assoc ["include_resolved", `Bool true]) in
  Alcotest.(check (list string))
    "open asks first in the order asked, then resolved asks newest first"
    ["old-open"; "new-open"; "new-answered"; "mid-withdrawn"; "old-answered"]
    (asked_ids everything);
  Alcotest.(check int) "every ask matched" 5 (count everything "matching");
  Alcotest.(check int) "every ask fit" 5 (count everything "returned");
  let open_only = status_json base_path (`Assoc []) in
  Alcotest.(check (list string)) "without include_resolved only the open asks, in the order asked"
    ["old-open"; "new-open"] (asked_ids open_only);
  Alcotest.(check int) "the open count is the snapshot's" 2 (count open_only "open_count")

let ask_status_breaks_a_tie_on_asked_at_by_ask_id () =
  let base_path = temp_dir () in
  List.iter
    (fun (ask_id, asked_at) -> record_at base_path ~ask_id ~asked_at ~context:"why")
    ["b-open", 1000.; "a-open", 1000.; "d-done", 2000.; "c-done", 2000.];
  answer_ask base_path "d-done";
  answer_ask base_path "c-done";
  Alcotest.(check (list string)) "two asks at one time list in ask id order, open or resolved"
    ["a-open"; "b-open"; "c-done"; "d-done"]
    (asked_ids (status_json base_path (`Assoc ["include_resolved", `Bool true])))

(* In the 72 hours before 2026-11-11 08:40 KST, 83 calls with include_resolved
   returned the whole history, 25 became a blob preview of the oldest row, and
   in 11 of those the open asks at the end were out of view. The oldest ask is
   open here and 40 newer ones are answered, each about 2.5 KB, so the result
   has to leave rows out and still begin with the open one. *)
let ask_status_stops_under_the_inline_ceiling_and_keeps_the_open_ask_first () =
  let base_path = temp_dir () in
  let context = String.make 2000 'x' in
  record_at base_path ~ask_id:"the-oldest-is-open" ~asked_at:1.0 ~context;
  for index = 1 to 40 do
    let ask_id = Printf.sprintf "resolved-%02d" index in
    record_at base_path ~ask_id ~asked_at:(1000. +. float_of_int index) ~context;
    answer_ask base_path ask_id
  done;
  let result = ask_status base_path (`Assoc ["include_resolved", `Bool true]) in
  let message = Tool_result.message result in
  Alcotest.(check bool) "the result fits under the inline ceiling" true
    (String.length message <= Common.max_tool_result_wire_bytes);
  let json = Yojson.Safe.from_string message in
  (match asked_ids json with
   | first :: second :: _ ->
       Alcotest.(check string) "the oldest ask comes first because it is open"
         "the-oldest-is-open" first;
       Alcotest.(check string) "the newest resolved ask follows" "resolved-40" second
   | [] | [_] -> Alcotest.fail "the result names fewer than two asks");
  Alcotest.(check int) "matching counts the rows left out too" 41 (count json "matching");
  let returned = count json "returned" in
  Alcotest.(check bool) "some rows were left out" true (returned < 41);
  Alcotest.(check int) "returned counts the rows shown" returned (List.length (asked_ids json))

(* A result that named no ask would answer nothing, so one row stays even when
   it alone is over the ceiling. *)
let ask_status_keeps_one_row_when_it_alone_is_over_the_ceiling () =
  let base_path = temp_dir () in
  record_at base_path ~ask_id:"long-context" ~asked_at:1000.
    ~context:(String.make (2 * Common.max_tool_result_wire_bytes) 'y');
  let json = status_json base_path (`Assoc ["ask_id", `String "long-context"]) in
  Alcotest.(check (list string)) "the ask is still named" ["long-context"] (asked_ids json);
  Alcotest.(check int) "nothing that matched was left out" 1 (count json "matching")

let withdrawal_storage_failures_are_runtime_failures () =
  let base_path = temp_dir () in
  record base_path "ask-1";
  append_raw base_path "{broken middle row}\n";
  record base_path "ask-2";
  let ctx : Mcp_tool_runtime_ask.context =
    { config=Workspace.default_config base_path; agent_name=keeper;
      arguments=`Assoc ["ask_id", `String "ask-1"; "reason", `String "done elsewhere"] } in
  match Mcp_tool_runtime_ask.handle_ask_withdraw ~tool_name:"masc_ask_withdraw"
      ~start_time:(Tool_timing.start ()) ctx with
  | Some result ->
      Alcotest.(check bool) "storage damage is not a workflow refusal" true
        (Tool_result.failure_class result = Some Tool_result.Runtime_failure)
  | None -> Alcotest.fail "Ask withdrawal did not handle its operation"

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
          Alcotest.test_case "a racing answer prevents withdrawal acknowledgement" `Quick
            a_racing_answer_prevents_withdrawal_acknowledgement;
          Alcotest.test_case "a racing withdrawal retains the first reason" `Quick
            a_racing_withdrawal_keeps_the_first_reason;
          Alcotest.test_case "identical racing withdrawals confirm the same outcome" `Quick
            identical_racing_withdrawals_confirm_the_same_outcome;
          Alcotest.test_case "a committed withdrawal with a missing canonical row is unconfirmed" `Quick
            (committed_withdrawal_without_a_terminal_row_is_unconfirmed ~missing:true);
          Alcotest.test_case "a committed withdrawal with an open canonical row is unconfirmed" `Quick
            (committed_withdrawal_without_a_terminal_row_is_unconfirmed ~missing:false);
          Alcotest.test_case "committed withdrawal with unreadable outcome is explicit" `Quick
            committed_withdrawal_with_unreadable_outcome_is_explicit;
          Alcotest.test_case "withdrawal storage failures are runtime failures" `Quick
            withdrawal_storage_failures_are_runtime_failures;
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
      ( "Keeper status",
        [
          Alcotest.test_case "missing questions and unreadable history differ" `Quick
            ask_status_distinguishes_missing_questions_from_unreadable_history;
          Alcotest.test_case "the filter and count describe one snapshot" `Quick
            ask_status_counts_the_same_snapshot_it_filters;
          Alcotest.test_case "open asks first, then the newest resolved" `Quick
            ask_status_lists_open_asks_first_then_the_newest_resolved;
          Alcotest.test_case "a tie on asked_at is broken by ask id" `Quick
            ask_status_breaks_a_tie_on_asked_at_by_ask_id;
          Alcotest.test_case "the list stops under the inline ceiling" `Quick
            ask_status_stops_under_the_inline_ceiling_and_keeps_the_open_ask_first;
          Alcotest.test_case "one row stays even when it is over the ceiling" `Quick
            ask_status_keeps_one_row_when_it_alone_is_over_the_ceiling;
        ] );
    ]
