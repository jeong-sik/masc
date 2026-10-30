(** The recall evaluation record and the client edge: what is saved before a
    request goes out and after its answer comes back, what the flow is told
    when saving fails, and how the client's failure becomes the flow's. The
    client is a function the test passes in. *)

open Masc
module Eval = Keeper_memory_recall_evaluation
module Client = Typesafeai_client
module Types = Typesafeai_types
module Codec = Keeper_memory_recall_jev_codec
module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment
module C = Keeper_memory_recall_candidates
module T = Keeper_memory_os_types
module U = Yojson.Safe.Util

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let purpose = `Assoc [ "turn_input", `String "review the open pull request" ]
let api_key = "private-fixture-key"
let endpoint = "https://fixture.invalid/evaluate"
let destination : Client.destination = { endpoint; model = "fixture"; api_key }
let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-fixture" ~absolute_turn:7
let now = 1_700_000_000.0

(* ---- fixtures ---- *)

let candidate claim =
  C.of_fact
    (T.observed ~claim ~category:T.Lesson ~now ~origin:{ T.kind = T.Authored; trace_id = "trace" })

let two_candidates = [ candidate "the staging deploy needs a manual approval"; candidate "merge only squash" ]

let piece_of candidates =
  match C.split ~piece_bytes:max_int candidates with
  | piece :: _ -> piece
  | [] -> Alcotest.fail "no piece"

let guidance_for piece =
  Codec.load_guidance ~question_ids:(List.map C.id (C.piece_candidates piece))
let build_candidate_request ~purpose piece =
  let ( let* ) = Result.bind in
  let* guidance = guidance_for piece in Codec.candidate_request ~guidance ~purpose piece
let build_turn_request ~purpose =
  let ( let* ) = Result.bind in
  let* guidance = guidance_for (piece_of two_candidates) in Codec.turn_request ~guidance ~purpose
let build_time_request piece =
  let ( let* ) = Result.bind in
  let* guidance = guidance_for piece in Codec.time_request ~guidance piece

let built = function
  | Ok request -> request
  | Error (Codec.Duplicate_candidate_id id) -> Alcotest.failf "duplicate id %s" id
  | Error (Codec.Choice_set_invalid detail) -> Alcotest.failf "choice set invalid: %s" detail
  | Error (Codec.Guidance_unavailable detail) -> Alcotest.failf "guidance unavailable: %s" detail

let candidate_request () = built (build_candidate_request ~purpose (piece_of two_candidates))

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

let answers_for questions answer = List.map (fun (id, _) -> id, answer) questions

(* The first row of a judgment forces the rotation inside a protected section,
   so everything here runs in an Eio main loop. *)
let with_config f =
  Eio_main.run @@ fun _env ->
  let base = Filename.temp_dir "memory-recall-evaluation-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base)
    (fun () -> f (Workspace.default_config base))

let create_journal ?(keeper_id = "fixture") config =
  Eval.create ~config ~keeper_id ~turn_ref ~destinations:(destination, [])

let with_journal f = with_config (fun config -> f (create_journal config))

let read_rows path =
  Fs_compat.load_file path
  |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "")
  |> List.map Yojson.Safe.from_string

let field name row = U.member name row
let text name row = U.to_string (field name row)
let statuses rows = List.map (text "status") rows

(* The journal path becomes a directory, so the next write to it fails. *)
let break_journal journal =
  let path = Eval.journal_path journal in
  Unix.rename path (path ^ ".kept");
  Unix.mkdir path 0o700

let accepted_call ~destinations:_ ~state:_ ~questions () = Ok (evaluated (answers_for questions possibly))

(* ---- the rows of one request ---- *)

let test_the_request_is_saved_before_the_client_is_called () =
  with_journal (fun journal ->
    let request = candidate_request () in
    let calls = ref 0 in
    let call ~destinations:_ ~state ~questions () =
      incr calls;
      let rows = read_rows (Eval.journal_path journal) in
      let last = List.nth rows (List.length rows - 1) in
      Alcotest.(check string) "the last saved row precedes the call" "started" (text "status" last);
      Alcotest.(check json) "the exact state is saved" state (field "state" last);
      Alcotest.(check bool) "credentials are not in the row" false
        (String_util.contains_substring (Yojson.Safe.to_string last) api_key);
      Ok (evaluated (answers_for questions possibly))
    in
    (match Eval.evaluate_with ~call journal request with
     | Ok response -> Alcotest.(check string) "the client's response" "jev-fixture" response.model
     | Error _ -> Alcotest.fail "the request failed");
    Alcotest.(check int) "one call" 1 !calls;
    let rows = read_rows (Eval.journal_path journal) in
    Alcotest.(check (list string)) "started, then the response" [ "started"; "response_received" ]
      (statuses rows);
    List.iter
      (fun row ->
        Alcotest.(check string) "judgment id" (Eval.judgment_id journal) (text "judgment_id" row);
        Alcotest.(check json) "turn ref" (Ids.Turn_ref.to_yojson turn_ref) (field "turn_ref" row);
        Alcotest.(check string) "question kind" "candidates" (text "kind" row))
      rows;
    (match rows with
     | [ started; received ] ->
       Alcotest.(check string) "one request id" (text "request_id" started) (text "request_id" received);
       let response = field "response" received in
       Alcotest.(check string) "model" "jev-fixture" (text "model" response);
       Alcotest.(check int) "input tokens" 12 (U.to_int (U.member "input_tokens" (field "usage" response)));
       Alcotest.(check (list string)) "an answer for each question"
         (List.map fst request.questions)
         (List.map fst (U.to_assoc (field "answers" response)))
     | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "expected two rows"))

let test_each_row_names_its_question () =
  with_journal (fun journal ->
    let piece = piece_of two_candidates in
    let requests =
      [ built (build_candidate_request ~purpose piece)
      ; built (build_turn_request ~purpose)
      ; built (build_time_request piece)
      ]
    in
    List.iter
      (fun request ->
        match Eval.evaluate_with ~call:accepted_call journal request with
        | Ok _ -> ()
        | Error _ -> Alcotest.fail "the request failed")
      requests;
    Alcotest.(check (list string)) "kinds in order"
      [ "candidates"; "candidates"; "turn"; "turn"; "time"; "time" ]
      (List.map (text "kind") (read_rows (Eval.journal_path journal))))

let test_a_request_that_cannot_be_saved_is_not_sent () =
  with_journal (fun journal ->
    Fs_compat.mkdir_p (Eval.journal_path journal);
    let call ~destinations:_ ~state:_ ~questions:_ () = Alcotest.fail "an unsaved request was sent" in
    match Eval.evaluate_with ~call journal (candidate_request ()) with
    | Error Flow.Not_recorded -> ()
    | Error _ | Ok _ -> Alcotest.fail "expected Not_recorded")

let test_a_response_that_cannot_be_saved_is_dropped () =
  with_journal (fun journal ->
    let call ~destinations:_ ~state:_ ~questions () =
      break_journal journal;
      Ok (evaluated (answers_for questions possibly))
    in
    match Eval.evaluate_with ~call journal (candidate_request ()) with
    | Error Flow.Not_recorded -> ()
    | Error _ | Ok _ -> Alcotest.fail "an unsaved response was used")

let test_a_cancelled_request_leaves_a_cancelled_row_and_is_raised_again () =
  with_journal (fun journal ->
    let raised = Eio.Cancel.Cancelled (Failure "stopped") in
    let call ~destinations:_ ~state:_ ~questions:_ () = raise raised in
    Alcotest.check_raises "the cancellation is raised again" raised (fun () ->
      ignore (Eval.evaluate_with ~call journal (candidate_request ())));
    Alcotest.(check (list string)) "started, then cancelled" [ "started"; "cancelled" ]
      (statuses (read_rows (Eval.journal_path journal))))

(* The context really is cancelled here, so a row written without protection
   from the cancellation would be refused. *)
let test_the_cancelled_row_is_saved_inside_a_cancelled_context () =
  with_journal (fun journal ->
    let never, _unused = Eio.Promise.create () in
    let call ~destinations:_ ~state:_ ~questions:_ () = Eio.Promise.await never in
    Eio.Fiber.first
      (fun () -> ignore (Eval.evaluate_with ~call journal (candidate_request ())))
      (fun () -> Eio.Fiber.yield ());
    Alcotest.(check (list string)) "started, then cancelled" [ "started"; "cancelled" ]
      (statuses (read_rows (Eval.journal_path journal))))

(* ---- the client's failure ---- *)

let attempt refusal : Client.attempt = { destination_uri = endpoint; model = "fixture"; refusal }

let http status body =
  attempt (Client.Http_response_failure { status; body; destination_uri = endpoint; detail = "fixture" })

let transport = attempt (Client.Transport_failure "offline")
let capacity_body = {|{"detail":{"error_type":"max_tokens_exceeded"}}|}

let failure first later : Client.failure = { first_attempt = first; later_attempts = later }

let test_the_client_failure_becomes_the_flow_failure () =
  let cases =
    [ "capacity: every destination says so", failure (http 400 capacity_body) [ http 400 capacity_body ], "capacity_refused"
    ; "429 from the only destination", failure (http 429 "") [], "rate_limited"
    ; "429 from every destination", failure (http 429 "") [ http 429 "" ], "rate_limited"
    ; "200 that does not decode", failure (http 200 "not json") [], "invalid_response"
    ; "200 from every destination", failure (http 200 "{}") [ http 200 "not json" ], "invalid_response"
    ; "429 mixed with another status", failure (http 429 "") [ http 500 "" ], "failed"
    ; "429 mixed with a 200", failure (http 429 "") [ http 200 "{}" ], "failed"
    ; "a 200 and a transport failure", failure (http 200 "{}") [ transport ], "failed"
    ; "a transport failure", failure transport [], "failed"
    ; "400 with another body", failure (http 400 "too long") [], "failed"
    ; "capacity mixed with 429", failure (http 400 capacity_body) [ http 429 "" ], "failed"
    ; "a server error", failure (http 503 "") [], "failed"
    ]
  in
  List.iter
    (fun (label, failure, expected) ->
      Alcotest.(check string) label expected
        (Flow.attempt_failure_token (Eval.attempt_failure_of_client_failure failure)))
    cases

let test_a_failed_request_is_saved_and_classified () =
  with_journal (fun journal ->
    let call ~destinations:_ ~state:_ ~questions:_ () = Error (failure (http 429 "slow down") []) in
    (match Eval.evaluate_with ~call journal (candidate_request ()) with
     | Error Flow.Rate_limited -> ()
     | Error _ | Ok _ -> Alcotest.fail "expected Rate_limited");
    let rows = read_rows (Eval.journal_path journal) in
    Alcotest.(check (list string)) "started, then the failure" [ "started"; "provider_failed" ] (statuses rows);
    match rows with
    | [ _; failed ] ->
      Alcotest.(check bool) "the failure is saved" true (field "failure" failed <> `Null)
    | [] | [ _ ] | _ :: _ :: _ :: _ -> Alcotest.fail "expected two rows")

(* The client's own bug is not a cancellation and not a failure the flow knows:
   it is raised again, and its request stays open in the journal. *)
let test_an_exception_that_is_not_a_cancellation_leaves_the_request_open () =
  with_journal (fun journal ->
    let call ~destinations:_ ~state:_ ~questions:_ () = failwith "client bug" in
    Alcotest.check_raises "the exception is raised again" (Failure "client bug") (fun () ->
      ignore (Eval.evaluate_with ~call journal (candidate_request ())));
    Alcotest.(check (list string)) "only started is saved" [ "started" ]
      (statuses (read_rows (Eval.journal_path journal))))

(* ---- metrics ---- *)

(* The metric store is shared by every test of this process, so each test counts
   under a Keeper of its own. *)
let counter name labels =
  Option.value ~default:0.0 (Otel_metric_store.get_metric_value name ~labels ())

let requests ~keeper ~kind ~result =
  counter
    Keeper_metrics.(to_string MemoryRecallRequests)
    [ "keeper", keeper; "kind", kind; "result", result ]

let input_bytes ~keeper =
  counter Keeper_metrics.(to_string MemoryRecallInputBytes) [ "keeper", keeper ]

let timed_requests ~keeper ~kind =
  counter
    (Otel_metric_store.histogram_count_name Keeper_metrics.(to_string MemoryRecallRequestSeconds))
    [ "keeper", keeper; "kind", kind ]

let with_keeper_journal keeper f =
  with_config (fun config -> f (create_journal ~keeper_id:keeper config))

let first_line path =
  match String.split_on_char '\n' (Fs_compat.load_file path) with
  | line :: _ -> line
  | [] -> Alcotest.fail "no row"

let test_a_request_is_counted_sized_and_timed () =
  let keeper = "metrics-answered" in
  with_keeper_journal keeper (fun journal ->
    ignore (Eval.evaluate_with ~call:accepted_call journal (candidate_request ()));
    Alcotest.(check (float 0.0)) "one answered request of the candidates question" 1.0
      (requests ~keeper ~kind:"candidates" ~result:"answered");
    Alcotest.(check (float 0.0)) "the size of the started row, with its newline"
      (Float.of_int (String.length (first_line (Eval.journal_path journal)) + 1))
      (input_bytes ~keeper);
    Alcotest.(check (float 0.0)) "one sample of the time" 1.0
      (timed_requests ~keeper ~kind:"candidates"))

let test_each_question_kind_is_counted_on_its_own () =
  let keeper = "metrics-kinds" in
  with_keeper_journal keeper (fun journal ->
    let piece = piece_of two_candidates in
    List.iter
      (fun request -> ignore (Eval.evaluate_with ~call:accepted_call journal request))
      [ built (build_candidate_request ~purpose piece)
      ; built (build_turn_request ~purpose)
      ; built (build_time_request piece)
      ; built (build_time_request piece)
      ];
    List.iter
      (fun (kind, expected) ->
        Alcotest.(check (float 0.0)) kind expected (requests ~keeper ~kind ~result:"answered"))
      [ "candidates", 1.0; "turn", 1.0; "time", 2.0 ])

let test_a_failed_request_is_counted_by_its_failure () =
  List.iter
    (fun (result, client_failure) ->
      let keeper = "metrics-failed-" ^ result in
      with_keeper_journal keeper (fun journal ->
        let call ~destinations:_ ~state:_ ~questions:_ () = Error client_failure in
        ignore (Eval.evaluate_with ~call journal (candidate_request ()));
        Alcotest.(check (float 0.0)) result 1.0 (requests ~keeper ~kind:"candidates" ~result);
        Alcotest.(check (float 0.0)) (result ^ " is not counted as answered") 0.0
          (requests ~keeper ~kind:"candidates" ~result:"answered");
        Alcotest.(check (float 0.0)) (result ^ " is timed") 1.0
          (timed_requests ~keeper ~kind:"candidates")))
    [ "capacity_refused", failure (http 400 capacity_body) []
    ; "rate_limited", failure (http 429 "") []
    ; "invalid_response", failure (http 200 "not json") []
    ; "failed", failure transport []
    ]

let test_a_request_that_was_not_sent_has_no_size_and_no_time () =
  let keeper = "metrics-not-sent" in
  with_keeper_journal keeper (fun journal ->
    Fs_compat.mkdir_p (Eval.journal_path journal);
    let call ~destinations:_ ~state:_ ~questions:_ () = Alcotest.fail "an unsaved request was sent" in
    ignore (Eval.evaluate_with ~call journal (candidate_request ()));
    Alcotest.(check (float 0.0)) "counted as not recorded" 1.0
      (requests ~keeper ~kind:"candidates" ~result:"not_recorded");
    Alcotest.(check (float 0.0)) "no input was saved" 0.0 (input_bytes ~keeper);
    Alcotest.(check (float 0.0)) "no call was timed" 0.0 (timed_requests ~keeper ~kind:"candidates"))

let test_a_dropped_response_is_counted_as_not_recorded_after_it_was_timed () =
  let keeper = "metrics-dropped" in
  with_keeper_journal keeper (fun journal ->
    let call ~destinations:_ ~state:_ ~questions () =
      break_journal journal;
      Ok (evaluated (answers_for questions possibly))
    in
    ignore (Eval.evaluate_with ~call journal (candidate_request ()));
    Alcotest.(check (float 0.0)) "counted as not recorded" 1.0
      (requests ~keeper ~kind:"candidates" ~result:"not_recorded");
    Alcotest.(check (float 0.0)) "not as answered" 0.0
      (requests ~keeper ~kind:"candidates" ~result:"answered");
    Alcotest.(check bool) "the request was sent, so its input was counted" true (input_bytes ~keeper > 0.0);
    Alcotest.(check (float 0.0)) "and its call timed" 1.0 (timed_requests ~keeper ~kind:"candidates"))

let test_a_cancelled_request_is_counted_and_not_timed () =
  let keeper = "metrics-cancelled" in
  with_keeper_journal keeper (fun journal ->
    let call ~destinations:_ ~state:_ ~questions:_ () = raise (Eio.Cancel.Cancelled (Failure "stopped")) in
    (try ignore (Eval.evaluate_with ~call journal (candidate_request ())) with
     | Eio.Cancel.Cancelled _ -> ());
    Alcotest.(check (float 0.0)) "counted as cancelled" 1.0
      (requests ~keeper ~kind:"candidates" ~result:"cancelled");
    Alcotest.(check (float 0.0)) "a cancelled call has no time" 0.0
      (timed_requests ~keeper ~kind:"candidates");
    Alcotest.(check bool) "its input was counted" true (input_bytes ~keeper > 0.0))

(* ---- rotation ---- *)

let with_max_bytes value f =
  let name = "MASC_KEEPER_METRICS_MAX_BYTES" in
  let before = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value before ~default:"10485760"))
    f

let test_a_full_journal_is_rotated_once_before_the_first_row_of_a_judgment () =
  with_max_bytes "100" (fun () ->
    with_config (fun config ->
      let first = create_journal config in
      ignore (Eval.evaluate_with ~call:accepted_call first (candidate_request ()));
      let path = Eval.journal_path first in
      Alcotest.(check int) "the first judgment wrote two rows" 2 (List.length (read_rows path));
      let second = create_journal config in
      ignore (Eval.evaluate_with ~call:accepted_call second (candidate_request ()));
      ignore (Eval.evaluate_with ~call:accepted_call second (candidate_request ()));
      let ids rows = List.sort_uniq String.compare (List.map (text "judgment_id") rows) in
      Alcotest.(check (list string)) "the rotated file holds the first judgment only"
        [ Eval.judgment_id first ] (ids (read_rows (path ^ ".1")));
      let current = read_rows path in
      Alcotest.(check int) "the second judgment's rows are together" 4 (List.length current);
      Alcotest.(check (list string)) "and only its own" [ Eval.judgment_id second ] (ids current)))

(* A rotation that cannot be done is a journal that cannot be kept: nothing is
   sent and every request of the judgment counts as not recorded. *)
let test_a_journal_that_cannot_be_rotated_sends_nothing () =
  with_max_bytes "100" (fun () ->
    with_config (fun config ->
      let first = create_journal config in
      ignore (Eval.evaluate_with ~call:accepted_call first (candidate_request ()));
      Unix.mkdir (Eval.journal_path first ^ ".1") 0o700;
      let second = create_journal config in
      let call ~destinations:_ ~state:_ ~questions:_ () = Alcotest.fail "a request was sent" in
      List.iter
        (fun () ->
          match Eval.evaluate_with ~call second (candidate_request ()) with
          | Error Flow.Not_recorded -> ()
          | Error _ | Ok _ -> Alcotest.fail "expected Not_recorded")
        [ (); () ];
      Alcotest.(check int) "the second judgment wrote nothing" 2
        (List.length (read_rows (Eval.journal_path first)))))

(* ---- the outcome ---- *)

(* The client answers by the shape of the request: this stands in for Jev. *)
let scripted_call ~destinations:_ ~state ~questions () =
  let is_candidate_question =
    match state with
    | `Assoc fields -> List.mem_assoc "purpose" fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
  in
  let is_turn_question = List.map fst questions = [ "turn" ] in
  let first_candidate = C.id (List.hd two_candidates) in
  let answer (id, _) =
    id,
    if is_turn_question then yes
    else if is_candidate_question then (if String.equal id first_candidate then possibly else unrelated)
    else standing
  in
  Ok (evaluated (List.map answer questions))

let judged_of journal =
  match Flow.run ~evaluate:(Eval.evaluate_with ~call:scripted_call journal) ~purpose two_candidates with
  | Ok (Some judged) -> judged
  | Ok None | Error _ -> Alcotest.fail "expected a judgment"

let test_the_outcome_is_saved_as_the_last_row () =
  with_journal (fun journal ->
    let judged = judged_of journal in
    let retained = Eval.retain_outcome journal judged in
    Alcotest.(check bool) "the judgment is used as it was" true (retained = judged);
    let rows = read_rows (Eval.journal_path journal) in
    Alcotest.(check (list string)) "three requests, each started and answered, then the outcome"
      [ "judgment_completed"; "response_received"; "response_received"; "response_received"
      ; "started"; "started"; "started" ]
      (List.sort String.compare (statuses rows));
    let last = List.nth rows (List.length rows - 1) in
    let first_id = C.id (List.hd two_candidates) and second_id = C.id (List.nth two_candidates 1) in
    Alcotest.(check json) "the outcome"
      (`Assoc
         [ "status", `String "selected"
         ; "judged", `Int 2
         ; "total", `Int 2
         ; "selected", `List [ `String first_id ]
         ; "turn_question_contradicted", `Bool false
         ; "turn", `String "yes"
         ; ( "results"
           , `List
               [ `Assoc [ "id", `String first_id; "decision", `String "possibly_needed" ]
               ; `Assoc [ "id", `String second_id; "decision", `String "not_needed" ]
               ] )
         ; "marks", `List [ `Assoc [ "id", `String first_id; "mark", `String "standing" ] ]
         ])
      (field "outcome" last);
    Alcotest.(check string) "the outcome row carries the judgment id" (Eval.judgment_id journal)
      (text "judgment_id" last))

let test_a_judgment_whose_outcome_cannot_be_saved_is_not_used () =
  with_journal (fun journal ->
    let judged = judged_of journal in
    break_journal journal;
    let retained = Eval.retain_outcome journal judged in
    Alcotest.(check string) "unavailable, not recorded" "unavailable"
      (J.status_token retained.status);
    Alcotest.(check bool) "every candidate is undecided as not recorded" true
      (List.for_all
         (function
           | J.Undecided { id = _; reason = J.Not_recorded } -> true
           | J.Undecided { id = _; reason = _ } | J.Decided _ -> false)
         retained.results);
    Alcotest.(check bool) "nothing of the old judgment is kept" true
      (retained.marks = [] && retained.turn = J.Turn_question_failed))

let () =
  Alcotest.run "keeper_memory_recall_evaluation"
    [ ( "request rows"
      , [ Alcotest.test_case "the request is saved before the client is called" `Quick
            test_the_request_is_saved_before_the_client_is_called
        ; Alcotest.test_case "each row names its question" `Quick test_each_row_names_its_question
        ; Alcotest.test_case "a request that cannot be saved is not sent" `Quick
            test_a_request_that_cannot_be_saved_is_not_sent
        ; Alcotest.test_case "a response that cannot be saved is dropped" `Quick
            test_a_response_that_cannot_be_saved_is_dropped
        ; Alcotest.test_case "a cancelled request leaves a cancelled row and is raised again" `Quick
            test_a_cancelled_request_leaves_a_cancelled_row_and_is_raised_again
        ; Alcotest.test_case "the cancelled row is saved inside a cancelled context" `Quick
            test_the_cancelled_row_is_saved_inside_a_cancelled_context
        ; Alcotest.test_case "an exception that is not a cancellation leaves the request open" `Quick
            test_an_exception_that_is_not_a_cancellation_leaves_the_request_open
        ] )
    ; ( "metrics"
      , [ Alcotest.test_case "a request is counted, sized and timed" `Quick
            test_a_request_is_counted_sized_and_timed
        ; Alcotest.test_case "each question kind is counted on its own" `Quick
            test_each_question_kind_is_counted_on_its_own
        ; Alcotest.test_case "a failed request is counted by its failure" `Quick
            test_a_failed_request_is_counted_by_its_failure
        ; Alcotest.test_case "a request that was not sent has no size and no time" `Quick
            test_a_request_that_was_not_sent_has_no_size_and_no_time
        ; Alcotest.test_case "a dropped response is counted as not recorded after it was timed" `Quick
            test_a_dropped_response_is_counted_as_not_recorded_after_it_was_timed
        ; Alcotest.test_case "a cancelled request is counted and not timed" `Quick
            test_a_cancelled_request_is_counted_and_not_timed
        ] )
    ; ( "client failure"
      , [ Alcotest.test_case "the client failure becomes the flow failure" `Quick
            test_the_client_failure_becomes_the_flow_failure
        ; Alcotest.test_case "a failed request is saved and classified" `Quick
            test_a_failed_request_is_saved_and_classified
        ] )
    ; ( "journal"
      , [ Alcotest.test_case "a full journal is rotated once before the first row of a judgment" `Quick
            test_a_full_journal_is_rotated_once_before_the_first_row_of_a_judgment
        ; Alcotest.test_case "a journal that cannot be rotated sends nothing" `Quick
            test_a_journal_that_cannot_be_rotated_sends_nothing
        ; Alcotest.test_case "the outcome is saved as the last row" `Quick
            test_the_outcome_is_saved_as_the_last_row
        ; Alcotest.test_case "a judgment whose outcome cannot be saved is not used" `Quick
            test_a_judgment_whose_outcome_cannot_be_saved_is_not_used
        ] )
    ]
