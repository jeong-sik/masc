(* Answering from the terminal. Every case here is one the operator can reach
   with two keys, so a regression shows up as a wrong keystroke, not a wrong
   type. *)

module Decode = Masc.Tui_decode
module Ask = Masc_tui_ask_projection

let choice id label : Decode.ask_choice =
  { ac_id = id; ac_label = label; ac_description = None }

let question ?(mode = Decode.Ask_single) ?(free_text = Decode.Ask_choices_only)
    ?(choices = [ choice "yes" "Yes"; choice "no" "No" ]) id : Decode.ask_question =
  {
    aq_id = id;
    aq_header = "Header";
    aq_prompt = "Prompt for " ^ id;
    aq_mode = mode;
    aq_free_text = free_text;
    aq_choices = choices;
  }

let row ?(resolution = Decode.Ask_open) ?(questions = [ question "q1" ]) id : Decode.ask_row =
  {
    ar_keeper = "asker";
    ar_id = id;
    ar_asked_at = 1.0;
    ar_context = None;
    ar_questions = questions;
    ar_resolution = resolution;
  }

let chosen draft q =
  match Ask.response_for draft ~question:q with
  | Some (Ask.Draft_chose ids) -> ids
  | Some (Ask.Draft_wrote text) -> [ "wrote:" ^ text ]
  | Some Ask.Draft_skipped -> [ "skipped" ]
  | None -> []

let check_ids = Alcotest.(check (list string))

let single = question "q1"
let multi = question ~mode:Decode.Ask_multi "q1"
let yes = choice "yes" "Yes"
let no = choice "no" "No"

let test_draft_for_keeps_matching_ask () =
  let d = Ask.toggle_choice (Ask.empty_draft ~ask_id:"a1") ~question:single ~choice:yes in
  let kept = Ask.draft_for (Some d) ~row:(row "a1") in
  check_ids "selection survives" [ "yes" ] (chosen kept single)

let test_draft_for_resets_on_other_ask () =
  let d = Ask.toggle_choice (Ask.empty_draft ~ask_id:"a1") ~question:single ~choice:yes in
  let fresh = Ask.draft_for (Some d) ~row:(row "a2") in
  Alcotest.(check string) "adopts the new ask" "a2" (Ask.draft_ask_id fresh);
  check_ids "nothing carried over" [] (chosen fresh single)

let test_single_replaces () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:single ~choice:yes in
  let d = Ask.toggle_choice d ~question:single ~choice:no in
  check_ids "one at a time" [ "no" ] (chosen d single)

let test_single_repick_clears () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:single ~choice:yes in
  let d = Ask.toggle_choice d ~question:single ~choice:yes in
  check_ids "a mis-press needs no second key" [] (chosen d single);
  Alcotest.(check bool) "back to unanswered" true (Ask.response_for d ~question:single = None)

let test_multi_keeps_pick_order () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:multi ~choice:no in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  check_ids "order the operator picked" [ "no"; "yes" ] (chosen d multi)

let test_multi_removes () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:multi ~choice:no in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  let d = Ask.toggle_choice d ~question:multi ~choice:no in
  check_ids "removed the first" [ "yes" ] (chosen d multi)

let test_multi_emptied_is_unanswered () =
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  let d = Ask.toggle_choice d ~question:multi ~choice:yes in
  Alcotest.(check bool) "empty selection is not an answer" true
    (Ask.response_for d ~question:multi = None)

let test_free_text_slot_absent_for_choices_only () =
  Alcotest.(check bool) "no editor on a choices-only question" true
    (Ask.free_text_slot single = None)

let test_free_text_slot_carries_hint () =
  let q =
    question ~free_text:(Decode.Ask_free_text_allowed { aft_hint = Some "one line" }) "q1"
  in
  match Ask.free_text_slot q with
  | None -> Alcotest.fail "expected a slot"
  | Some slot ->
      Alcotest.(check (option string)) "hint reaches the editor" (Some "one line")
        (Ask.free_text_hint slot)

let text_question_named id =
  question ~free_text:(Decode.Ask_free_text_allowed { aft_hint = None }) ~choices:[] id

let text_question = text_question_named "q1"

let slot_of q =
  match Ask.free_text_slot q with None -> Alcotest.fail "expected a slot" | Some s -> s

let test_set_text_records () =
  let d = Ask.set_text (Ask.empty_draft ~ask_id:"a1") ~slot:(slot_of text_question) ~text:"ship it" in
  check_ids "text is the answer" [ "wrote:ship it" ] (chosen d text_question)

let test_blank_text_clears () =
  let slot = slot_of text_question in
  let d = Ask.set_text (Ask.empty_draft ~ask_id:"a1") ~slot ~text:"draft" in
  let d = Ask.set_text d ~slot ~text:"   " in
  Alcotest.(check bool) "an emptied editor means unanswered" true
    (Ask.response_for d ~question:text_question = None)

let test_skip_counts_as_answered () =
  let d = Ask.skip (Ask.empty_draft ~ask_id:"a1") ~question:single in
  check_ids "declining is an answer" [ "skipped" ] (chosen d single)

let test_clear_removes () =
  let d = Ask.toggle_choice (Ask.empty_draft ~ask_id:"a1") ~question:single ~choice:yes in
  let d = Ask.clear d ~question:single in
  Alcotest.(check bool) "cleared" true (Ask.response_for d ~question:single = None)

let missing_ids = function
  | Ask.Missing questions ->
      List.map (fun (q : Decode.ask_question) -> q.aq_id) questions
  | Ask.Ready _ -> [ "<ready>" ]
  | Ask.Not_open -> [ "<not-open>" ]

let two_questions = [ question "q1"; question "q2" ]

let test_missing_lists_every_gap_at_once () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.empty_draft ~ask_id:"a1" in
  check_ids "one round trip, not two" [ "q1"; "q2" ] (missing_ids (Ask.readiness d ~row:r))

let test_missing_shrinks_as_answered () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.skip (Ask.empty_draft ~ask_id:"a1") ~question:(List.nth two_questions 0) in
  check_ids "only the gap remains" [ "q2" ] (missing_ids (Ask.readiness d ~row:r))

let test_ready_follows_ask_order_not_draft_order () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.skip d ~question:(List.nth two_questions 1) in
  let d = Ask.toggle_choice d ~question:(List.nth two_questions 0) ~choice:yes in
  match Ask.readiness d ~row:r with
  | Ask.Ready json ->
      let ids =
        match json with
        | `List items ->
            List.filter_map
              (function
                | `Assoc fields -> (
                    match List.assoc_opt "question_id" fields with
                    | Some (`String id) -> Some id
                    | Some _ | None -> None)
                | _ -> None)
              items
        | _ -> []
      in
      check_ids "the ask decides the order" [ "q1"; "q2" ] ids
  | Ask.Missing _ | Ask.Not_open -> Alcotest.fail "expected ready"

let test_ready_encodes_each_shape () =
  let questions = [ question "q1"; question "q2"; text_question_named "q3" ] in
  let r = row ~questions "a1" in
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:(List.nth questions 0) ~choice:yes in
  let d = Ask.skip d ~question:(List.nth questions 1) in
  let d = Ask.set_text d ~slot:(slot_of (List.nth questions 2)) ~text:"because" in
  match Ask.readiness d ~row:r with
  | Ask.Ready json ->
      Alcotest.(check string)
        "wire shape the endpoint decodes"
        {|[{"question_id":"q1","response":{"kind":"chose","choice_ids":["yes"]}},{"question_id":"q2","response":{"kind":"skipped"}},{"question_id":"q3","response":{"kind":"wrote","text":"because"}}]|}
        (Yojson.Safe.to_string json)
  | Ask.Missing _ | Ask.Not_open -> Alcotest.fail "expected ready"

let test_answered_row_is_not_open () =
  let r =
    row ~resolution:(Decode.Ask_answered { aa_answered_at = 2.0; aa_question_ids = [ "q1" ] }) "a1"
  in
  check_ids "first write settled it" [ "<not-open>" ] (missing_ids (Ask.readiness (Ask.empty_draft ~ask_id:"a1") ~row:r))

let test_withdrawn_row_is_not_open () =
  let r =
    row ~resolution:(Decode.Ask_withdrawn { aw_reason = "moot"; aw_withdrawn_at = 2.0 }) "a1"
  in
  check_ids "withdrawn" [ "<not-open>" ] (missing_ids (Ask.readiness (Ask.empty_draft ~ask_id:"a1") ~row:r))

let test_foreign_draft_contributes_nothing () =
  let r = row ~questions:two_questions "a1" in
  let d = Ask.skip (Ask.empty_draft ~ask_id:"OTHER") ~question:(List.nth two_questions 0) in
  check_ids "everything missing, which is true" [ "q1"; "q2" ] (missing_ids (Ask.readiness d ~row:r))

let test_request_body_omits_blank_identity () =
  let body = Ask.request_body ~answers:(`List []) ~actor_id:(Some "  ") ~session_id:None in
  Alcotest.(check string) "no empty identity fields" {|{"answers":[]}|} (Yojson.Safe.to_string body)

let test_request_body_carries_identity () =
  let body = Ask.request_body ~answers:(`List []) ~actor_id:(Some "vincent") ~session_id:(Some "s1") in
  Alcotest.(check string) "identity travels with the answer"
    {|{"answers":[],"actor_id":"vincent","session_id":"s1"}|}
    (Yojson.Safe.to_string body)

let gate_name = function
  | Ask.Ask_gate_blocked_inflight -> "blocked"
  | Ask.Ask_gate_arm id -> "arm:" ^ id
  | Ask.Ask_gate_submit -> "submit"

let test_gate_blocks_while_inflight () =
  Alcotest.(check string) "one answer at a time" "blocked"
    (gate_name (Ask.gate_transition ~inflight:true ~pending:(Some "a1") ~ask_id:"a1"))

let test_gate_arms_first () =
  Alcotest.(check string) "first press arms" "arm:a1"
    (gate_name (Ask.gate_transition ~inflight:false ~pending:None ~ask_id:"a1"))

let test_gate_submits_on_second_press () =
  Alcotest.(check string) "second press sends" "submit"
    (gate_name (Ask.gate_transition ~inflight:false ~pending:(Some "a1") ~ask_id:"a1"))

let test_gate_rearms_on_a_different_ask () =
  Alcotest.(check string) "moving the cursor disarms the old one" "arm:a2"
    (gate_name (Ask.gate_transition ~inflight:false ~pending:(Some "a1") ~ask_id:"a2"))

let rows ids = List.map (fun id -> row id) ids

let test_cursor_follows_the_ask () =
  Alcotest.(check int) "same ask, new index" 2
    (Ask.reconcile_cursor ~current_rows:(rows [ "a1"; "a2" ]) ~cursor:1
       ~next_rows:(rows [ "x"; "y"; "a2" ]))

let test_cursor_falls_back_when_ask_is_gone () =
  Alcotest.(check int) "bounded, not stale" 1
    (Ask.reconcile_cursor ~current_rows:(rows [ "a1"; "a2" ]) ~cursor:1
       ~next_rows:(rows [ "x"; "y" ]))

let test_cursor_clamps_to_shorter_list () =
  Alcotest.(check int) "clamped" 0
    (Ask.reconcile_cursor ~current_rows:(rows [ "a1"; "a2"; "a3" ]) ~cursor:2 ~next_rows:(rows [ "x" ]))

(* summarize_answer: the confirmation after an answer reads the labels the
   operator saw, never the choice ids the wire carries. *)
let test_summarize_names_chosen_label () =
  let q = question "q1" in
  let r = row ~questions:[ q ] "a1" in
  let d =
    Ask.toggle_choice (Ask.empty_draft ~ask_id:"a1") ~question:q
      ~choice:(choice "yes" "Yes")
  in
  Alcotest.(check string) "the label, not the id" "Yes"
    (Ask.summarize_answer d ~row:r)

let test_summarize_empty_when_unanswered () =
  let q = question "q1" in
  let r = row ~questions:[ q ] "a1" in
  Alcotest.(check string) "nothing answered is empty" ""
    (Ask.summarize_answer (Ask.empty_draft ~ask_id:"a1") ~row:r)

let test_summarize_quotes_written_answer () =
  let q = question ~free_text:(Decode.Ask_free_text_allowed { aft_hint = None }) "q1" in
  let r = row ~questions:[ q ] "a1" in
  let d = Ask.set_text (Ask.empty_draft ~ask_id:"a1") ~slot:(slot_of q) ~text:"do it" in
  Alcotest.(check string) "written is quoted" "\"do it\""
    (Ask.summarize_answer d ~row:r)

let test_summarize_names_skip () =
  let q = question "q1" in
  let r = row ~questions:[ q ] "a1" in
  let d = Ask.skip (Ask.empty_draft ~ask_id:"a1") ~question:q in
  Alcotest.(check string) "skip is named" "skipped"
    (Ask.summarize_answer d ~row:r)

let test_summarize_joins_questions_in_ask_order () =
  let q1 = question "q1" in
  let q2 = question ~choices:[ choice "a" "Alpha"; choice "b" "Beta" ] "q2" in
  let r = row ~questions:[ q1; q2 ] "a1" in
  let d = Ask.empty_draft ~ask_id:"a1" in
  let d = Ask.toggle_choice d ~question:q1 ~choice:(choice "no" "No") in
  let d = Ask.toggle_choice d ~question:q2 ~choice:(choice "b" "Beta") in
  Alcotest.(check string) "joined with ; in ask order" "No; Beta"
    (Ask.summarize_answer d ~row:r)

(* newly_opened_ask_ids: the bell rings once per question that arrives, not
   per poll and not for the state the session started in. *)
let snapshot rows : Decode.asks_snapshot =
  { asn_keeper = None; asn_open_count = List.length rows; asn_rows = rows }

let answered_row id =
  row
    ~resolution:(Decode.Ask_answered { aa_answered_at = 1.0; aa_question_ids = [] })
    id

let test_newly_opened_silent_on_first_read () =
  Alcotest.(check (list string)) "first read establishes a baseline silently" []
    (Ask.newly_opened_ask_ids ~previous:None ~current:(snapshot [ row "a1" ]))

let test_newly_opened_reports_arrival () =
  let before = snapshot [ row "a1" ] in
  let after = snapshot [ row "a1"; row "a2" ] in
  Alcotest.(check (list string)) "the ask that arrived" [ "a2" ]
    (Ask.newly_opened_ask_ids ~previous:(Some before) ~current:after)

let test_newly_opened_silent_on_reread () =
  let s = snapshot [ row "a1" ] in
  Alcotest.(check (list string)) "the same open asks ring nothing" []
    (Ask.newly_opened_ask_ids ~previous:(Some s) ~current:s)

let test_newly_opened_ignores_answered () =
  let before = snapshot [ row "a1" ] in
  let after = snapshot [ answered_row "a1"; row "a2" ] in
  Alcotest.(check (list string)) "a1 closing is not an arrival, a2 is" [ "a2" ]
    (Ask.newly_opened_ask_ids ~previous:(Some before) ~current:after)

let test_ring_when_arrival_and_not_watching () =
  Alcotest.(check bool) "arrival off the asks surface rings" true
    (Ask.should_ring_for_new_ask ~new_ids:[ "a1" ]
       ~operator_is_watching_asks:false)

let test_silent_when_watching_asks () =
  Alcotest.(check bool) "on the asks surface it stays silent" false
    (Ask.should_ring_for_new_ask ~new_ids:[ "a1" ]
       ~operator_is_watching_asks:true)

let test_silent_when_nothing_arrived () =
  Alcotest.(check bool) "no arrival, no ring, even off the surface" false
    (Ask.should_ring_for_new_ask ~new_ids:[] ~operator_is_watching_asks:false)

let () =
  Alcotest.run "TUI ask projection"
    [
      ( "draft",
        [
          Alcotest.test_case "keeps a matching ask" `Quick test_draft_for_keeps_matching_ask;
          Alcotest.test_case "resets on another ask" `Quick test_draft_for_resets_on_other_ask;
          Alcotest.test_case "clear removes" `Quick test_clear_removes;
          Alcotest.test_case "skip is an answer" `Quick test_skip_counts_as_answered;
        ] );
      ( "choices",
        [
          Alcotest.test_case "single replaces" `Quick test_single_replaces;
          Alcotest.test_case "single re-pick clears" `Quick test_single_repick_clears;
          Alcotest.test_case "multi keeps pick order" `Quick test_multi_keeps_pick_order;
          Alcotest.test_case "multi removes" `Quick test_multi_removes;
          Alcotest.test_case "multi emptied is unanswered" `Quick test_multi_emptied_is_unanswered;
        ] );
      ( "free text",
        [
          Alcotest.test_case "absent for choices-only" `Quick
            test_free_text_slot_absent_for_choices_only;
          Alcotest.test_case "carries the hint" `Quick test_free_text_slot_carries_hint;
          Alcotest.test_case "records text" `Quick test_set_text_records;
          Alcotest.test_case "blank clears" `Quick test_blank_text_clears;
        ] );
      ( "readiness",
        [
          Alcotest.test_case "every gap at once" `Quick test_missing_lists_every_gap_at_once;
          Alcotest.test_case "shrinks as answered" `Quick test_missing_shrinks_as_answered;
          Alcotest.test_case "ask order wins" `Quick test_ready_follows_ask_order_not_draft_order;
          Alcotest.test_case "encodes each shape" `Quick test_ready_encodes_each_shape;
          Alcotest.test_case "answered is closed" `Quick test_answered_row_is_not_open;
          Alcotest.test_case "withdrawn is closed" `Quick test_withdrawn_row_is_not_open;
          Alcotest.test_case "foreign draft contributes nothing" `Quick
            test_foreign_draft_contributes_nothing;
        ] );
      ( "request",
        [
          Alcotest.test_case "omits blank identity" `Quick test_request_body_omits_blank_identity;
          Alcotest.test_case "carries identity" `Quick test_request_body_carries_identity;
        ] );
      ( "gate",
        [
          Alcotest.test_case "blocked while inflight" `Quick test_gate_blocks_while_inflight;
          Alcotest.test_case "arms first" `Quick test_gate_arms_first;
          Alcotest.test_case "submits on second press" `Quick test_gate_submits_on_second_press;
          Alcotest.test_case "re-arms on a different ask" `Quick
            test_gate_rearms_on_a_different_ask;
        ] );
      ( "cursor",
        [
          Alcotest.test_case "follows the ask" `Quick test_cursor_follows_the_ask;
          Alcotest.test_case "falls back when gone" `Quick test_cursor_falls_back_when_ask_is_gone;
          Alcotest.test_case "clamps" `Quick test_cursor_clamps_to_shorter_list;
        ] );
      ( "summary",
        [
          Alcotest.test_case "names the chosen label" `Quick
            test_summarize_names_chosen_label;
          Alcotest.test_case "empty when unanswered" `Quick
            test_summarize_empty_when_unanswered;
          Alcotest.test_case "quotes a written answer" `Quick
            test_summarize_quotes_written_answer;
          Alcotest.test_case "names a skip" `Quick test_summarize_names_skip;
          Alcotest.test_case "joins questions in ask order" `Quick
            test_summarize_joins_questions_in_ask_order;
        ] );
      ( "arrival",
        [
          Alcotest.test_case "silent on the first read" `Quick
            test_newly_opened_silent_on_first_read;
          Alcotest.test_case "reports an arrival" `Quick
            test_newly_opened_reports_arrival;
          Alcotest.test_case "silent on a re-read" `Quick
            test_newly_opened_silent_on_reread;
          Alcotest.test_case "ignores a closing ask" `Quick
            test_newly_opened_ignores_answered;
          Alcotest.test_case "rings off the asks surface" `Quick
            test_ring_when_arrival_and_not_watching;
          Alcotest.test_case "silent on the asks surface" `Quick
            test_silent_when_watching_asks;
          Alcotest.test_case "silent with no arrival" `Quick
            test_silent_when_nothing_arrived;
        ] );
    ]
