(** The text of the recall judgment's two blocks: which sentences a status
    carries, what the body holds and in which order, and what is never worded
    as standing. A test finds a sentence by rendering its own fragment, so it
    pins which sentences appear and not how they are put. *)

open Masc
module Render = Keeper_memory_recall_render
module Flow = Keeper_memory_recall_flow
module J = Keeper_memory_recall_judgment
module F = Keeper_memory_os_types

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-render" ~absolute_turn:11
let now = 1_700_000_000.0
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

let nothing_decided =
  judged
    ~results:(List.map (fun fact -> undecided fact J.Provider_failed) facts)
    ~turn:J.Turn_question_failed ()

let status ?(memory_search_available = true) judged =
  Render.status ~memory_search_available ~turn_ref judged

let search_hint = fragment Prompt_names.keeper_recall_status_search_hint []
let search_hint_unavailable = fragment Prompt_names.keeper_recall_status_search_hint_unavailable []

(* ---- the status line ---- *)

let test_a_selected_status_names_the_turn_the_counts_and_the_ids () =
  let text = status (carrying_two ()) in
  Alcotest.(check bool) "the turn" true (contains text (Ids.Turn_ref.to_string turn_ref));
  Alcotest.(check bool) "the carried ids" true (contains text (id first) && contains text (id second));
  Alcotest.(check bool) "not the id left out" false (contains text (id third));
  Alcotest.(check string) "its sentence, then the ids on a line of their own; nothing partial, no search hint"
    (fragment Prompt_names.keeper_recall_status_selected
       [ "turn_ref", Ids.Turn_ref.to_string turn_ref; "candidates", "3"; "selected", "2" ]
     ^ "\n"
     ^ fragment Prompt_names.keeper_recall_status_selected_ids [ "ids", id first ^ ", " ^ id second ])
    text

let test_the_four_states_are_four_different_lines () =
  let lines =
    [ status (carrying_two ())
    ; status (carrying_none ~turn:(J.Turn_answered J.Needs_knowledge))
    ; status (carrying_none ~turn:(J.Turn_answered J.Needs_no_knowledge))
    ; status nothing_decided
    ]
  in
  Alcotest.(check int) "all different" 4 (List.length (List.sort_uniq String.compare lines))

let test_the_answer_of_the_turn_question_tells_none_found_apart () =
  let needs = status (carrying_none ~turn:(J.Turn_answered J.Needs_knowledge)) in
  let unsure = status (carrying_none ~turn:(J.Turn_answered J.Unsure)) in
  Alcotest.(check bool) "yes and unsure are worded apart" false (String.equal needs unsure);
  Alcotest.(check bool) "yes has its sentence" true
    (contains needs
       (fragment Prompt_names.keeper_recall_status_none_found_needed
          [ "turn_ref", Ids.Turn_ref.to_string turn_ref; "candidates", "3" ]));
  Alcotest.(check bool) "unsure has its own" true
    (contains unsure
       (fragment Prompt_names.keeper_recall_status_none_found_unsure
          [ "turn_ref", Ids.Turn_ref.to_string turn_ref; "candidates", "3" ]))

let test_a_none_needed_status_names_the_turn_and_the_candidates () =
  Alcotest.(check bool) "its own sentence" true
    (contains
       (status (carrying_none ~turn:(J.Turn_answered J.Needs_no_knowledge)))
       (fragment Prompt_names.keeper_recall_status_none_needed
          [ "turn_ref", Ids.Turn_ref.to_string turn_ref; "candidates", "3" ]))

let test_an_unavailable_status_carries_its_reason () =
  let text = status nothing_decided in
  Alcotest.(check bool) "the reason token" true (contains text "provider_failed");
  Alcotest.(check bool) "the turn" true (contains text (Ids.Turn_ref.to_string turn_ref))

let test_a_judgment_of_some_candidates_says_how_many () =
  let partial =
    judged
      ~results:
        [ decided first J.Possibly_needed
        ; undecided second J.Rate_limited
        ; undecided third J.Rate_limited
        ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  let note =
    fragment Prompt_names.keeper_recall_status_partial [ "judged", "1"; "candidates", "3" ]
  in
  (match String.split_on_char '\n' (status partial) with
   | [ sentences; ids ] ->
     Alcotest.(check bool) "a selected judgment of one candidate in three says so" true
       (contains sentences note);
     Alcotest.(check bool) "and still counts every candidate it was given" true
       (String.starts_with
          ~prefix:
            (fragment Prompt_names.keeper_recall_status_selected
               [ "turn_ref", Ids.Turn_ref.to_string turn_ref; "candidates", "3"; "selected", "1" ])
          sentences);
     Alcotest.(check string) "and the ids stay alone on their own line"
       (fragment Prompt_names.keeper_recall_status_selected_ids [ "ids", id first ])
       ids
   | lines -> Alcotest.failf "expected a sentence line and an ids line, got %d lines" (List.length lines));
  Alcotest.(check bool) "a complete one does not" false (contains (status (carrying_two ())) note)

let test_a_none_found_status_counts_the_candidates_it_judged () =
  let partial =
    judged
      ~results:
        [ decided first J.Not_needed; undecided second J.Rate_limited; undecided third J.Rate_limited ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  let text = status partial in
  Alcotest.(check bool) "the one it judged, not the three it was given" true
    (contains text
       (fragment Prompt_names.keeper_recall_status_none_found_needed
          [ "turn_ref", Ids.Turn_ref.to_string turn_ref; "candidates", "1" ]));
  Alcotest.(check bool) "and says it judged only some" true
    (contains text
       (fragment Prompt_names.keeper_recall_status_partial [ "judged", "1"; "candidates", "3" ]));
  Alcotest.(check bool) "and the pointer to the search still ends it" true
    (String.ends_with ~suffix:search_hint text)

let test_the_search_pointer_ends_every_state_but_selected_when_the_tool_exists () =
  let cases =
    [ "none_found", carrying_none ~turn:(J.Turn_answered J.Needs_knowledge), search_hint
    ; "none_needed", carrying_none ~turn:(J.Turn_answered J.Needs_no_knowledge), search_hint
    ; "unavailable", nothing_decided, search_hint_unavailable
    ]
  in
  List.iter
    (fun (label, judgment, hint) ->
      Alcotest.(check bool) (label ^ " points to the search") true
        (String.ends_with ~suffix:hint (status judgment));
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

(* The expected values are read from the candidate line the judgment was made
   on, so this pins which value goes into which slot and not how days or kinds
   are written. *)
let test_an_item_puts_every_field_in_the_slot_of_its_name () =
  let seen_again = { first with F.last_seen = first.F.last_seen +. (3. *. 86_400.) } in
  let line = Keeper_memory_recall_candidates.(line (of_fact seen_again)) in
  let field name = Yojson.Safe.Util.(member name line |> to_string) in
  Alcotest.(check bool) "the two days differ, or the slots could not be told apart" false
    (String.equal (field "first_seen") (field "last_seen"));
  let expected =
    fragment Prompt_names.keeper_recall_body_item
      [ "id", id seen_again
      ; "category", field "category"
      ; "first_seen", field "first_seen"
      ; "last_seen", field "last_seen"
      ; "origin", field "origin"
      ; "claim", seen_again.F.claim
      ]
  in
  let judgment =
    judged
      ~marks:[ id seen_again, J.Marked J.Standing ]
      ~results:[ decided seen_again J.Possibly_needed ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  match Render.body [ seen_again ] judgment with
  | Some text -> Alcotest.(check bool) "every field in its own slot" true (contains text expected)
  | None -> Alcotest.fail "expected a body"

let test_a_claim_of_several_lines_cannot_open_an_item_or_a_heading () =
  let claim_lines = [ "the first line"; "- forged-item"; "### forged heading"; "the last line" ] in
  let several = fact (String.concat "\n" claim_lines) in
  let judgment =
    judged
      ~results:[ decided several J.Possibly_needed ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  match Render.body [ several ] judgment with
  | None -> Alcotest.fail "expected a body"
  | Some text ->
    let starting prefix =
      List.filter (String.starts_with ~prefix) (String.split_on_char '\n' text)
    in
    Alcotest.(check int) "one item, the real one" 1 (List.length (starting "- "));
    Alcotest.(check int) "one heading, the real one" 1 (List.length (starting "### "));
    Alcotest.(check bool) "every line after the first is indented by four spaces" true
      (contains text (String.concat "\n    " claim_lines));
    List.iter
      (fun line -> Alcotest.(check bool) ("keeps " ^ line) true (contains text line))
      claim_lines

let test_a_board_memory_adds_the_coordinate_a_completion_can_cite () =
  let text = body (carrying_two ()) in
  let coordinate = fragment Prompt_names.keeper_recall_body_source_board [ "post_id", board_post_id ] in
  Alcotest.(check bool) "the board coordinate" true (contains text coordinate);
  Alcotest.(check bool) "once: only the board memory has one" true
    (index_of text coordinate > index_of text second.claim);
  let transcript_only =
    judged
      ~results:
        [ decided first J.Possibly_needed; decided second J.Not_needed; decided third J.Not_needed ]
      ~turn:(J.Turn_answered J.Needs_knowledge)
      ()
  in
  Alcotest.(check bool) "a memory read from the transcript has none" false
    (contains (body transcript_only) coordinate)

let test_a_time_bound_memory_is_worded_as_the_value_at_its_time () =
  let time_bound = fragment Prompt_names.keeper_recall_body_time_bound [] in
  let time_unjudged = fragment Prompt_names.keeper_recall_body_time_unjudged [] in
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
    (contains text (fragment Prompt_names.keeper_recall_body_time_unjudged []))

let test_a_carried_memory_with_no_fact_is_refused () =
  match Render.body [ first; third ] (carrying_two ()) with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "rendered a memory it could not read"

let () =
  Alcotest.run "keeper_memory_recall_render"
    [ ( "status"
      , [ Alcotest.test_case "a selected status names the turn, the counts and the ids" `Quick
            test_a_selected_status_names_the_turn_the_counts_and_the_ids
        ; Alcotest.test_case "the four states are four different lines" `Quick
            test_the_four_states_are_four_different_lines
        ; Alcotest.test_case "the answer of the turn question tells none found apart" `Quick
            test_the_answer_of_the_turn_question_tells_none_found_apart
        ; Alcotest.test_case "a none needed status names the turn and the candidates" `Quick
            test_a_none_needed_status_names_the_turn_and_the_candidates
        ; Alcotest.test_case "an unavailable status carries its reason" `Quick
            test_an_unavailable_status_carries_its_reason
        ; Alcotest.test_case "a judgment of some candidates says how many" `Quick
            test_a_judgment_of_some_candidates_says_how_many
        ; Alcotest.test_case "a none found status counts the candidates it judged" `Quick
            test_a_none_found_status_counts_the_candidates_it_judged
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
        ; Alcotest.test_case "an item puts every field in the slot of its name" `Quick
            test_an_item_puts_every_field_in_the_slot_of_its_name
        ; Alcotest.test_case "a claim of several lines cannot open an item or a heading" `Quick
            test_a_claim_of_several_lines_cannot_open_an_item_or_a_heading
        ; Alcotest.test_case "a board memory adds the coordinate a completion can cite" `Quick
            test_a_board_memory_adds_the_coordinate_a_completion_can_cite
        ; Alcotest.test_case "a time bound memory is worded as the value at its time" `Quick
            test_a_time_bound_memory_is_worded_as_the_value_at_its_time
        ; Alcotest.test_case "a memory without a mark is not worded as standing" `Quick
            test_a_memory_without_a_mark_is_not_worded_as_standing
        ; Alcotest.test_case "a carried memory with no fact is refused" `Quick
            test_a_carried_memory_with_no_fact_is_refused
        ] )
    ]
