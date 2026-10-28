(** Pure parts of Keeper memory recall: the closed judgment vocabulary and its
    reduction, the candidate line and the cut into pieces, and the Jev request
    and answer codec. Expected values are written out by hand. *)

open Masc
module J = Keeper_memory_recall_judgment
module C = Keeper_memory_recall_candidates
module Codec = Keeper_memory_recall_jev_codec
module T = Keeper_memory_os_types
module Types = Typesafeai_types

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

(* ---- judgment ---- *)

let carried id = J.Decided { id; decision = J.Possibly_needed }
let left_out id = J.Decided { id; decision = J.Not_needed }
let undecided id reason = J.Undecided { id; reason }

let every_turn =
  [ J.Turn_answered J.Needs_knowledge
  ; J.Turn_answered J.Needs_no_knowledge
  ; J.Turn_answered J.Unsure
  ; J.Turn_question_failed
  ]

let describe (verdict : J.verdict) =
  let coverage = J.status_coverage verdict.status in
  let detail =
    match verdict.status with
    | J.Selected { selection; coverage = _ } ->
      " [" ^ String.concat "," (J.selection_ids selection) ^ "]"
    | J.Unavailable { reason; coverage = _ } -> " " ^ J.unavailable_reason_token reason
    | J.None_found _ | J.None_needed _ -> ""
  in
  Printf.sprintf "%s %d/%d%s%s" (J.status_token verdict.status)
    (J.coverage_judged coverage) (J.coverage_total coverage) detail
    (if verdict.turn_question_contradicted then " contradicted" else "")

let reduced candidates turn =
  Option.map describe (J.reduce ~candidates ~turn)

let check_reduced label expected candidates turn =
  Alcotest.(check (option string)) label (Some expected) (reduced candidates turn)

let test_no_candidates_have_no_verdict () =
  List.iter (fun turn ->
    Alcotest.(check (option string)) "no candidates, no verdict" None (reduced [] turn))
    every_turn

let test_carried_candidate_selects_whatever_the_turn_said () =
  let candidates = [carried "a"; left_out "b"; carried "c"] in
  check_reduced "yes" "selected 3/3 [a,c]" candidates (J.Turn_answered J.Needs_knowledge);
  check_reduced "unsure" "selected 3/3 [a,c]" candidates (J.Turn_answered J.Unsure);
  check_reduced "question failed" "selected 3/3 [a,c]" candidates J.Turn_question_failed;
  check_reduced "no is a contradiction" "selected 3/3 [a,c] contradicted" candidates
    (J.Turn_answered J.Needs_no_knowledge)

let test_selection_keeps_candidate_order_and_counts_undecided () =
  check_reduced "order" "selected 2/3 [z,a]"
    [carried "z"; undecided "m" J.Timeout; carried "a"]
    (J.Turn_answered J.Needs_knowledge)

let test_nothing_carried_follows_the_turn_question () =
  let candidates = [left_out "a"; left_out "b"] in
  check_reduced "yes" "none_found 2/2" candidates (J.Turn_answered J.Needs_knowledge);
  check_reduced "unsure" "none_found 2/2" candidates (J.Turn_answered J.Unsure);
  check_reduced "no" "none_needed 2/2" candidates (J.Turn_answered J.Needs_no_knowledge);
  check_reduced "failed is not unsure" "unavailable 2/2 turn_question" candidates
    J.Turn_question_failed

let test_partial_coverage_is_counted () =
  let candidates = [left_out "a"; undecided "b" J.Timeout; left_out "c"] in
  check_reduced "partial" "none_found 2/3" candidates (J.Turn_answered J.Needs_knowledge);
  match J.reduce ~candidates ~turn:(J.Turn_answered J.Needs_knowledge) with
  | None -> Alcotest.fail "expected a verdict"
  | Some verdict ->
    Alcotest.(check bool) "partial" true (J.is_partial (J.status_coverage verdict.status));
    (match J.reduce ~candidates:[left_out "a"] ~turn:(J.Turn_answered J.Unsure) with
     | None -> Alcotest.fail "expected a verdict"
     | Some full ->
       Alcotest.(check bool) "full" false (J.is_partial (J.status_coverage full.status)))

let test_nothing_decided_reports_the_first_reason_whatever_the_turn_said () =
  List.iter (fun turn ->
    check_reduced "first reason wins" "unavailable 0/2 rate_limited"
      [undecided "a" J.Rate_limited; undecided "b" J.Timeout] turn;
    check_reduced "order matters" "unavailable 0/2 timeout"
      [undecided "a" J.Timeout; undecided "b" J.Rate_limited] turn)
    every_turn

let test_too_large_shows_as_capacity () =
  check_reduced "status line token" "unavailable 0/1 capacity"
    [undecided "a" J.Too_large] J.Turn_question_failed;
  Alcotest.(check string) "its own token" "too_large" (J.unjudged_reason_token J.Too_large)

let test_contradiction_needs_a_carried_candidate () =
  match J.reduce ~candidates:[left_out "a"] ~turn:(J.Turn_answered J.Needs_no_knowledge) with
  | None -> Alcotest.fail "expected a verdict"
  | Some verdict ->
    Alcotest.(check bool) "nothing carried" false verdict.turn_question_contradicted

let test_a_hundred_thousand_candidates_keep_order () =
  let ids = List.init 100_000 string_of_int in
  match J.reduce ~candidates:(List.map carried ids)
          ~turn:(J.Turn_answered J.Needs_knowledge) with
  | None -> Alcotest.fail "expected a verdict"
  | Some { status = J.Selected { selection; coverage = _ }; turn_question_contradicted = _ } ->
    Alcotest.(check (list string)) "ids" ids (J.selection_ids selection)
  | Some { status = J.None_found _ | J.None_needed _ | J.Unavailable _
         ; turn_question_contradicted = _ } -> Alcotest.fail "expected a selection"

let test_tokens () =
  Alcotest.(check (list string)) "question (a) labels"
    ["possibly_needed"; "not_needed"]
    (List.map J.candidate_decision_label J.all_candidate_decisions);
  Alcotest.(check (list string)) "question (b) labels" ["yes"; "no"; "unsure"]
    (List.map J.turn_need_label J.all_turn_needs);
  Alcotest.(check (list string)) "question (c) labels" ["standing"; "time_bound"]
    (List.map J.time_nature_label J.all_time_natures);
  Alcotest.(check (list string)) "unjudged reasons"
    ["capacity"; "too_large"; "rate_limited"; "timeout"; "provider_failed"; "cancelled";
     "invalid_answer"]
    (List.map J.unjudged_reason_token
       [J.Capacity; J.Too_large; J.Rate_limited; J.Timeout; J.Provider_failed; J.Cancelled;
        J.Invalid_answer]);
  Alcotest.(check string) "turn question" "turn_question"
    (J.unavailable_reason_token J.Turn_question)

(* ---- candidates ---- *)

let now = 1_700_000_000.0 (* 2023-11-14T22:13:20Z *)
let next_utc_midnight = 1_700_006_400.0 (* 2023-11-15T00:00:00Z *)

let fact ?(kind = T.Authored) ?(first_seen = now) ?(last_seen = now) claim =
  let base =
    T.observed ~claim ~category:T.Lesson ~now ~origin:{ T.kind; trace_id = "trace-secret" } in
  { base with T.first_seen; last_seen }

let contains text part =
  let text_length = String.length text and part_length = String.length part in
  let rec from index =
    index + part_length <= text_length
    && (String.equal (String.sub text index part_length) part || from (index + 1)) in
  from 0

let line_field candidate name =
  match C.line candidate with
  | `Assoc fields -> List.assoc name fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "candidate line is not an object"

let test_line_carries_the_six_fields_in_order () =
  let source = fact "keep the head pinned" in
  let candidate = C.of_fact source in
  Alcotest.(check json) "line"
    (`Assoc
       [ "question_id", `String (T.memory_id source)
       ; "category", `String "lesson"
       ; "claim", `String "keep the head pinned"
       ; "first_seen", `String "2023-11-14"
       ; "last_seen", `String "2023-11-14"
       ; "origin", `String "authored"
       ])
    (C.line candidate);
  Alcotest.(check string) "id" (T.memory_id source) (C.id candidate);
  Alcotest.(check bool) "no trace id" false
    (contains (Yojson.Safe.to_string (C.line candidate)) "trace-secret")

let test_origin_is_the_kind () =
  Alcotest.(check json) "injected" (`String "injected")
    (line_field (C.of_fact (fact ~kind:T.Injected "x")) "origin")

let test_dates_are_utc_days () =
  let day candidate name = line_field candidate name in
  let before = C.of_fact (fact ~first_seen:(next_utc_midnight -. 1.0) ~last_seen:next_utc_midnight "x") in
  Alcotest.(check json) "last second of the day" (`String "2023-11-14") (day before "first_seen");
  Alcotest.(check json) "first second of the next day" (`String "2023-11-15") (day before "last_seen");
  Alcotest.(check json) "before 1970" (`String "1969-12-31")
    (day (C.of_fact (fact ~first_seen:(-86_400.0) "x")) "first_seen")

let test_unrepresentable_timestamps_are_null_and_stay_in () =
  List.iter (fun bad ->
    let candidate = C.of_fact (fact ~first_seen:bad ~last_seen:bad "x") in
    Alcotest.(check json) "first_seen" `Null (line_field candidate "first_seen");
    Alcotest.(check json) "last_seen" `Null (line_field candidate "last_seen");
    Alcotest.(check json) "claim kept" (`String "x") (line_field candidate "claim"))
    [Float.nan; Float.infinity; Float.neg_infinity; 1e18]

let test_line_bytes_counts_utf8_bytes () =
  (* {"question_id":"sha256:<64 hex>","category":"lesson","claim":"a",
     "first_seen":"2023-11-14","last_seen":"2023-11-14","origin":"authored"} *)
  Alcotest.(check int) "ascii claim" 192 (C.line_bytes (C.of_fact (fact "a")));
  Alcotest.(check int) "three-byte character" 194 (C.line_bytes (C.of_fact (fact "\xea\xb0\x80")))

(* A candidate whose line is exactly [size] bytes: the line is 191 bytes plus the claim. *)
let line_overhead = 191

let sized index size =
  let tag = string_of_int index in
  C.of_fact (fact (String.make (size - line_overhead - String.length tag) 'x' ^ tag))

let cut ~budget sizes =
  List.map (fun piece -> List.map C.line_bytes (C.piece_candidates piece))
    (C.split ~piece_bytes:budget (List.mapi sized sizes))

let check_cut label expected ~budget sizes =
  Alcotest.(check (list (list int))) label expected (cut ~budget sizes)

let test_split_boundary_is_inclusive () =
  check_cut "fits exactly" [[500; 500]; [300]] ~budget:1000 [500; 500; 300];
  check_cut "one byte over" [[500]; [501]] ~budget:1000 [500; 501];
  check_cut "greedy in order" [[300; 300; 300]; [300]] ~budget:1000 [300; 300; 300; 300]

let test_split_gives_an_oversize_candidate_its_own_piece () =
  check_cut "middle" [[300]; [5000]; [300]] ~budget:1000 [300; 5000; 300];
  check_cut "first" [[5000]; [300]] ~budget:1000 [5000; 300];
  check_cut "only" [[5000]] ~budget:1000 [5000]

let test_split_with_no_budget_separates_every_candidate () =
  check_cut "zero" [[300]; [300]; [300]] ~budget:0 [300; 300; 300];
  check_cut "negative" [[300]; [300]] ~budget:(-5) [300; 300]

let test_split_of_nothing_is_nothing () = check_cut "empty" [] ~budget:1000 []

let test_split_keeps_every_candidate_once_in_order () =
  let candidates = List.mapi sized [400; 250; 900; 250; 5000; 200; 200; 200] in
  let pieces = C.split ~piece_bytes:1000 candidates in
  Alcotest.(check (list string)) "ids" (List.map C.id candidates)
    (List.concat_map (fun piece -> List.map C.id (C.piece_candidates piece)) pieces);
  List.iter (fun piece ->
    Alcotest.(check int) "piece bytes"
      (List.fold_left (fun sum candidate -> sum + C.line_bytes candidate) 0
         (C.piece_candidates piece))
      (C.piece_line_bytes piece))
    pieces

let test_split_cuts_five_thousand_candidates_at_the_default_budget () =
  Alcotest.(check int) "default budget" 80_000 C.state_bytes_per_piece;
  let pieces = C.split ~piece_bytes:C.state_bytes_per_piece
      (List.init 5_000 (fun index -> sized index 400)) in
  Alcotest.(check int) "pieces" 25 (List.length pieces);
  Alcotest.(check (list int)) "candidates per piece" (List.init 25 (fun _ -> 200))
    (List.map (fun piece -> List.length (C.piece_candidates piece)) pieces)

(* ---- codec ---- *)

let purpose = `Assoc ["turn_input", `String "review the open pull request"]

let piece_of facts =
  match C.split ~piece_bytes:max_int (List.map C.of_fact facts) with
  | [piece] -> piece
  | [] | _ :: _ :: _ -> Alcotest.fail "expected one piece"

let two_facts = [fact "first claim"; fact "second claim"]
let two_ids = List.map T.memory_id two_facts

let first_id, second_id =
  match two_ids with
  | [first; second] -> first, second
  | [] | [_] | _ :: _ :: _ :: _ -> failwith "two facts have two ids"

let ok_request label = function
  | Ok request -> request
  | Error (Codec.Duplicate_candidate_id id) -> Alcotest.failf "%s: duplicate id %s" label id
  | Error (Codec.Choice_set_invalid detail) -> Alcotest.failf "%s: %s" label detail

let choice_parts label = function
  | Types.Choice { instructions; criteria } -> instructions, criteria
  | Types.Score _ | Types.Noul _ -> Alcotest.failf "%s: expected a choice question" label

let test_candidate_request_shape () =
  let request = ok_request "request" (Codec.candidate_request ~purpose (piece_of two_facts)) in
  Alcotest.(check json) "state"
    (`Assoc
       [ "purpose", purpose
       ; "candidates", `List (List.map (fun source -> C.line (C.of_fact source)) two_facts)
       ])
    request.state;
  Alcotest.(check (list string)) "one question per candidate, in order" two_ids
    (List.map fst request.questions);
  List.iter (fun (id, question) ->
    let instructions, criteria = choice_parts "question" question in
    Alcotest.(check bool) "names its entry" true
      (contains instructions ("whose question_id is " ^ id ^ "."));
    Alcotest.(check bool) "rule in the instructions" true
      (contains instructions "Choose not_needed only when it is clearly unrelated.");
    Alcotest.(check (list string)) "labels" ["possibly_needed"; "not_needed"]
      (List.map fst criteria);
    List.iter (fun (_, meaning) ->
      Alcotest.(check bool) "meaning given" true (Option.is_some meaning)) criteria)
    request.questions;
  Alcotest.(check bool) "rules stay out of state" false
    (contains (Yojson.Safe.to_string request.state) "Choose not_needed")

let test_candidate_request_is_a_valid_wire_body () =
  let request = ok_request "request" (Codec.candidate_request ~purpose (piece_of two_facts)) in
  let body = Types.request_to_yojson ~model:"jev-test" ~state:request.state
      ~questions:request.questions in
  match Yojson.Safe.Util.member "questions" body with
  | `Assoc keys -> Alcotest.(check (list string)) "question keys" two_ids (List.map fst keys)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "questions is not an object"

let test_a_duplicate_candidate_is_refused_before_dispatch () =
  let same = fact "same claim" in
  match Codec.candidate_request ~purpose (piece_of [same; same]) with
  | Error (Codec.Duplicate_candidate_id id) ->
    Alcotest.(check string) "id" (T.memory_id same) id
  | Error (Codec.Choice_set_invalid detail) -> Alcotest.fail detail
  | Ok _ -> Alcotest.fail "a request with one key twice was built"

let choice label probabilities confidence =
  Types.Choice_answer { choice = label; probabilities; confidence }

let possibly confidence = choice "possibly_needed" ["possibly_needed", 0.8; "not_needed", 0.2] confidence
let unrelated confidence = choice "not_needed" ["possibly_needed", 0.3; "not_needed", 0.7] confidence

let response answers = { Types.model = "jev-test"; answers; usage = None }

let decisions_of piece answers =
  List.map (fun (_, answer) ->
    match answer with
    | Codec.Answered decoded -> J.candidate_decision_label decoded.Types.choice
    | Codec.Not_decoded _ -> "not decoded")
    (Codec.decode_candidates piece (response answers))

let test_candidate_answers_are_read_in_piece_order () =
  let piece = piece_of two_facts in
  let first, second = first_id, second_id in
  Alcotest.(check (list string)) "decisions" ["possibly_needed"; "not_needed"]
    (decisions_of piece [second, unrelated 0.9; first, possibly 0.9]);
  Alcotest.(check (list string)) "ids"
    two_ids (List.map fst (Codec.decode_candidates piece (response [first, possibly 0.9])))

let test_confidence_does_not_change_the_decision () =
  let piece = piece_of [fact "only claim"] in
  let id = T.memory_id (fact "only claim") in
  List.iter (fun confidence ->
    Alcotest.(check (list string)) "decision" ["possibly_needed"]
      (decisions_of piece [id, possibly confidence]))
    [0.0; 0.5; 1.0]

let test_an_answer_that_does_not_decode_leaves_only_that_candidate () =
  let piece = piece_of two_facts in
  let first, second = first_id, second_id in
  Alcotest.(check (list string)) "label is not the most probable option"
    ["not decoded"; "not_needed"]
    (decisions_of piece
       [first, choice "possibly_needed" ["possibly_needed", 0.4; "not_needed", 0.6] 0.5;
        second, unrelated 0.9]);
  Alcotest.(check (list string)) "unknown label" ["not decoded"; "not_needed"]
    (decisions_of piece
       [first, choice "maybe" ["possibly_needed", 0.4; "not_needed", 0.6] 0.5;
        second, unrelated 0.9]);
  Alcotest.(check (list string)) "not a choice answer" ["not decoded"; "not_needed"]
    (decisions_of piece [first, Types.Score_answer { score = 1.0; probabilities = []; confidence = 0.5 };
                         second, unrelated 0.9]);
  Alcotest.(check (list string)) "missing answer" ["possibly_needed"; "not decoded"]
    (decisions_of piece [first, possibly 0.9]);
  Alcotest.(check (list string)) "no answers" ["not decoded"; "not decoded"]
    (decisions_of piece [])

let test_a_response_with_a_duplicate_or_unknown_id_leaves_the_whole_piece () =
  let piece = piece_of two_facts in
  let first, second = first_id, second_id in
  Alcotest.(check (list string)) "duplicate" ["not decoded"; "not decoded"]
    (decisions_of piece [first, possibly 0.9; first, possibly 0.9; second, unrelated 0.9]);
  Alcotest.(check (list string)) "unknown" ["not decoded"; "not decoded"]
    (decisions_of piece [first, possibly 0.9; second, unrelated 0.9; "sha256:other", possibly 0.9])

let test_candidate_result () =
  Alcotest.(check (list string)) "decided and undecided" ["decided possibly_needed"; "undecided invalid_answer"]
    (List.map (fun (id, answer) ->
       match Codec.candidate_result ~id answer with
       | J.Decided { id = _; decision } -> "decided " ^ J.candidate_decision_label decision
       | J.Undecided { id = _; reason } -> "undecided " ^ J.unjudged_reason_token reason)
       (Codec.decode_candidates (piece_of two_facts)
          (response [first_id, possibly 0.9])))

let test_turn_request_has_no_candidates () =
  let request = ok_request "turn" (Codec.turn_request ~purpose) in
  Alcotest.(check json) "state" (`Assoc ["purpose", purpose]) request.state;
  match request.questions with
  | [id, question] ->
    Alcotest.(check string) "id" "turn" id;
    let _, criteria = choice_parts "turn" question in
    Alcotest.(check (list string)) "labels" ["yes"; "no"; "unsure"] (List.map fst criteria)
  | [] | _ :: _ :: _ -> Alcotest.fail "expected exactly one question"

let turn_outcome answers =
  match Codec.turn_answer (Codec.decode_turn (response answers)) with
  | J.Turn_answered need -> J.turn_need_label need
  | J.Turn_question_failed -> "failed"

let test_turn_answers () =
  let answer label probabilities = choice label probabilities 0.5 in
  Alcotest.(check string) "yes" "yes"
    (turn_outcome ["turn", answer "yes" ["yes", 0.7; "no", 0.2; "unsure", 0.1]]);
  Alcotest.(check string) "unsure is an answer, not a failure" "unsure"
    (turn_outcome ["turn", answer "unsure" ["yes", 0.2; "no", 0.2; "unsure", 0.6]]);
  Alcotest.(check string) "no" "no"
    (turn_outcome ["turn", answer "no" ["yes", 0.1; "no", 0.8; "unsure", 0.1]]);
  Alcotest.(check string) "no answer" "failed" (turn_outcome []);
  Alcotest.(check string) "wrong key" "failed"
    (turn_outcome ["other", answer "yes" ["yes", 0.7; "no", 0.2; "unsure", 0.1]]);
  Alcotest.(check string) "two answers" "failed"
    (turn_outcome ["turn", answer "yes" ["yes", 0.7; "no", 0.2; "unsure", 0.1];
                   "extra", answer "yes" ["yes", 0.7; "no", 0.2; "unsure", 0.1]]);
  Alcotest.(check string) "label is not the most probable option" "failed"
    (turn_outcome ["turn", answer "yes" ["yes", 0.2; "no", 0.5; "unsure", 0.3]]);
  Alcotest.(check string) "a three-way tie is an answer" "yes"
    (turn_outcome ["turn", answer "yes" ["yes", 0.2; "no", 0.2; "unsure", 0.2]])

let test_time_marks () =
  let piece = piece_of two_facts in
  let first = first_id in
  let request = ok_request "time" (Codec.time_request ~purpose piece) in
  Alcotest.(check (list string)) "keys" two_ids (List.map fst request.questions);
  List.iter (fun (_, question) ->
    let _, criteria = choice_parts "time" question in
    Alcotest.(check (list string)) "labels" ["standing"; "time_bound"] (List.map fst criteria))
    request.questions;
  let mark answer =
    match Codec.time_mark answer with
    | J.Marked J.Standing -> "standing"
    | J.Marked J.Time_bound -> "time_bound"
    | J.Time_unjudged -> "unjudged" in
  Alcotest.(check (list string)) "marks" ["time_bound"; "unjudged"]
    (List.map (fun (_, answer) -> mark answer)
       (Codec.decode_time piece
          (response [first, choice "time_bound" ["standing", 0.1; "time_bound", 0.9] 0.9])));
  Alcotest.(check string) "a failed answer is never standing" "unjudged"
    (mark (Codec.Not_decoded "x"))

let () =
  Alcotest.run "keeper_memory_recall_parts"
    [ ( "judgment"
      , [ Alcotest.test_case "no candidates have no verdict" `Quick
            test_no_candidates_have_no_verdict
        ; Alcotest.test_case "a carried candidate selects whatever the turn said" `Quick
            test_carried_candidate_selects_whatever_the_turn_said
        ; Alcotest.test_case "selection keeps candidate order" `Quick
            test_selection_keeps_candidate_order_and_counts_undecided
        ; Alcotest.test_case "nothing carried follows the turn question" `Quick
            test_nothing_carried_follows_the_turn_question
        ; Alcotest.test_case "partial coverage is counted" `Quick
            test_partial_coverage_is_counted
        ; Alcotest.test_case "nothing decided reports the first reason" `Quick
            test_nothing_decided_reports_the_first_reason_whatever_the_turn_said
        ; Alcotest.test_case "too large shows as capacity" `Quick
            test_too_large_shows_as_capacity
        ; Alcotest.test_case "a contradiction needs a carried candidate" `Quick
            test_contradiction_needs_a_carried_candidate
        ; Alcotest.test_case "a hundred thousand candidates keep order" `Quick
            test_a_hundred_thousand_candidates_keep_order
        ; Alcotest.test_case "tokens" `Quick test_tokens
        ] )
    ; ( "candidates"
      , [ Alcotest.test_case "line carries the six fields in order" `Quick
            test_line_carries_the_six_fields_in_order
        ; Alcotest.test_case "origin is the kind" `Quick test_origin_is_the_kind
        ; Alcotest.test_case "dates are UTC days" `Quick test_dates_are_utc_days
        ; Alcotest.test_case "unrepresentable timestamps are null and stay in" `Quick
            test_unrepresentable_timestamps_are_null_and_stay_in
        ; Alcotest.test_case "line bytes count UTF-8 bytes" `Quick
            test_line_bytes_counts_utf8_bytes
        ; Alcotest.test_case "split boundary is inclusive" `Quick
            test_split_boundary_is_inclusive
        ; Alcotest.test_case "oversize candidate gets its own piece" `Quick
            test_split_gives_an_oversize_candidate_its_own_piece
        ; Alcotest.test_case "no budget separates every candidate" `Quick
            test_split_with_no_budget_separates_every_candidate
        ; Alcotest.test_case "split of nothing is nothing" `Quick
            test_split_of_nothing_is_nothing
        ; Alcotest.test_case "split keeps every candidate once in order" `Quick
            test_split_keeps_every_candidate_once_in_order
        ; Alcotest.test_case "five thousand candidates at the default budget" `Quick
            test_split_cuts_five_thousand_candidates_at_the_default_budget
        ] )
    ; ( "codec"
      , [ Alcotest.test_case "candidate request shape" `Quick test_candidate_request_shape
        ; Alcotest.test_case "candidate request is a valid wire body" `Quick
            test_candidate_request_is_a_valid_wire_body
        ; Alcotest.test_case "a duplicate candidate is refused before dispatch" `Quick
            test_a_duplicate_candidate_is_refused_before_dispatch
        ; Alcotest.test_case "candidate answers are read in piece order" `Quick
            test_candidate_answers_are_read_in_piece_order
        ; Alcotest.test_case "confidence does not change the decision" `Quick
            test_confidence_does_not_change_the_decision
        ; Alcotest.test_case "an answer that does not decode leaves only that candidate" `Quick
            test_an_answer_that_does_not_decode_leaves_only_that_candidate
        ; Alcotest.test_case "a duplicate or unknown id leaves the whole piece" `Quick
            test_a_response_with_a_duplicate_or_unknown_id_leaves_the_whole_piece
        ; Alcotest.test_case "candidate result" `Quick test_candidate_result
        ; Alcotest.test_case "turn request has no candidates" `Quick
            test_turn_request_has_no_candidates
        ; Alcotest.test_case "turn answers" `Quick test_turn_answers
        ; Alcotest.test_case "time marks" `Quick test_time_marks
        ] )
    ]
