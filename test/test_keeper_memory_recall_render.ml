(** The text of the recall judgment's two blocks: which sentences a status
    carries, what the body holds and in which order, and what is never worded
    as standing. A test finds a sentence by rendering its own fragment, so it
    pins which sentences appear and not how they are put. *)

open Masc
module Render = Keeper_memory_recall_render
module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment
module F = Keeper_memory_os_types
module Candidates = Keeper_memory_recall_candidates

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-render" ~absolute_turn:11
let turn_ref_text = Ids.Turn_ref.to_string turn_ref
let now = 1_700_000_000.0
let three_days = 3. *. 86_400.
let origin = { F.kind = F.Authored; trace_id = "trace" }

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

let index_of haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i =
    if i + n > h then Alcotest.failf "%S not found" needle
    else if String.sub haystack i n = needle then i
    else go (i + 1)
  in
  go 0

let occurrences haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i found =
    if i + n > h then found
    else if String.sub haystack i n = needle then go (i + n) (found + 1)
    else go (i + 1) found
  in
  if n = 0 then 0 else go 0 0

(* A sentence is found by rendering its fragment, never by copying its words. *)
let fragment key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> text
  | Error detail -> Alcotest.fail detail

(* ---- facts and judgments ---- *)

let fact claim = F.observed ~claim ~category:F.Lesson ~now ~origin
let board_post_id = "p-0123456789abcdef0123456789abcdef"

let board_fact claim =
  match F.board_ref_of_ids ~post_id:board_post_id ~comment_id:None with
  | Ok board -> { (fact claim) with F.basis = F.Observed (F.Board board) }
  | Error _ -> Alcotest.fail "the board reference does not satisfy the grammar"

let first = fact "the staging deploy needs a manual approval"
let second = board_fact "merge only squash"
let third = fact "the release branch is frozen on Fridays"
let facts = [ first; second; third ]
let id = F.memory_id

let decided fact decision = J.Decided { id = id fact; decision }
let undecided fact reason = J.Undecided { id = id fact; reason }

let judged ?(marks = []) ~results ~turn () =
  match J.reduce ~candidates:results ~turn with
  | Some status -> { Flow.status; results; turn; marks }
  | None -> Alcotest.fail "no candidates"

(* The first and the second are carried; the third is not. *)
let carrying_two ?(marks = []) () =
  judged ~marks
    ~results:
      [ decided first J.Possibly_needed
      ; decided second J.Possibly_needed
      ; decided third J.Not_needed
      ]
    ~turn:(J.Turn_answered J.Needs_knowledge)
    ()

let carrying_none ~turn =
  judged ~results:(List.map (fun fact -> decided fact J.Not_needed) facts) ~turn ()

(* Only the first of the three was judged. *)
let partly_judged ~decision ~turn =
  judged
    ~results:[ decided first decision; undecided second J.Rate_limited; undecided third J.Rate_limited ]
    ~turn ()

let nothing_decided =
  judged
    ~results:(List.map (fun fact -> undecided fact J.Provider_failed) facts)
    ~turn:J.Turn_question_failed ()

(* Every candidate was judged and none is needed, but the turn question failed. *)
let turn_unanswered = carrying_none ~turn:J.Turn_question_failed

let partly_judged_and_turn_unanswered =
  judged
    ~results:[ decided first J.Not_needed; decided second J.Not_needed; undecided third J.Rate_limited ]
    ~turn:J.Turn_question_failed ()

let reason_token (judgment : Flow.judged) =
  match judgment.status with
  | J.Unavailable unavailable -> J.unavailable_reason_token unavailable
  | J.Selected _ | J.None_found _ | J.None_needed _ -> Alcotest.fail "expected an unavailable status"

let status ?(memory_search_available = true) judged =
  Render.status ~memory_search_available ~turn_ref judged

let search_hint = fragment Prompt_names.keeper_recall_status_search_hint []
let search_hint_unavailable = fragment Prompt_names.keeper_recall_status_search_hint_unavailable []

let partial_note ~judged ~candidates =
  fragment Prompt_names.keeper_recall_status_partial
    [ "judged", string_of_int judged; "candidates", string_of_int candidates ]

(* ---- the status line ---- *)

let test_a_selected_status_names_the_turn_the_counts_and_the_ids () =
  let text = status (carrying_two ()) in
  Alcotest.(check bool) "the turn" true (contains text turn_ref_text);
  Alcotest.(check bool) "the carried ids" true (contains text (id first) && contains text (id second));
  Alcotest.(check bool) "not the id left out" false (contains text (id third));
  Alcotest.(check string) "its sentence, then the ids on a line of their own; nothing partial, no search hint"
    (fragment Prompt_names.keeper_recall_status_selected
       [ "turn_ref", turn_ref_text; "candidates", "3"; "selected", "2" ]
     ^ "\n"
     ^ fragment Prompt_names.keeper_recall_status_selected_ids [ "ids", id first ^ ", " ^ id second ])
    text

let test_the_five_kinds_of_status_are_five_different_lines () =
  let lines =
    [ status (carrying_two ())
    ; status (carrying_none ~turn:(J.Turn_answered J.Needs_knowledge))
    ; status (carrying_none ~turn:(J.Turn_answered J.Needs_no_knowledge))
    ; status nothing_decided
    ; status turn_unanswered
    ]
  in
  Alcotest.(check int) "all different" 5 (List.length (List.sort_uniq String.compare lines))

let test_the_answer_of_the_turn_question_tells_none_found_apart () =
  let needs = status (carrying_none ~turn:(J.Turn_answered J.Needs_knowledge)) in
  let unsure = status (carrying_none ~turn:(J.Turn_answered J.Unsure)) in
  Alcotest.(check bool) "yes and unsure are worded apart" false (String.equal needs unsure);
  Alcotest.(check bool) "yes has its sentence" true
    (contains needs
       (fragment Prompt_names.keeper_recall_status_none_found_needed
          [ "turn_ref", turn_ref_text; "judged", "3" ]));
  Alcotest.(check bool) "unsure has its own" true
    (contains unsure
       (fragment Prompt_names.keeper_recall_status_none_found_unsure
          [ "turn_ref", turn_ref_text; "judged", "3" ]))

let test_a_none_needed_status_names_the_turn_and_the_candidates () =
  Alcotest.(check bool) "its own sentence" true
    (contains
       (status (carrying_none ~turn:(J.Turn_answered J.Needs_no_knowledge)))
       (fragment Prompt_names.keeper_recall_status_none_needed
          [ "turn_ref", turn_ref_text; "judged", "3" ]))

let test_an_unavailable_status_carries_its_reason () =
  let text = status nothing_decided in
  Alcotest.(check bool) "its own sentence, with the reason" true
    (contains text
       (fragment Prompt_names.keeper_recall_status_unavailable
          [ "turn_ref", turn_ref_text; "reason", reason_token nothing_decided ]));
  Alcotest.(check bool) "the reason is a token of the flow" true (contains text "provider_failed")

let test_a_failed_turn_question_after_judging_says_how_many_were_looked_at () =
  let text = status partly_judged_and_turn_unanswered in
  Alcotest.(check bool) "its own sentence, with the count it judged and the reason" true
    (contains text
       (fragment Prompt_names.keeper_recall_status_unavailable_turn_question
          [ "turn_ref", turn_ref_text
          ; "judged", "2"
          ; "reason", reason_token partly_judged_and_turn_unanswered
          ]));
  Alcotest.(check bool) "and says it judged only some" true
    (contains text (partial_note ~judged:2 ~candidates:3));
  Alcotest.(check bool) "not the sentence of a status that judged nothing" false
    (contains text
       (fragment Prompt_names.keeper_recall_status_unavailable
          [ "turn_ref", turn_ref_text; "reason", reason_token partly_judged_and_turn_unanswered ]))

let test_a_judgment_of_some_candidates_says_how_many () =
  let partial = partly_judged ~decision:J.Possibly_needed ~turn:(J.Turn_answered J.Needs_knowledge) in
  let note = partial_note ~judged:1 ~candidates:3 in
  (match String.split_on_char '\n' (status partial) with
   | [ sentences; ids ] ->
     Alcotest.(check bool) "a selected judgment of one candidate in three says so" true
       (contains sentences note);
     Alcotest.(check bool) "and still counts every candidate it was given" true
       (String.starts_with
          ~prefix:
            (fragment Prompt_names.keeper_recall_status_selected
               [ "turn_ref", turn_ref_text; "candidates", "3"; "selected", "1" ])
          sentences);
     Alcotest.(check string) "and the ids stay alone on their own line"
       (fragment Prompt_names.keeper_recall_status_selected_ids [ "ids", id first ])
       ids
   | lines -> Alcotest.failf "expected a sentence line and an ids line, got %d lines" (List.length lines));
  Alcotest.(check bool) "a complete one does not" false (contains (status (carrying_two ())) note)

let test_a_status_without_a_selection_counts_the_candidates_it_judged () =
  List.iter
    (fun (label, key, turn) ->
      let text = status (partly_judged ~decision:J.Not_needed ~turn) in
      Alcotest.(check bool) (label ^ ": the one it judged, not the three it was given") true
        (contains text (fragment key [ "turn_ref", turn_ref_text; "judged", "1" ]));
      Alcotest.(check bool) (label ^ ": says it judged only some") true
        (contains text (partial_note ~judged:1 ~candidates:3));
      Alcotest.(check bool) (label ^ ": the pointer to the search still ends it") true
        (String.ends_with ~suffix:search_hint text))
    [ "none found", Prompt_names.keeper_recall_status_none_found_needed, J.Turn_answered J.Needs_knowledge
    ; "none needed", Prompt_names.keeper_recall_status_none_needed, J.Turn_answered J.Needs_no_knowledge
    ]

let test_the_search_pointer_ends_every_state_but_selected_when_the_tool_exists () =
  let cases =
    [ "none_found", carrying_none ~turn:(J.Turn_answered J.Needs_knowledge), search_hint
    ; "none_needed", carrying_none ~turn:(J.Turn_answered J.Needs_no_knowledge), search_hint
    ; "unavailable", nothing_decided, search_hint_unavailable
    ; "turn question failed", turn_unanswered, search_hint_unavailable
    ]
  in
  List.iter
    (fun (label, judgment, hint) ->
      Alcotest.(check bool) (label ^ " points to the search") true
        (String.ends_with ~suffix:hint (status judgment));
      (* The short pointer is the last sentence of the long one, so what ends
         the text does not tell them apart. *)
      Alcotest.(check bool) (label ^ " has the long pointer only where it should") (String.equal hint search_hint)
        (contains (status judgment) search_hint);
      Alcotest.(check bool) (label ^ " names no tool when there is none") false
        (contains (status ~memory_search_available:false judgment) "keeper_memory_search"))
    cases;
  Alcotest.(check bool) "selected has no pointer" false
    (contains (status (carrying_two ())) "keeper_memory_search")

let test_a_status_the_flow_cannot_build_is_refused () =
  let impossible =
    { (carrying_none ~turn:(J.Turn_answered J.Needs_knowledge)) with Flow.turn = J.Turn_question_failed }
  in
  match status impossible with
  | exception Invalid_argument _ -> ()
  | text -> Alcotest.failf "worded an impossible status: %s" text

(* ---- the body ---- *)

let body judgment =
  match Render.body facts judgment with
  | Some text -> text
  | None -> Alcotest.fail "expected a body"

let test_only_a_selected_judgment_has_a_body () =
  List.iter
    (fun (label, judgment) ->
      Alcotest.(check bool) label true (Option.is_none (Render.body facts judgment)))
    [ "none found", carrying_none ~turn:(J.Turn_answered J.Needs_knowledge)
    ; "none needed", carrying_none ~turn:(J.Turn_answered J.Needs_no_knowledge)
    ; "unavailable", nothing_decided
    ; "turn question failed", turn_unanswered
    ]

let test_the_body_holds_the_carried_memories_in_candidate_order_and_no_other () =
  let text = body (carrying_two ()) in
  Alcotest.(check bool) "starts with its heading" true
    (String.starts_with ~prefix:(fragment Prompt_names.keeper_recall_body_heading [ "count", "2" ]) text);
  Alcotest.(check bool) "the first claim, in full" true (contains text first.claim);
  Alcotest.(check bool) "the second claim, in full" true (contains text second.claim);
  Alcotest.(check bool) "not the claim that was left out" false (contains text third.claim);
  Alcotest.(check bool) "candidate order" true (index_of text first.claim < index_of text second.claim);
  Alcotest.(check bool) "each by its id" true (contains text (id first) && contains text (id second))

let day seconds = Option.value (Candidates.utc_day seconds) ~default:Render.unknown_day

let item_head ?(first_seen = fun (fact : F.fact) -> day fact.first_seen) (fact : F.fact) =
  fragment Prompt_names.keeper_recall_body_item
    [ "id", id fact
    ; "category", F.category_to_string fact.category
    ; "first_seen", first_seen fact
    ; "last_seen", day fact.last_seen
    ; "origin", F.origin_kind_to_string fact.origin.kind
    ; "claim", fact.claim
    ]

let board_coordinate = fragment Prompt_names.keeper_recall_body_source_board [ "post_id", board_post_id ]
let time_bound = fragment Prompt_names.keeper_recall_body_time_bound []
let time_unjudged = fragment Prompt_names.keeper_recall_body_time_unjudged []

(* The whole body of one memory, built from the same fragments: this pins
   which value is in which slot, which note comes first and how deep a note
   stands under its item, and not how any of them are worded. The memory was
   last seen three days after it was first seen so the two days differ. *)
let test_a_body_is_its_heading_then_each_item_with_its_notes_two_spaces_in () =
  let seen_again = { second with F.last_seen = second.F.last_seen +. three_days } in
  Alcotest.(check bool) "the two days differ, or the slots could not be told apart" false
    (String.equal (day seen_again.first_seen) (day seen_again.last_seen));
  let judgment =
    judged
      ~marks:[ id seen_again, J.Marked J.Time_bound ]
      ~results:[ decided seen_again J.Possibly_needed ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  match Render.body [ seen_again ] judgment with
  | None -> Alcotest.fail "expected a body"
  | Some text ->
    Alcotest.(check string) "heading, item, coordinate, time note"
      (String.concat "\n"
         [ fragment Prompt_names.keeper_recall_body_heading [ "count", "1" ]
         ; item_head seen_again
         ; "  " ^ board_coordinate
         ; "  " ^ time_bound
         ])
      text

let test_a_board_memory_adds_the_coordinate_a_completion_can_cite () =
  let text = body (carrying_two ()) in
  Alcotest.(check int) "once: only the board memory has one" 1 (occurrences text board_coordinate);
  Alcotest.(check bool) "under the board memory" true
    (index_of text board_coordinate > index_of text second.claim);
  let transcript_only =
    judged
      ~results:
        [ decided first J.Possibly_needed; decided second J.Not_needed; decided third J.Not_needed ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  Alcotest.(check int) "a memory read from the transcript has none" 0
    (occurrences (body transcript_only) board_coordinate)

let test_a_time_no_date_can_be_made_of_is_written_as_unknown () =
  let unrepresentable = { first with F.first_seen = 1e18 } in
  Alcotest.(check bool) "there is no date for it" true
    (Option.is_none (Candidates.utc_day unrepresentable.first_seen));
  Alcotest.(check bool) "the word for it is not an empty slot" false
    (String.equal Render.unknown_day "");
  let judgment =
    judged
      ~results:[ decided unrepresentable J.Possibly_needed ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  match Render.body [ unrepresentable ] judgment with
  | None -> Alcotest.fail "expected a body"
  | Some text ->
    Alcotest.(check bool) "the first day is unknown and the last day is a date" true
      (contains text (item_head ~first_seen:(fun _ -> Render.unknown_day) unrepresentable))

let test_a_time_bound_memory_is_worded_as_the_value_at_its_time () =
  let marked marks = body (carrying_two ~marks ()) in
  let standing = marked [ id first, J.Marked J.Standing; id second, J.Marked J.Standing ] in
  Alcotest.(check bool) "standing memories carry neither note" false
    (contains standing time_bound || contains standing time_unjudged);
  let bound = marked [ id first, J.Marked J.Time_bound; id second, J.Marked J.Standing ] in
  Alcotest.(check bool) "time bound is said" true (contains bound time_bound);
  Alcotest.(check bool) "and only where it is" true
    (index_of bound time_bound < index_of bound second.claim);
  let unjudged = marked [ id first, J.Time_unjudged; id second, J.Marked J.Standing ] in
  Alcotest.(check bool) "an unjudged time is said" true (contains unjudged time_unjudged);
  Alcotest.(check bool) "and is not worded as time bound" false (contains unjudged time_bound)

let test_a_memory_without_a_mark_is_not_worded_as_standing () =
  let text = body (carrying_two ~marks:[ id second, J.Marked J.Standing ] ()) in
  Alcotest.(check bool) "the one with no mark says its time was not judged" true
    (contains text time_unjudged)

let test_a_claim_of_several_lines_cannot_open_an_item_or_a_heading () =
  let claim_lines = [ "the first line"; "- forged-item"; "### forged heading"; "the last line" ] in
  List.iter
    (fun (label, line_break) ->
      let several = fact (String.concat line_break claim_lines) in
      let judgment =
        judged
          ~results:[ decided several J.Possibly_needed ]
          ~turn:(J.Turn_answered J.Needs_knowledge)
          ()
      in
      match Render.body [ several ] judgment with
      | None -> Alcotest.fail "expected a body"
      | Some text ->
        (* Whoever reads the text may take any of LF, CR or CRLF for a line break. *)
        let readers_lines =
          String.split_on_char '\n' (String.map (fun c -> if Char.equal c '\r' then '\n' else c) text)
        in
        let starting prefix = List.filter (String.starts_with ~prefix) readers_lines in
        Alcotest.(check int) (label ^ ": one item, the real one") 1 (List.length (starting "- "));
        Alcotest.(check int) (label ^ ": one heading, the real one") 1 (List.length (starting "### "));
        Alcotest.(check bool) (label ^ ": every line after the first is indented by four spaces") true
          (contains text (String.concat "\n    " claim_lines));
        Alcotest.(check bool) (label ^ ": no carriage return is left") false (String.contains text '\r');
        List.iter
          (fun line -> Alcotest.(check bool) (label ^ ": keeps " ^ line) true (contains text line))
          claim_lines)
    [ "LF", "\n"; "CR", "\r"; "CRLF", "\r\n" ]

let test_a_carried_memory_whose_fact_is_gone_is_named_and_not_dropped () =
  (* The judgment carried the first and the second. A retry in the turn read the
     facts again and the store no longer holds the second. *)
  match Render.body [ first; third ] (carrying_two ()) with
  | None -> Alcotest.fail "expected a body"
  | Some text ->
    let omitted = fragment Prompt_names.keeper_recall_body_omitted [ "ids", id second ] in
    Alcotest.(check bool) "the heading counts the one shown" true
      (String.starts_with ~prefix:(fragment Prompt_names.keeper_recall_body_heading [ "count", "1" ]) text);
    Alcotest.(check bool) "the memory still held is shown" true (contains text first.claim);
    Alcotest.(check bool) "the one that is gone is not" false (contains text second.claim);
    Alcotest.(check bool) "its id is named after the items" true
      (index_of text omitted > index_of text first.claim);
    Alcotest.(check int) "once" 1 (occurrences text omitted)

let test_a_body_whose_facts_are_all_gone_still_names_every_id () =
  match Render.body [] (carrying_two ()) with
  | None -> Alcotest.fail "expected a body"
  | Some text ->
    Alcotest.(check string) "a heading of none, then the ids in candidate order"
      (String.concat "\n"
         [ fragment Prompt_names.keeper_recall_body_heading [ "count", "0" ]
         ; fragment Prompt_names.keeper_recall_body_omitted [ "ids", id first ^ ", " ^ id second ]
         ])
      text

let () =
  Alcotest.run "keeper_memory_recall_render"
    [ ( "status"
      , [ Alcotest.test_case "a selected status names the turn, the counts and the ids" `Quick
            test_a_selected_status_names_the_turn_the_counts_and_the_ids
        ; Alcotest.test_case "the five kinds of status are five different lines" `Quick
            test_the_five_kinds_of_status_are_five_different_lines
        ; Alcotest.test_case "the answer of the turn question tells none found apart" `Quick
            test_the_answer_of_the_turn_question_tells_none_found_apart
        ; Alcotest.test_case "a none needed status names the turn and the candidates" `Quick
            test_a_none_needed_status_names_the_turn_and_the_candidates
        ; Alcotest.test_case "an unavailable status carries its reason" `Quick
            test_an_unavailable_status_carries_its_reason
        ; Alcotest.test_case "a failed turn question after judging says how many were looked at" `Quick
            test_a_failed_turn_question_after_judging_says_how_many_were_looked_at
        ; Alcotest.test_case "a judgment of some candidates says how many" `Quick
            test_a_judgment_of_some_candidates_says_how_many
        ; Alcotest.test_case "a status without a selection counts the candidates it judged" `Quick
            test_a_status_without_a_selection_counts_the_candidates_it_judged
        ; Alcotest.test_case "the search pointer ends every state but selected when the tool exists" `Quick
            test_the_search_pointer_ends_every_state_but_selected_when_the_tool_exists
        ; Alcotest.test_case "a status the flow cannot build is refused" `Quick
            test_a_status_the_flow_cannot_build_is_refused
        ] )
    ; ( "body"
      , [ Alcotest.test_case "only a selected judgment has a body" `Quick
            test_only_a_selected_judgment_has_a_body
        ; Alcotest.test_case "the body holds the carried memories in candidate order and no other" `Quick
            test_the_body_holds_the_carried_memories_in_candidate_order_and_no_other
        ; Alcotest.test_case "a body is its heading then each item with its notes two spaces in" `Quick
            test_a_body_is_its_heading_then_each_item_with_its_notes_two_spaces_in
        ; Alcotest.test_case "a board memory adds the coordinate a completion can cite" `Quick
            test_a_board_memory_adds_the_coordinate_a_completion_can_cite
        ; Alcotest.test_case "a time no date can be made of is written as unknown" `Quick
            test_a_time_no_date_can_be_made_of_is_written_as_unknown
        ; Alcotest.test_case "a time bound memory is worded as the value at its time" `Quick
            test_a_time_bound_memory_is_worded_as_the_value_at_its_time
        ; Alcotest.test_case "a memory without a mark is not worded as standing" `Quick
            test_a_memory_without_a_mark_is_not_worded_as_standing
        ; Alcotest.test_case "a claim of several lines cannot open an item or a heading" `Quick
            test_a_claim_of_several_lines_cannot_open_an_item_or_a_heading
        ; Alcotest.test_case "a carried memory whose fact is gone is named and not dropped" `Quick
            test_a_carried_memory_whose_fact_is_gone_is_named_and_not_dropped
        ; Alcotest.test_case "a body whose facts are all gone still names every id" `Quick
            test_a_body_whose_facts_are_all_gone_still_names_every_id
        ] )
    ]
