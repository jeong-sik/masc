(** The recall judgment of one turn: who is judged, what is saved and counted,
    and when a judgment is given back. The client is a function the test passes
    in. *)

open Masc
module Turn = Keeper_memory_recall_turn
module Eval = Keeper_memory_recall_evaluation
module Types = Typesafeai_types
module Client = Typesafeai_client
module Codec = Keeper_memory_recall_jev_codec
module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment
module C = Keeper_memory_recall_candidates
module T = Keeper_memory_os_types
module U = Yojson.Safe.Util

let purpose = `Assoc [ "turn_input", `String "review the open pull request" ]
let destination : Client.destination = { endpoint = "https://fixture.invalid/evaluate"; model = "fixture"; api_key = "private-fixture-key" }
let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-fixture" ~absolute_turn:7
let next_turn_ref = Ids.Turn_ref.make ~trace_id:"trace-fixture" ~absolute_turn:8
let now = 1_700_000_000.0

(* ---- fixtures ---- *)

let candidate claim =
  C.of_fact
    (T.observed ~claim ~category:T.Lesson ~now ~origin:{ T.kind = T.Authored; trace_id = "trace" })

let first_candidate = candidate "the staging deploy needs a manual approval"
let second_candidate = candidate "merge only squash"
let two_candidates = [ first_candidate; second_candidate ]
let extra_candidate = candidate "the release branch is frozen on Fridays"

let choice label probabilities =
  Types.Choice_answer { choice = label; probabilities; confidence = 0.9 }

let possibly = choice "possibly_needed" [ "possibly_needed", 0.8; "not_needed", 0.2 ]
let unrelated = choice "not_needed" [ "possibly_needed", 0.3; "not_needed", 0.7 ]
let yes = choice "yes" [ "yes", 0.7; "no", 0.2; "unsure", 0.1 ]
let standing = choice "standing" [ "standing", 0.9; "time_bound", 0.1 ]

let evaluated answers : Client.evaluated =
  { response =
      { Types.model = "jev-fixture"
      ; answers
      ; usage = Some { Types.input_tokens = 12; output_tokens = 3 }
      }
  ; destination = Client.identify destination
  ; request_body_sha256 = "fixture-request"
  ; passed_over = []
  }

(* The client answers by the shape of the request: this stands in for Jev. It
   carries the candidates [carries] says. *)
let scripted ~carries ~destinations:_ ~state ~questions () =
  let is_candidate_question =
    match state with
    | `Assoc fields -> List.mem_assoc "purpose" fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
  in
  let is_turn_question = List.map fst questions = [ "turn" ] in
  let answer (id, _) =
    id,
    if is_turn_question then yes
    else if is_candidate_question then (if carries id then possibly else unrelated)
    else standing
  in
  Ok (evaluated (List.map answer questions))

let answering = scripted ~carries:(String.equal (C.id first_candidate))
let carrying_nothing = scripted ~carries:(fun _ -> false)

let transport_failure : Client.failure =
  { first_attempt = { destination_uri = "https://fixture.invalid/evaluate"; model = "fixture"; refusal = Client.Transport_failure "offline" }
  ; later_attempts = []
  }

let failing ~destinations:_ ~state:_ ~questions:_ () = Error transport_failure

(* ---- setup ---- *)

let recall scope =
  { Runtime_schema.default_typesafeai with memory_recall = Runtime_schema.Memory_recall_on scope }

let everybody = recall Runtime_schema.All_keepers

(* Every judgment forces a rotation inside a protected section, so everything
   here runs in an Eio main loop. *)
let with_config f =
  Eio_main.run @@ fun _env ->
  let base = Filename.temp_dir "memory-recall-turn-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base)
    (fun () -> f (Workspace.default_config base))

let with_recall_setup ?(policy = everybody) ?(key = Some "synthetic-jev-key") f =
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" key (fun () ->
    Masc_test_deps.with_typesafeai_policy policy (fun () -> with_config f))

(* The calls the test's client was asked for, whichever judgment asked. *)
let counting call =
  let calls = ref 0 in
  (fun ~destinations ~state ~questions () ->
     incr calls;
     call ~destinations ~state ~questions ()),
  calls

let judge ~call ~memo config ~keeper_id ?(turn_ref = turn_ref) ?(candidates = two_candidates) () =
  Turn.judge_with
    ~evaluate:(fun record -> Eval.evaluate_with ~call record)
    ~memo
    ~config
    ~keeper_id
    ~turn_ref
    ~purpose
    candidates

let journal_path config ~keeper_id =
  Eval.journal_path (Eval.create ~config ~keeper_id ~turn_ref ~destinations:(destination, []))

let rows config ~keeper_id =
  let path = journal_path config ~keeper_id in
  if Sys.file_exists path
  then
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> line <> "")
    |> List.map Yojson.Safe.from_string
  else []

let statuses rows = List.map (fun row -> U.to_string (U.member "status" row)) rows

let judged_of = function
  | Ok (Turn.Judged judged) -> judged
  | Ok (Turn.Off _) -> Alcotest.fail "the keeper was not judged"
  | Ok Turn.Nothing_to_judge -> Alcotest.fail "nothing to judge"
  | Error _ -> Alcotest.fail "a request could not be built"

(* ---- metrics ---- *)

(* The metric store is shared by every test of this process, so each test
   counts under a Keeper of its own. *)
let counter name labels =
  Option.value ~default:0.0 (Otel_metric_store.get_metric_value name ~labels ())

let judgments ~keeper ~outcome =
  counter Keeper_metrics.(to_string MemoryRecallTotal) [ "keeper", keeper; "outcome", outcome ]

let selected ~keeper =
  counter Keeper_metrics.(to_string MemoryRecallSelected) [ "keeper", keeper ]

let timed ~keeper =
  counter
    (Otel_metric_store.histogram_count_name Keeper_metrics.(to_string MemoryRecallJudgmentSeconds))
    [ "keeper", keeper ]

(* The histogram's sum. A judgment saves several rows, each with an fsync, so
   its time is never zero. *)
let seconds_sum ~keeper =
  counter Keeper_metrics.(to_string MemoryRecallJudgmentSeconds) [ "keeper", keeper ]

let all_outcomes = [ "selected"; "none_found"; "none_needed"; "unavailable" ]

let total_judgments ~keeper =
  List.fold_left (fun sum outcome -> sum +. judgments ~keeper ~outcome) 0.0 all_outcomes

(* ---- who is judged ---- *)

let off_reason = function
  | Ok (Turn.Off reason) -> Typesafeai_config.unavailable_reason_to_string reason
  | Ok (Turn.Judged _) -> "judged"
  | Ok Turn.Nothing_to_judge -> "nothing to judge"
  | Error _ -> "error"

let test_a_keeper_that_is_not_judged_sends_and_saves_nothing () =
  let cases =
    [ "the switch is off by default", Runtime_schema.default_typesafeai, Some "synthetic-jev-key", "memory_recall_disabled"
    ; "the keeper is outside the list"
      , recall (Runtime_schema.Listed_keepers ("someone-else", [])), Some "synthetic-jev-key", "memory_recall_disabled"
    ; "the keeper is excluded"
      , { everybody with Runtime_schema.excluded_keepers = [ "not-judged" ] }, Some "synthetic-jev-key", "keeper_excluded"
    ; "the lane is off"
      , { everybody with Runtime_schema.lane_enabled = false }, Some "synthetic-jev-key", "lane_disabled"
    ; "no key", everybody, None, "no_armed_destination"
    ]
  in
  List.iter
    (fun (label, policy, key, expected) ->
      with_recall_setup ~policy ~key (fun config ->
        let call, calls = counting answering in
        let keeper_id = "not-judged" in
        let memo = Turn.create_memo () in
        Alcotest.(check string) label expected (off_reason (judge ~call ~memo config ~keeper_id ()));
        Alcotest.(check int) (label ^ ": nothing was sent") 0 !calls;
        Alcotest.(check bool) (label ^ ": nothing was saved") false
          (Sys.file_exists (journal_path config ~keeper_id));
        Alcotest.(check (float 0.0)) (label ^ ": nothing was counted") 0.0
          (total_judgments ~keeper:keeper_id)))
    cases

let test_a_keeper_without_candidates_has_nothing_to_judge () =
  with_recall_setup (fun config ->
    let call, calls = counting answering in
    let keeper_id = "no-candidates" in
    (match judge ~call ~memo:(Turn.create_memo ()) config ~keeper_id ~candidates:[] () with
     | Ok Turn.Nothing_to_judge -> ()
     | Ok (Turn.Off _ | Turn.Judged _) | Error _ -> Alcotest.fail "expected nothing to judge");
    Alcotest.(check int) "nothing was sent" 0 !calls;
    Alcotest.(check (list string)) "nothing was saved" [] (statuses (rows config ~keeper_id));
    Alcotest.(check (float 0.0)) "nothing was counted" 0.0 (total_judgments ~keeper:keeper_id))

(* ---- the judgment ---- *)

let test_a_judgment_is_saved_and_counted () =
  with_recall_setup (fun config ->
    let call, calls = counting answering in
    let keeper_id = "judged" in
    let judged = judged_of (judge ~call ~memo:(Turn.create_memo ()) config ~keeper_id ()) in
    Alcotest.(check string) "the first candidate is carried" "selected" (J.status_token judged.status);
    (match judged.status with
     | J.Selected { selection; coverage = _; turn_question_contradicted = _ } ->
       Alcotest.(check (list string)) "and only it" [ C.id first_candidate ] (J.selection_ids selection)
     | J.None_found _ | J.None_needed _ | J.Unavailable _ -> Alcotest.fail "expected selected");
    Alcotest.(check int) "three requests were sent" 3 !calls;
    let saved = rows config ~keeper_id in
    Alcotest.(check string) "the last row is the outcome" "judgment_completed"
      (U.to_string (U.member "status" (List.nth saved (List.length saved - 1))));
    Alcotest.(check (float 0.0)) "counted as selected" 1.0 (judgments ~keeper:keeper_id ~outcome:"selected");
    Alcotest.(check (float 0.0)) "and as nothing else" 1.0 (total_judgments ~keeper:keeper_id);
    Alcotest.(check (float 0.0)) "one candidate was carried" 1.0 (selected ~keeper:keeper_id);
    Alcotest.(check (float 0.0)) "one sample of the judgment time" 1.0 (timed ~keeper:keeper_id);
    Alcotest.(check bool) "and the time is measured, not zero" true (seconds_sum ~keeper:keeper_id > 0.0))

let test_a_judgment_that_carries_two_candidates_counts_both () =
  with_recall_setup (fun config ->
    let keeper_id = "carries-two" in
    let judged =
      judged_of
        (judge ~call:(scripted ~carries:(fun _ -> true)) ~memo:(Turn.create_memo ()) config ~keeper_id ())
    in
    Alcotest.(check string) "selected" "selected" (J.status_token judged.status);
    Alcotest.(check (float 0.0)) "both candidates were carried" 2.0 (selected ~keeper:keeper_id))

let test_a_judgment_that_carries_nothing_is_counted_without_a_selection () =
  with_recall_setup (fun config ->
    let keeper_id = "carries-nothing" in
    let judged = judged_of (judge ~call:carrying_nothing ~memo:(Turn.create_memo ()) config ~keeper_id ()) in
    Alcotest.(check string) "none found" "none_found" (J.status_token judged.status);
    Alcotest.(check (float 0.0)) "counted as none found" 1.0 (judgments ~keeper:keeper_id ~outcome:"none_found");
    Alcotest.(check (float 0.0)) "no selection was counted" 0.0 (selected ~keeper:keeper_id))

(* ---- the rest of the turn ---- *)

let test_the_judgment_is_given_back_for_the_rest_of_its_turn () =
  with_recall_setup (fun config ->
    let call, calls = counting answering in
    let keeper_id = "same-turn" in
    let memo = Turn.create_memo () in
    let first = judged_of (judge ~call ~memo config ~keeper_id ()) in
    let sent = !calls and saved = List.length (rows config ~keeper_id) in
    let again =
      judged_of (judge ~call ~memo config ~keeper_id ~candidates:(extra_candidate :: two_candidates) ())
    in
    Alcotest.(check bool) "the same judgment, whatever the candidates of the second call" true (first = again);
    Alcotest.(check int) "nothing more was sent" sent !calls;
    Alcotest.(check int) "nothing more was saved" saved (List.length (rows config ~keeper_id));
    Alcotest.(check (float 0.0)) "and it is not counted twice" 1.0 (total_judgments ~keeper:keeper_id))

let test_another_turn_judges_again_and_replaces_the_kept_judgment () =
  with_recall_setup (fun config ->
    let call, calls = counting answering in
    let keeper_id = "next-turn" in
    let memo = Turn.create_memo () in
    ignore (judge ~call ~memo config ~keeper_id ());
    let after_first = !calls in
    ignore (judge ~call ~memo config ~keeper_id ~turn_ref:next_turn_ref ());
    Alcotest.(check int) "another turn asks again" (2 * after_first) !calls;
    Alcotest.(check (float 0.0)) "and is counted" 2.0 (total_judgments ~keeper:keeper_id);
    ignore (judge ~call ~memo config ~keeper_id ());
    Alcotest.(check int) "the memo holds one judgment, so the earlier turn asks again too"
      (3 * after_first) !calls)

(* The turn owns its memo: a judgment kept in one is not given back from another. *)
let test_a_memo_belongs_to_its_turn () =
  with_recall_setup (fun config ->
    let call, calls = counting answering in
    ignore (judge ~call ~memo:(Turn.create_memo ()) config ~keeper_id:"memo-one" ());
    let after_first = !calls in
    ignore (judge ~call ~memo:(Turn.create_memo ()) config ~keeper_id:"memo-two" ());
    Alcotest.(check int) "another memo is judged on its own" (2 * after_first) !calls)

let test_an_unavailable_judgment_is_asked_again_in_its_turn () =
  with_recall_setup (fun config ->
    let keeper_id = "unavailable" in
    let memo = Turn.create_memo () in
    let failed = judged_of (judge ~call:failing ~memo config ~keeper_id ()) in
    Alcotest.(check string) "nothing was judged" "unavailable" (J.status_token failed.status);
    Alcotest.(check (float 0.0)) "counted as unavailable" 1.0 (judgments ~keeper:keeper_id ~outcome:"unavailable");
    Alcotest.(check (float 0.0)) "no selection" 0.0 (selected ~keeper:keeper_id);
    let call, calls = counting answering in
    let retried = judged_of (judge ~call ~memo config ~keeper_id ()) in
    Alcotest.(check string) "the retry in the same turn asks again" "selected" (J.status_token retried.status);
    Alcotest.(check bool) "and sent requests" true (!calls > 0);
    let sent = !calls in
    ignore (judge ~call ~memo config ~keeper_id ());
    Alcotest.(check int) "the judgment that worked is kept" sent !calls)

let test_a_judgment_whose_outcome_cannot_be_saved_is_not_kept () =
  with_recall_setup (fun config ->
    let keeper_id = "not-recorded" in
    Fs_compat.mkdir_p (journal_path config ~keeper_id);
    let call, calls = counting answering in
    let memo = Turn.create_memo () in
    let judged = judged_of (judge ~call ~memo config ~keeper_id ()) in
    Alcotest.(check string) "unavailable" "unavailable" (J.status_token judged.status);
    Alcotest.(check int) "nothing was sent without a record" 0 !calls;
    Alcotest.(check string) "the reason" "not_recorded"
      (match judged.status with
       | J.Unavailable unavailable -> J.unavailable_reason_token unavailable
       | J.Selected _ | J.None_found _ | J.None_needed _ -> "usable");
    Alcotest.(check (float 0.0)) "counted as unavailable" 1.0 (judgments ~keeper:keeper_id ~outcome:"unavailable");
    ignore (judge ~call ~memo config ~keeper_id ());
    Alcotest.(check (float 0.0)) "and asked again in the same turn" 2.0 (judgments ~keeper:keeper_id ~outcome:"unavailable"))

let test_the_gate_is_checked_before_a_kept_judgment_is_given_back () =
  let keeper_id = "gate-first" in
  with_recall_setup (fun config ->
    let call, _calls = counting answering in
    let memo = Turn.create_memo () in
    ignore (judged_of (judge ~call ~memo config ~keeper_id ()));
    Masc_test_deps.with_typesafeai_policy Runtime_schema.default_typesafeai (fun () ->
      Alcotest.(check string) "a switch turned off stops the next call of the turn"
        "memory_recall_disabled" (off_reason (judge ~call ~memo config ~keeper_id ())));
    ignore (judged_of (judge ~call ~memo config ~keeper_id ())))

(* ---- what goes wrong ---- *)

let test_two_candidates_with_one_id_are_refused_before_anything_is_sent () =
  with_recall_setup (fun config ->
    let call, calls = counting answering in
    let keeper_id = "duplicate" in
    (match judge ~call ~memo:(Turn.create_memo ()) config ~keeper_id ~candidates:[ first_candidate; first_candidate ] () with
     | Error (Codec.Duplicate_candidate_id id) ->
       Alcotest.(check string) "the id" (C.id first_candidate) id
     | Error (Codec.Choice_set_invalid _) | Ok _ -> Alcotest.fail "expected a duplicate id");
    Alcotest.(check int) "nothing was sent" 0 !calls;
    Alcotest.(check (float 0.0)) "nothing was counted" 0.0 (total_judgments ~keeper:keeper_id))

let test_a_cancellation_builds_nothing_keeps_nothing_and_counts_nothing () =
  with_recall_setup (fun config ->
    let keeper_id = "cancelled" in
    let memo = Turn.create_memo () in
    let cancelling ~destinations:_ ~state:_ ~questions:_ () =
      raise (Eio.Cancel.Cancelled (Failure "stopped"))
    in
    (try ignore (judge ~call:cancelling ~memo config ~keeper_id ()) with
     | Eio.Cancel.Cancelled _ | Eio.Exn.Multiple _ -> ());
    Alcotest.(check (float 0.0)) "nothing was counted" 0.0 (total_judgments ~keeper:keeper_id);
    let call, calls = counting answering in
    ignore (judge ~call ~memo config ~keeper_id ());
    Alcotest.(check bool) "the retry in the same turn asks again" true (!calls > 0))

let () =
  Alcotest.run "keeper_memory_recall_turn"
    [ ( "who is judged"
      , [ Alcotest.test_case "a keeper that is not judged sends and saves nothing" `Quick
            test_a_keeper_that_is_not_judged_sends_and_saves_nothing
        ; Alcotest.test_case "a keeper without candidates has nothing to judge" `Quick
            test_a_keeper_without_candidates_has_nothing_to_judge
        ] )
    ; ( "judgment"
      , [ Alcotest.test_case "a judgment is saved and counted" `Quick test_a_judgment_is_saved_and_counted
        ; Alcotest.test_case "a judgment that carries two candidates counts both" `Quick
            test_a_judgment_that_carries_two_candidates_counts_both
        ; Alcotest.test_case "a judgment that carries nothing is counted without a selection" `Quick
            test_a_judgment_that_carries_nothing_is_counted_without_a_selection
        ] )
    ; ( "the rest of the turn"
      , [ Alcotest.test_case "the judgment is given back for the rest of its turn" `Quick
            test_the_judgment_is_given_back_for_the_rest_of_its_turn
        ; Alcotest.test_case "another turn judges again and replaces the kept judgment" `Quick
            test_another_turn_judges_again_and_replaces_the_kept_judgment
        ; Alcotest.test_case "a memo belongs to its turn" `Quick test_a_memo_belongs_to_its_turn
        ; Alcotest.test_case "an unavailable judgment is asked again in its turn" `Quick
            test_an_unavailable_judgment_is_asked_again_in_its_turn
        ; Alcotest.test_case "a judgment whose outcome cannot be saved is not kept" `Quick
            test_a_judgment_whose_outcome_cannot_be_saved_is_not_kept
        ; Alcotest.test_case "the gate is checked before a kept judgment is given back" `Quick
            test_the_gate_is_checked_before_a_kept_judgment_is_given_back
        ] )
    ; ( "failures"
      , [ Alcotest.test_case "two candidates with one id are refused before anything is sent" `Quick
            test_two_candidates_with_one_id_are_refused_before_anything_is_sent
        ; Alcotest.test_case "a cancellation builds nothing, keeps nothing and counts nothing" `Quick
            test_a_cancellation_builds_nothing_keeps_nothing_and_counts_nothing
        ] )
    ]
