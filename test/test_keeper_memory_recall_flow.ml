(** The recall judgment flow: which requests go out, in which order, and what a
    refused or failed request comes to. The client is a scripted function; the
    expected values are written out by hand. *)

open Masc
module J = Keeper_memory_recall_judgment
module C = Keeper_memory_recall_candidates
module Codec = Keeper_memory_recall_jev_codec
module Flow = Keeper_memory_recall_flow
module T = Keeper_memory_os_types
module Types = Typesafeai_types

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let purpose = `Assoc [ "turn_input", `String "review the open pull request" ]
let now = 1_700_000_000.0

let fact claim =
  T.observed ~claim ~category:T.Lesson ~now ~origin:{ T.kind = T.Authored; trace_id = "trace" }

let line_overhead = 191

(* A candidate whose line is exactly [size] bytes. *)
let sized index size =
  let tag = string_of_int index in
  C.of_fact (fact (String.make (size - line_overhead - String.length tag) 'x' ^ tag))

let small = 300
let huge = 6_000

(* ---- the scripted client ---- *)

let choice label probabilities confidence =
  Types.Choice_answer { choice = label; probabilities; confidence }

let possibly = choice "possibly_needed" [ "possibly_needed", 0.8; "not_needed", 0.2 ] 0.9
let unrelated = choice "not_needed" [ "possibly_needed", 0.3; "not_needed", 0.7 ] 0.9
let yes = choice "yes" [ "yes", 0.7; "no", 0.2; "unsure", 0.1 ] 0.9
let no = choice "no" [ "yes", 0.1; "no", 0.8; "unsure", 0.1 ] 0.9
let standing = choice "standing" [ "standing", 0.9; "time_bound", 0.1 ] 0.9
let time_bound = choice "time_bound" [ "standing", 0.2; "time_bound", 0.8 ] 0.9
let response answers = { Types.model = "jev-test"; answers; usage = None }

type kind = Codec.request_kind =
  | Candidate_question
  | Turn_question
  | Time_question

let kind_of (request : Codec.request) = request.kind

type call =
  { kind : kind
  ; ids : string list
  ; state : Yojson.Safe.t
  }

let ids_of (request : Codec.request) = List.map fst request.questions

let purpose_of call =
  match call.state with
  | `Assoc fields -> List.assoc_opt "purpose" fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

type script =
  { candidates : string list -> (Types.eval_response, Flow.attempt_failure) result
  ; turn : (Types.eval_response, Flow.attempt_failure) result
  ; time : string list -> (Types.eval_response, Flow.attempt_failure) result
  }

let answer_all answer ids = Ok (response (List.map (fun id -> id, answer) ids))

let accepting =
  { candidates = answer_all possibly
  ; turn = Ok (response [ "turn", yes ])
  ; time = answer_all standing
  }

let evaluator log script : Flow.evaluate =
 fun request ->
  let ids = List.map fst request.questions in
  log := { kind = kind_of request; ids; state = request.state } :: !log;
  match kind_of request with
  | Candidate_question -> script.candidates ids
  | Turn_question -> script.turn
  | Time_question -> script.time ids

let run_flow ?piece_bytes script candidates =
  Eio_main.run @@ fun _env ->
  let log = ref [] in
  let result = Flow.run ~evaluate:(evaluator log script) ~purpose ?piece_bytes candidates in
  result, List.rev !log

(* ---- reading a result ---- *)

let names candidates =
  let table = List.mapi (fun index candidate -> C.id candidate, "c" ^ string_of_int index) candidates in
  fun id -> List.assoc id table

let describe_result name = function
  | J.Decided { id; decision } -> name id ^ ":" ^ J.candidate_decision_label decision
  | J.Undecided { id; reason } -> name id ^ ":" ^ J.unjudged_reason_token reason

let describe_status name status =
  let coverage = J.status_coverage status in
  let detail =
    match status with
    | J.Selected { selection; coverage = _; turn_question_contradicted } ->
      " [" ^ String.concat "," (List.map name (J.selection_ids selection)) ^ "]"
      ^ if turn_question_contradicted then " contradicted" else ""
    | J.Unavailable unavailable -> " " ^ J.unavailable_reason_token unavailable
    | J.None_found _ | J.None_needed _ -> ""
  in
  Printf.sprintf "%s %d/%d%s" (J.status_token status) (J.coverage_judged coverage)
    (J.coverage_total coverage) detail

let describe_mark name (id, mark) =
  name id ^ ":" ^ match mark with J.Marked nature -> J.time_nature_label nature | J.Time_unjudged -> "unjudged"

let describe_call name call =
  let kind = match call.kind with Candidate_question -> "a" | Turn_question -> "b" | Time_question -> "c" in
  match call.kind with
  | Turn_question -> kind
  | Candidate_question | Time_question -> kind ^ "[" ^ String.concat "," (List.map name call.ids) ^ "]"

let judged_of = function
  | Ok (Some judged) -> judged
  | Ok None -> Alcotest.fail "expected a judgment"
  | Error (Codec.Duplicate_candidate_id id) -> Alcotest.failf "duplicate id %s" id
  | Error (Codec.Choice_set_invalid detail) -> Alcotest.failf "choice set invalid: %s" detail

let calls_of_kind kind calls = List.filter (fun call -> call.kind = kind) calls

let rendered_calls candidates kind calls =
  List.map (describe_call (names candidates)) (calls_of_kind kind calls)

let check_strings label expected actual = Alcotest.(check (list string)) label expected actual
let sorted strings = List.sort String.compare strings

(* ---- tests ---- *)

(* The sizes in the tests are line bytes, so a change of [line_overhead] would
   change what they test without failing. *)
let test_sized_candidates_have_the_line_bytes_they_are_named_for () =
  List.iter
    (fun (index, size) ->
      Alcotest.(check int) (Printf.sprintf "candidate %d" index) size (C.line_bytes (sized index size)))
    [ 0, small; 7, 451; 12, 450; 3, huge ]

let test_no_candidates_send_nothing () =
  let result, calls = run_flow accepting [] in
  Alcotest.(check bool) "no judgment" true (result = Ok None);
  Alcotest.(check int) "no call" 0 (List.length calls)

let test_everything_taken () =
  let candidates = List.init 3 (fun index -> sized index small) in
  let name = names candidates in
  let id_of index = C.id (List.nth candidates index) in
  let script =
    { accepting with
      candidates =
        (fun ids -> Ok (response (List.map (fun id -> id, if id = id_of 1 then unrelated else possibly) ids)))
    ; time = (fun ids -> Ok (response (List.map (fun id -> id, if id = id_of 0 then standing else time_bound) ids)))
    }
  in
  let result, calls = run_flow script candidates in
  let judged = judged_of result in
  check_strings "results" [ "c0:possibly_needed"; "c1:not_needed"; "c2:possibly_needed" ]
    (List.map (describe_result name) judged.results);
  Alcotest.(check string) "status" "selected 3/3 [c0,c2]" (describe_status name judged.status);
  Alcotest.(check bool) "turn answered yes" true (judged.turn = J.Turn_answered J.Needs_knowledge);
  check_strings "marks" [ "c0:standing"; "c2:time_bound" ] (List.map (describe_mark name) judged.marks);
  check_strings "one request each for (a) and (b), then (c)"
    [ "a[c0,c1,c2]"; "b"; "c[c0,c2]" ]
    (sorted (List.map (describe_call name) calls));
  (match List.rev calls with
   | last :: _ -> Alcotest.(check bool) "(c) goes last" true (last.kind = Time_question)
   | [] -> Alcotest.fail "no call")

let test_purpose_goes_to_question_a_and_b_and_not_to_c () =
  let candidates = [ sized 0 small ] in
  let result, calls = run_flow accepting candidates in
  ignore (judged_of result);
  List.iter
    (fun call ->
      match call.kind with
      | Candidate_question | Turn_question ->
        Alcotest.(check (option json)) "purpose as given" (Some purpose) (purpose_of call)
      | Time_question -> Alcotest.(check (option json)) "no purpose" None (purpose_of call))
    calls

let test_nothing_carried_asks_no_time_question () =
  let candidates = List.init 3 (fun index -> sized index small) in
  let name = names candidates in
  let none_carried = { accepting with candidates = answer_all unrelated } in
  let result, calls = run_flow none_carried candidates in
  let judged = judged_of result in
  Alcotest.(check string) "yes" "none_found 3/3" (describe_status name judged.status);
  Alcotest.(check int) "no (c)" 0 (List.length (calls_of_kind Time_question calls));
  check_strings "no marks" [] (List.map (describe_mark name) judged.marks);
  let turn_no = { none_carried with turn = Ok (response [ "turn", no ]) } in
  let judged = judged_of (fst (run_flow turn_no candidates)) in
  Alcotest.(check string) "no" "none_needed 3/3" (describe_status name judged.status)

let test_a_carried_candidate_wins_over_a_no () =
  let candidates = [ sized 0 small ] in
  let name = names candidates in
  let judged = judged_of (fst (run_flow { accepting with turn = Ok (response [ "turn", no ]) } candidates)) in
  Alcotest.(check string) "selected, contradicted" "selected 1/1 [c0] contradicted"
    (describe_status name judged.status)

let refuse_over limit ids =
  if List.length ids > limit then Error Flow.Capacity_refused else answer_all possibly ids

let test_a_refused_piece_is_cut_in_two_and_the_halves_go_in_order () =
  let candidates = List.init 4 (fun index -> sized index small) in
  let name = names candidates in
  let result, calls =
    run_flow ~piece_bytes:(4 * small) { accepting with candidates = refuse_over 2 } candidates
  in
  let judged = judged_of result in
  check_strings "(a) requests" [ "a[c0,c1,c2,c3]"; "a[c0,c1]"; "a[c2,c3]" ]
    (rendered_calls candidates Candidate_question calls);
  check_strings "results in candidate order"
    [ "c0:possibly_needed"; "c1:possibly_needed"; "c2:possibly_needed"; "c3:possibly_needed" ]
    (List.map (describe_result name) judged.results);
  Alcotest.(check string) "status" "selected 4/4 [c0,c1,c2,c3]" (describe_status name judged.status)

let refuse_ids refused ids =
  if List.exists (fun id -> List.mem id refused) ids then Error Flow.Capacity_refused
  else answer_all possibly ids

(* c0 and c2 are small and c1 is too large to be judged: a piece holding it is
   refused. *)
let one_huge_candidate () = [ sized 0 small; sized 1 huge; sized 2 small ]

let test_a_lone_candidate_the_server_refuses_is_too_large_when_it_took_the_purpose () =
  let candidates = one_huge_candidate () in
  let name = names candidates in
  let refused = [ C.id (List.nth candidates 1) ] in
  let result, calls =
    run_flow ~piece_bytes:(huge + (2 * small)) { accepting with candidates = refuse_ids refused } candidates
  in
  let judged = judged_of result in
  check_strings "(a) requests" [ "a[c0,c1,c2]"; "a[c0]"; "a[c1]"; "a[c2]" ]
    (rendered_calls candidates Candidate_question calls);
  check_strings "results" [ "c0:possibly_needed"; "c1:too_large"; "c2:possibly_needed" ]
    (List.map (describe_result name) judged.results);
  Alcotest.(check string) "status" "selected 2/3 [c0,c2]" (describe_status name judged.status);
  check_strings "(c) holds what each answered request carried" [ "c[c0]"; "c[c2]" ]
    (sorted (rendered_calls candidates Time_question calls))

let test_a_lone_candidate_is_capacity_when_question_b_failed_another_way () =
  let candidates = [ sized 0 small; sized 1 huge ] in
  let name = names candidates in
  let refused = [ C.id (List.nth candidates 1) ] in
  List.iter
    (fun failure ->
      let script = { accepting with candidates = refuse_ids refused; turn = Error failure } in
      let judged = judged_of (fst (run_flow ~piece_bytes:(huge + small) script candidates)) in
      check_strings "results" [ "c0:possibly_needed"; "c1:capacity" ] (List.map (describe_result name) judged.results);
      Alcotest.(check string) "status" "selected 1/2 [c0]" (describe_status name judged.status);
      Alcotest.(check bool) "(b) counted as failed" true (judged.turn = J.Turn_question_failed))
    [ Flow.Rate_limited; Flow.Failed; Flow.Not_recorded ]

let test_a_response_that_does_not_decode_still_shows_the_purpose_fits () =
  let candidates = [ sized 0 small; sized 1 huge ] in
  let name = names candidates in
  let refused = [ C.id (List.nth candidates 1) ] in
  let script = { accepting with candidates = refuse_ids refused; turn = Error Flow.Invalid_response } in
  let judged = judged_of (fst (run_flow ~piece_bytes:(huge + small) script candidates)) in
  check_strings "results" [ "c0:possibly_needed"; "c1:too_large" ] (List.map (describe_result name) judged.results);
  Alcotest.(check bool) "(b) counted as failed" true (judged.turn = J.Turn_question_failed)

(* The request of (a) waits until (b) has been refused, so the flow knows the
   purpose is too large when it would cut the piece. *)
let test_a_purpose_that_is_too_large_stops_everything () =
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  Eio_main.run @@ fun _env ->
  let log = ref [] in
  let turn_refused, resolve_turn_refused = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    log := { kind = kind_of request; ids = List.map fst request.questions; state = request.state } :: !log;
    match kind_of request with
    | Turn_question ->
      Eio.Promise.resolve resolve_turn_refused ();
      Error Flow.Capacity_refused
    | Candidate_question ->
      Eio.Promise.await turn_refused;
      Error Flow.Capacity_refused
    | Time_question -> Alcotest.fail "no candidate was carried"
  in
  let judged = judged_of (Flow.run ~evaluate ~purpose ~piece_bytes:(2 * small) candidates) in
  let calls = List.rev !log in
  check_strings "one request of (a), no halves" [ "a[c0,c1]" ] (rendered_calls candidates Candidate_question calls);
  check_strings "results" [ "c0:capacity"; "c1:capacity" ] (List.map (describe_result name) judged.results);
  Alcotest.(check string) "status" "unavailable 0/2 capacity" (describe_status name judged.status)

let test_the_other_failures_leave_only_their_piece_undecided_and_are_not_retried () =
  let candidates = List.init 5 (fun index -> sized index small) in
  let name = names candidates in
  let by_candidate ids =
    match List.map name ids with
    | [ "c0" ] -> Error Flow.Rate_limited
    | [ "c1" ] -> Error Flow.Invalid_response
    | [ "c2" ] -> Error Flow.Failed
    | [ "c3" ] -> Error Flow.Not_recorded
    | _ -> answer_all possibly ids
  in
  let result, calls = run_flow ~piece_bytes:small { accepting with candidates = by_candidate } candidates in
  let judged = judged_of result in
  check_strings "results"
    [ "c0:rate_limited"; "c1:invalid_answer"; "c2:provider_failed"; "c3:not_recorded"; "c4:possibly_needed" ]
    (List.map (describe_result name) judged.results);
  Alcotest.(check string) "status" "selected 1/5 [c4]" (describe_status name judged.status);
  check_strings "each piece once" [ "a[c0]"; "a[c1]"; "a[c2]"; "a[c3]"; "a[c4]" ]
    (sorted (rendered_calls candidates Candidate_question calls))

(* A judgment whose own record could not be saved is replaced as a whole: what
   the model answered is not kept. *)
let test_not_recorded_replaces_the_whole_judgment () =
  let candidates = List.init 3 (fun index -> sized index small) in
  let name = names candidates in
  let judged = judged_of (fst (run_flow ~piece_bytes:small accepting candidates)) in
  Alcotest.(check string) "before" "selected 3/3 [c0,c1,c2]" (describe_status name judged.status);
  Alcotest.(check bool) "it had marks" true (judged.marks <> []);
  let replaced = Flow.not_recorded judged in
  check_strings "results"
    [ "c0:not_recorded"; "c1:not_recorded"; "c2:not_recorded" ]
    (List.map (describe_result name) replaced.results);
  Alcotest.(check string) "status" "unavailable 0/3 not_recorded" (describe_status name replaced.status);
  Alcotest.(check bool) "question (b) counts as failed" true (replaced.turn = J.Turn_question_failed);
  Alcotest.(check int) "no marks" 0 (List.length replaced.marks)

let test_an_answer_that_does_not_decode_leaves_only_that_candidate () =
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  let bad = choice "possibly_needed" [ "possibly_needed", 0.4; "not_needed", 0.6 ] 0.5 in
  let first = C.id (List.hd candidates) in
  let script =
    { accepting with
      candidates = (fun ids -> Ok (response (List.map (fun id -> id, if id = first then bad else possibly) ids)))
    }
  in
  let judged = judged_of (fst (run_flow script candidates)) in
  check_strings "results" [ "c0:invalid_answer"; "c1:possibly_needed" ] (List.map (describe_result name) judged.results);
  check_strings "(c) asked for the one carried" [ "c1:standing" ] (List.map (describe_mark name) judged.marks)

let test_a_time_question_that_fails_is_unjudged_and_never_cut () =
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  List.iter
    (fun failure ->
      let result, calls = run_flow { accepting with time = (fun _ -> Error failure) } candidates in
      let judged = judged_of result in
      check_strings "marks" [ "c0:unjudged"; "c1:unjudged" ] (List.map (describe_mark name) judged.marks);
      Alcotest.(check int) "one (c) request" 1 (List.length (calls_of_kind Time_question calls));
      Alcotest.(check string) "the status is not touched" "selected 2/2 [c0,c1]" (describe_status name judged.status))
    [ Flow.Capacity_refused; Flow.Rate_limited; Flow.Invalid_response; Flow.Failed; Flow.Not_recorded ]

let test_a_time_answer_that_does_not_decode_is_unjudged () =
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  let bad = choice "standing" [ "standing", 0.3; "time_bound", 0.7 ] 0.5 in
  let second = C.id (List.nth candidates 1) in
  let script =
    { accepting with time = (fun ids -> Ok (response (List.map (fun id -> id, if id = second then bad else time_bound) ids))) }
  in
  let judged = judged_of (fst (run_flow script candidates)) in
  check_strings "marks" [ "c0:time_bound"; "c1:unjudged" ] (List.map (describe_mark name) judged.marks)

let test_a_time_question_is_asked_for_each_answered_piece_with_its_carried_candidates () =
  let candidates = List.init 4 (fun index -> sized index small) in
  let name = names candidates in
  let carried = List.map (fun index -> C.id (List.nth candidates index)) [ 0; 2 ] in
  let script =
    { accepting with
      candidates = (fun ids -> Ok (response (List.map (fun id -> id, if List.mem id carried then possibly else unrelated) ids)))
    ; time = (fun ids -> Ok (response (List.map (fun id -> id, if id = List.hd carried then standing else time_bound) ids)))
    }
  in
  let result, calls = run_flow ~piece_bytes:(2 * small) script candidates in
  let judged = judged_of result in
  check_strings "(c) requests" [ "c[c0]"; "c[c2]" ] (sorted (rendered_calls candidates Time_question calls));
  check_strings "marks in candidate order" [ "c0:standing"; "c2:time_bound" ]
    (List.map (describe_mark name) judged.marks)

let test_a_duplicate_stops_before_anything_is_sent () =
  let same = sized 0 small in
  List.iter
    (fun (label, piece_bytes) ->
      let result, calls = run_flow ~piece_bytes accepting [ same; sized 1 small; same ] in
      (match result with
       | Error (Codec.Duplicate_candidate_id id) -> Alcotest.(check string) label (C.id same) id
       | Error (Codec.Choice_set_invalid detail) -> Alcotest.fail detail
       | Ok _ -> Alcotest.failf "%s: judged a list with a duplicate" label);
      Alcotest.(check int) (label ^ ": nothing sent") 0 (List.length calls))
    [ "one piece", 10 * small; "two pieces apart", small ]

(* Every candidate is refused alone, so the cut runs to the end. *)
let test_requests_of_a_piece_that_is_refused_down_to_one_candidate_are_bounded () =
  List.iter
    (fun count ->
      let candidates = List.init count (fun index -> sized index small) in
      let name = names candidates in
      let script = { accepting with candidates = (fun _ -> Error Flow.Capacity_refused) } in
      let result, calls = run_flow ~piece_bytes:(count * small) script candidates in
      let judged = judged_of result in
      let requests = List.length (calls_of_kind Candidate_question calls) in
      Alcotest.(check bool) (Printf.sprintf "%d candidates take %d requests, at most %d" count requests ((2 * count) - 1))
        true (requests <= (2 * count) - 1);
      check_strings "every candidate is too large"
        (List.mapi (fun index _ -> Printf.sprintf "c%d:too_large" index) candidates)
        (List.map (describe_result name) judged.results))
    [ 1; 2; 3; 5; 8; 13 ]

let test_eight_candidates_refused_alone_take_fifteen_requests () =
  let candidates = List.init 8 (fun index -> sized index small) in
  let script = { accepting with candidates = (fun _ -> Error Flow.Capacity_refused) } in
  let _, calls = run_flow ~piece_bytes:(8 * small) script candidates in
  Alcotest.(check int) "1 + 2 + 4 + 8" 15 (List.length (calls_of_kind Candidate_question calls))

(* The halves are built by another call than the first requests. *)
let test_the_halves_carry_the_purpose () =
  let candidates = List.init 4 (fun index -> sized index small) in
  let _, calls = run_flow ~piece_bytes:(4 * small) { accepting with candidates = refuse_over 2 } candidates in
  let requests_of_a = calls_of_kind Candidate_question calls in
  Alcotest.(check int) "the piece and its two halves" 3 (List.length requests_of_a);
  List.iter
    (fun call -> Alcotest.(check (option json)) "purpose as given" (Some purpose) (purpose_of call))
    requests_of_a

(* The cut is at the floor of half the line bytes. 300 + 451 is one byte over
   750 and 300 + 450 is exactly 750. *)
let test_the_cut_is_at_half_the_line_bytes_for_sizes_that_differ () =
  let candidates = List.mapi (fun index size -> sized index size) [ 300; 451; 300; 450 ] in
  let _, calls = run_flow ~piece_bytes:1501 { accepting with candidates = refuse_over 2 } candidates in
  check_strings "(a) requests" [ "a[c0,c1,c2,c3]"; "a[c0]"; "a[c1]"; "a[c2,c3]" ]
    (rendered_calls candidates Candidate_question calls)

(* The tests above send a failing piece of one candidate. *)
let test_a_piece_of_several_candidates_that_fails_another_way_leaves_all_of_them () =
  List.iter
    (fun (failure, token) ->
      let candidates = List.init 3 (fun index -> sized index small) in
      let name = names candidates in
      let result, _ =
        run_flow ~piece_bytes:(3 * small) { accepting with candidates = (fun _ -> Error failure) } candidates
      in
      let judged = judged_of result in
      check_strings "results" (List.init 3 (fun index -> Printf.sprintf "c%d:%s" index token))
        (List.map (describe_result name) judged.results);
      Alcotest.(check string) "status" ("unavailable 0/3 " ^ token) (describe_status name judged.status))
    [ Flow.Rate_limited, "rate_limited"
    ; Flow.Invalid_response, "invalid_answer"
    ; Flow.Failed, "provider_failed"
    ; Flow.Not_recorded, "not_recorded"
    ]

(* A 200 for (b) that nobody can read is a request the server took. The test
   with [Error Invalid_response] builds that case through the client failure
   only. *)
let test_a_200_for_question_b_that_does_not_decode_shows_the_purpose_fits () =
  let candidates = [ sized 0 small; sized 1 huge ] in
  let name = names candidates in
  let refused = [ C.id (List.nth candidates 1) ] in
  let script = { accepting with candidates = refuse_ids refused; turn = Ok (response []) } in
  let judged = judged_of (fst (run_flow ~piece_bytes:(huge + small) script candidates)) in
  check_strings "results" [ "c0:possibly_needed"; "c1:too_large" ] (List.map (describe_result name) judged.results);
  Alcotest.(check bool) "(b) counted as failed" true (judged.turn = J.Turn_question_failed)

(* [turn] is a field the next layer reads. A (b) refused for size is a question
   without an answer, never [Unsure]. *)
let test_question_b_refused_for_size_is_a_question_without_an_answer () =
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  let script =
    { accepting with candidates = (fun _ -> Error Flow.Capacity_refused); turn = Error Flow.Capacity_refused }
  in
  let judged = judged_of (fst (run_flow ~piece_bytes:(2 * small) script candidates)) in
  Alcotest.(check bool) "no answer" true (judged.turn = J.Turn_question_failed);
  Alcotest.(check string) "status" "unavailable 0/2 capacity" (describe_status name judged.status)

(* ---- concurrency ---- *)

let within_five_seconds env f = Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 f

(* The evaluator yields twice in each request of (a), so a half that starts
   before the one in front of it has ended shows in the order of the events. *)
let test_a_half_starts_after_the_one_before_it_has_ended () =
  Eio_main.run @@ fun env ->
  let candidates = List.init 4 (fun index -> sized index small) in
  let name = names candidates in
  let events = ref [] in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    let ids = ids_of request in
    match kind_of request with
    | Turn_question -> accepting.turn
    | Time_question -> answer_all standing ids
    | Candidate_question ->
      let label = String.concat "," (List.map name ids) in
      events := ("start " ^ label) :: !events;
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      events := ("end " ^ label) :: !events;
      refuse_over 2 ids
  in
  ignore
    (judged_of
       (within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose ~piece_bytes:(4 * small) candidates)));
  check_strings "one after the other"
    [ "start c0,c1,c2,c3"; "end c0,c1,c2,c3"; "start c0,c1"; "end c0,c1"; "start c2,c3"; "end c2,c3" ]
    (List.rev !events)

(* The cut does not wait for (b), which keeps the judgment short. Here (b)
   answers only after every request of (a) has come back. *)
let test_the_cut_does_not_wait_for_question_b () =
  Eio_main.run @@ fun env ->
  let candidates = List.init 4 (fun index -> sized index small) in
  let name = names candidates in
  let answered = ref 0 in
  let all_answered, resolve_all_answered = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    let ids = ids_of request in
    match kind_of request with
    | Turn_question ->
      Eio.Promise.await all_answered;
      accepting.turn
    | Time_question -> answer_all standing ids
    | Candidate_question ->
      incr answered;
      (* The piece and its two halves are the three requests of (a). *)
      if !answered = 3 then Eio.Promise.resolve resolve_all_answered ();
      refuse_over 2 ids
  in
  let judged =
    judged_of
      (within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose ~piece_bytes:(4 * small) candidates))
  in
  Alcotest.(check string) "status" "selected 4/4 [c0,c1,c2,c3]" (describe_status name judged.status)

(* Question (b) has not answered when the lone candidate is refused. The
   reason is known only after (b) has answered, so it waits. *)
let test_a_lone_candidate_refused_before_question_b_answers_waits_for_it () =
  Eio_main.run @@ fun env ->
  let candidates = [ sized 0 small ] in
  let name = names candidates in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    match kind_of request with
    | Candidate_question -> Error Flow.Capacity_refused
    | Turn_question ->
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      accepting.turn
    | Time_question -> Alcotest.fail "no candidate was carried"
  in
  let judged = judged_of (within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose candidates)) in
  check_strings "results" [ "c0:too_large" ] (List.map (describe_result name) judged.results)

(* Each request of (a) and (b) waits until all three have started, so the flow
   that sends them one after the other cannot finish. *)
let test_the_pieces_and_question_b_go_out_at_the_same_time () =
  Eio_main.run @@ fun env ->
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  let started = ref 0 in
  let all_started, resolve_all_started = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    let ids = List.map fst request.questions in
    match kind_of request with
    | Time_question -> answer_all standing ids
    | Candidate_question | Turn_question as kind ->
      incr started;
      if !started = 3 then Eio.Promise.resolve resolve_all_started ();
      Eio.Promise.await all_started;
      (match kind with
       | Turn_question -> accepting.turn
       | Candidate_question | Time_question -> answer_all possibly ids)
  in
  let result = within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose ~piece_bytes:small candidates) in
  let judged = judged_of result in
  Alcotest.(check string) "status" "selected 2/2 [c0,c1]" (describe_status name judged.status)

let test_results_keep_candidate_order_when_the_pieces_finish_the_other_way_round () =
  Eio_main.run @@ fun env ->
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  let first = C.id (List.hd candidates) in
  let second_done, resolve_second_done = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    let ids = List.map fst request.questions in
    match kind_of request with
    | Turn_question -> accepting.turn
    | Time_question -> answer_all standing ids
    | Candidate_question ->
      if ids = [ first ] then Eio.Promise.await second_done
      else Eio.Promise.resolve resolve_second_done ();
      answer_all possibly ids
  in
  let result = within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose ~piece_bytes:small candidates) in
  let judged = judged_of result in
  check_strings "results" [ "c0:possibly_needed"; "c1:possibly_needed" ] (List.map (describe_result name) judged.results);
  check_strings "marks" [ "c0:standing"; "c1:standing" ] (List.map (describe_mark name) judged.marks)

(* The requests of (c) go out at the same time: the 20 seconds of the RFC hold
   one (c) limit, not one limit for each request. *)
let test_the_requests_of_c_go_out_at_the_same_time () =
  Eio_main.run @@ fun env ->
  let candidates = List.init 2 (fun index -> sized index small) in
  let started = ref 0 in
  let all_started, resolve_all_started = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    let ids = ids_of request in
    match kind_of request with
    | Turn_question -> accepting.turn
    | Candidate_question -> answer_all possibly ids
    | Time_question ->
      incr started;
      if !started = 2 then Eio.Promise.resolve resolve_all_started ();
      Eio.Promise.await all_started;
      answer_all standing ids
  in
  let judged =
    judged_of (within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose ~piece_bytes:small candidates))
  in
  Alcotest.(check int) "two marks" 2 (List.length judged.marks)

(* The first request of (c) ends last. *)
let test_marks_keep_candidate_order_when_the_first_request_of_c_ends_last () =
  Eio_main.run @@ fun env ->
  let candidates = List.init 2 (fun index -> sized index small) in
  let name = names candidates in
  let first = C.id (List.hd candidates) in
  let second_done, resolve_second_done = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    let ids = ids_of request in
    match kind_of request with
    | Turn_question -> accepting.turn
    | Candidate_question -> answer_all possibly ids
    | Time_question ->
      if ids = [ first ] then Eio.Promise.await second_done else Eio.Promise.resolve resolve_second_done ();
      answer_all standing ids
  in
  let judged =
    judged_of (within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose ~piece_bytes:small candidates))
  in
  check_strings "marks" [ "c0:standing"; "c1:standing" ] (List.map (describe_mark name) judged.marks)

(* ---- cancellation and exceptions ---- *)

let test_a_cancellation_is_not_turned_into_a_status () =
  Eio_main.run @@ fun _env ->
  let candidates = [ sized 0 small ] in
  let completed = ref false and saw_cancellation = ref false in
  let never, _unused = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    match kind_of request with
    | Candidate_question ->
      (try Eio.Promise.await never with
       | Eio.Cancel.Cancelled _ as exn ->
         saw_cancellation := true;
         raise exn)
    | Turn_question -> accepting.turn
    | Time_question -> answer_all standing (List.map fst request.questions)
  in
  let outcome =
    Eio.Fiber.first
      (fun () ->
        ignore (Flow.run ~evaluate ~purpose candidates);
        completed := true;
        `Finished)
      (fun () ->
        Eio.Fiber.yield ();
        `Cancelled_by_the_test)
  in
  Alcotest.(check bool) "the other side won" true (outcome = `Cancelled_by_the_test);
  Alcotest.(check bool) "the request saw the cancellation" true !saw_cancellation;
  Alcotest.(check bool) "run did not return" false !completed

(* A cancellation the client raises on its own, with no cancelled context
   behind it, is the one case Eio does not raise again at the end of the
   fibers. Only the flow letting it through keeps it from becoming a status. *)
let test_an_exception_from_the_client_comes_out_of_run () =
  List.iter
    (fun raised ->
      Eio_main.run @@ fun _env ->
      (* Only (a) raises, so that one exception comes out of the two fibers. *)
      let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
        match kind_of request with
        | Candidate_question -> raise raised
        | Turn_question -> accepting.turn
        | Time_question -> answer_all standing (List.map fst request.questions)
      in
      Alcotest.check_raises "comes out of run" raised (fun () ->
        ignore (Flow.run ~evaluate ~purpose [ sized 0 small ])))
    [ Failure "client broke"; Eio.Cancel.Cancelled (Failure "stopped") ]

(* [raised] is the exception, or the reason inside nested [Cancelled]. (b) runs
   in a fiber of a switch. When that fiber raises [Cancelled] with no cancelled
   context behind it, the switch fails with it and hands it to the body as the
   reason of a cancellation, so it comes out wrapped once more. *)
let rec comes_from exn ~raised =
  exn = raised
  || (match exn with
      | Eio.Cancel.Cancelled inner -> comes_from inner ~raised
      | _ -> false)

(* The client raises in (b) or in (c) alone. *)
let test_an_exception_from_question_b_or_c_comes_out_of_run () =
  List.iter
    (fun (where, raised) ->
      Eio_main.run @@ fun _env ->
      let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
        match kind_of request, where with
        | Turn_question, `B -> raise raised
        | Time_question, `C -> raise raised
        | Turn_question, `C -> accepting.turn
        | Time_question, `B -> answer_all standing (ids_of request)
        | Candidate_question, (`B | `C) -> answer_all possibly (ids_of request)
      in
      match Flow.run ~evaluate ~purpose [ sized 0 small ] with
      | _ -> Alcotest.fail "run returned"
      | exception exn -> Alcotest.(check bool) "comes out of run" true (comes_from exn ~raised))
    [ `B, Failure "b broke"
    ; `B, Eio.Cancel.Cancelled (Failure "stopped")
    ; `C, Failure "c broke"
    ; `C, Eio.Cancel.Cancelled (Failure "stopped")
    ]

(* The request of (a) for a lone candidate waits for (b). If (b) ends with an
   exception nobody resolves what it waits for, so [run] ends only because the
   exception of (b) cancels the wait. *)
let test_question_b_raises_while_a_lone_candidate_waits_for_it () =
  Eio_main.run @@ fun env ->
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    match kind_of request with
    | Candidate_question -> Error Flow.Capacity_refused
    | Turn_question ->
      Eio.Fiber.yield ();
      raise (Failure "b broke")
    | Time_question -> answer_all standing (ids_of request)
  in
  Alcotest.check_raises "comes out of run" (Failure "b broke") (fun () ->
    ignore (within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose [ sized 0 small ])))

(* The other way round: (b) never answers, and (a) raises. The exception of (a)
   has to cancel (b). *)
let test_a_request_of_a_raises_while_question_b_is_waiting () =
  Eio_main.run @@ fun env ->
  let never, _unused = Eio.Promise.create () in
  let evaluate (request : Codec.request) : (Types.eval_response, Flow.attempt_failure) result =
    match kind_of request with
    | Candidate_question -> raise (Failure "a broke")
    | Turn_question -> Eio.Promise.await never
    | Time_question -> answer_all standing (ids_of request)
  in
  Alcotest.check_raises "comes out of run" (Failure "a broke") (fun () ->
    ignore (within_five_seconds env (fun () -> Flow.run ~evaluate ~purpose [ sized 0 small ])))

let () =
  Alcotest.run "keeper_memory_recall_flow"
    [ ( "flow"
      , [ Alcotest.test_case "sized candidates have the line bytes they are named for" `Quick
            test_sized_candidates_have_the_line_bytes_they_are_named_for
        ; Alcotest.test_case "no candidates send nothing" `Quick test_no_candidates_send_nothing
        ; Alcotest.test_case "everything taken" `Quick test_everything_taken
        ; Alcotest.test_case "the purpose goes to (a) and (b), not to (c)" `Quick
            test_purpose_goes_to_question_a_and_b_and_not_to_c
        ; Alcotest.test_case "nothing carried asks no (c)" `Quick test_nothing_carried_asks_no_time_question
        ; Alcotest.test_case "a carried candidate wins over a no" `Quick test_a_carried_candidate_wins_over_a_no
        ; Alcotest.test_case "a refused piece is cut in two, halves in order" `Quick
            test_a_refused_piece_is_cut_in_two_and_the_halves_go_in_order
        ; Alcotest.test_case "a lone refused candidate is too large when (b) was taken" `Quick
            test_a_lone_candidate_the_server_refuses_is_too_large_when_it_took_the_purpose
        ; Alcotest.test_case "a lone refused candidate is capacity when (b) failed another way" `Quick
            test_a_lone_candidate_is_capacity_when_question_b_failed_another_way
        ; Alcotest.test_case "a response that does not decode still shows the purpose fits" `Quick
            test_a_response_that_does_not_decode_still_shows_the_purpose_fits
        ; Alcotest.test_case "a purpose that is too large stops everything" `Quick
            test_a_purpose_that_is_too_large_stops_everything
        ; Alcotest.test_case "other failures leave their piece undecided, no retry" `Quick
            test_the_other_failures_leave_only_their_piece_undecided_and_are_not_retried
        ; Alcotest.test_case "not recorded replaces the whole judgment" `Quick
            test_not_recorded_replaces_the_whole_judgment
        ; Alcotest.test_case "an answer that does not decode leaves one candidate" `Quick
            test_an_answer_that_does_not_decode_leaves_only_that_candidate
        ; Alcotest.test_case "a failed (c) is unjudged and never cut" `Quick
            test_a_time_question_that_fails_is_unjudged_and_never_cut
        ; Alcotest.test_case "a (c) answer that does not decode is unjudged" `Quick
            test_a_time_answer_that_does_not_decode_is_unjudged
        ; Alcotest.test_case "(c) goes to each answered piece with its carried candidates" `Quick
            test_a_time_question_is_asked_for_each_answered_piece_with_its_carried_candidates
        ; Alcotest.test_case "a duplicate stops before anything is sent" `Quick
            test_a_duplicate_stops_before_anything_is_sent
        ; Alcotest.test_case "requests are bounded when everything is refused alone" `Quick
            test_requests_of_a_piece_that_is_refused_down_to_one_candidate_are_bounded
        ; Alcotest.test_case "eight candidates refused alone take fifteen requests" `Quick
            test_eight_candidates_refused_alone_take_fifteen_requests
        ; Alcotest.test_case "the halves carry the purpose" `Quick test_the_halves_carry_the_purpose
        ; Alcotest.test_case "the cut is at half the line bytes" `Quick
            test_the_cut_is_at_half_the_line_bytes_for_sizes_that_differ
        ; Alcotest.test_case "a piece of several candidates that fails another way leaves all of them" `Quick
            test_a_piece_of_several_candidates_that_fails_another_way_leaves_all_of_them
        ; Alcotest.test_case "a 200 for (b) that does not decode shows the purpose fits" `Quick
            test_a_200_for_question_b_that_does_not_decode_shows_the_purpose_fits
        ; Alcotest.test_case "(b) refused for size is a question without an answer" `Quick
            test_question_b_refused_for_size_is_a_question_without_an_answer
        ; Alcotest.test_case "a half starts after the one before it has ended" `Quick
            test_a_half_starts_after_the_one_before_it_has_ended
        ; Alcotest.test_case "the cut does not wait for (b)" `Quick
            test_the_cut_does_not_wait_for_question_b
        ; Alcotest.test_case "a lone candidate refused before (b) answers waits for it" `Quick
            test_a_lone_candidate_refused_before_question_b_answers_waits_for_it
        ; Alcotest.test_case "the pieces and (b) go out at the same time" `Quick
            test_the_pieces_and_question_b_go_out_at_the_same_time
        ; Alcotest.test_case "results keep candidate order" `Quick
            test_results_keep_candidate_order_when_the_pieces_finish_the_other_way_round
        ; Alcotest.test_case "the requests of (c) go out at the same time" `Quick
            test_the_requests_of_c_go_out_at_the_same_time
        ; Alcotest.test_case "marks keep candidate order when the first (c) ends last" `Quick
            test_marks_keep_candidate_order_when_the_first_request_of_c_ends_last
        ; Alcotest.test_case "a cancellation is not turned into a status" `Quick
            test_a_cancellation_is_not_turned_into_a_status
        ; Alcotest.test_case "an exception or a cancellation from the client comes out of run" `Quick
            test_an_exception_from_the_client_comes_out_of_run
        ; Alcotest.test_case "an exception from (b) or (c) comes out of run" `Quick
            test_an_exception_from_question_b_or_c_comes_out_of_run
        ; Alcotest.test_case "(b) raises while a lone candidate waits for it" `Quick
            test_question_b_raises_while_a_lone_candidate_waits_for_it
        ; Alcotest.test_case "(a) raises while (b) is waiting" `Quick
            test_a_request_of_a_raises_while_question_b_is_waiting
        ] )
    ]
